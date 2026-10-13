import AppKit
import Metal
import os

/// Shared pipeline, with stroke-local tile storage. No full-canvas GPU allocation.
final class MetalBrushCoverage {
    static let shared: MetalBrushCoverage? = {
        do { return try MetalBrushCoverage() } catch {
            // The CPU path gives the same pixels, only slower; say so, or a slow machine has no explanation.
            Logger.compositor("Tools").error("Brush coverage renders on the CPU: Metal is unavailable (\(String(describing: error), privacy: .public))")
            return nil
        }
    }()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    /// A tile's accumulated paint, kept on the GPU for the whole stroke.
    struct Tile {
        let permanent: MTLBuffer
    }
    /// Encoded, uncommitted work: where each tile's preview coverage will be in `staging` once it has run.
    struct Batch {
        let command: MTLCommandBuffer
        let staging: MTLBuffer
        let copies: [(offset: Int, count: Int, context: CGContext)]
    }
    private struct Uniforms {
        var mapping: SIMD4<Float>
        var geometry: SIMD4<Float>
        var canvas: SIMD4<Float>
        var counts: SIMD4<UInt32>
    }
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let function = try device.makeLibrary(source: Self.source, options: nil).makeFunction(name: "continuousBrush") else { throw ExportError.render }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }
    func tile(width: Int, height: Int) throws -> Tile {
        guard let permanent = device.makeBuffer(length: width * height * MemoryLayout<Float>.stride, options: .storageModeShared) else { throw ExportError.render }
        memset(permanent.contents(), 0, width * height * MemoryLayout<Float>.stride)
        return Tile(permanent: permanent)
    }

    /// Encodes one brush event over `tiles`. Each batch writes its preview into staging of its own, so a batch
    /// still being read back is never overwritten by the next; the permanent paint is shared, and Metal orders
    /// those writes by commit order on the one queue.
    func encode(_ tiles: [(Tile, CGRect, CGContext)], settled: [SIMD4<Float>], tail: [SIMD4<Float>],
                mapping: CGAffineTransform, settings: BrushSettings, canvas: CGSize) throws -> Batch? {
        guard !tiles.isEmpty else { return nil }
        // A dummy segment supplies a valid buffer for tail removal with no new geometry.
        let segments = settled + tail
        let storage = segments.isEmpty ? [SIMD4<Float>(repeating: 0)] : segments
        // Offsets kept to 256 bytes, which every Metal device accepts for a buffer binding.
        var copies: [(offset: Int, count: Int, context: CGContext)] = []
        var length = 0
        for (_, rect, context) in tiles {
            let count = Int(rect.width * rect.height)
            copies.append((length, count, context))
            length += (count + 255) / 256 * 256
        }
        guard let buffer = storage.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }), let staging = device.makeBuffer(length: max(1, length), options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 3)
        for ((tile, rect, _), copy) in zip(tiles, copies) {
            let origin = rect.origin.applying(mapping)
            var uniforms = Uniforms(
                mapping: SIMD4(Float(mapping.a), Float(mapping.b), Float(mapping.c), Float(mapping.d)),
                geometry: SIMD4(Float(origin.x), Float(origin.y), Float(settings.diameter / 2), Float(settings.hardness)),
                canvas: SIMD4(Float(canvas.width), Float(canvas.height), Float(max(0.001, min(hypot(mapping.a, mapping.b), hypot(mapping.c, mapping.d)))), Float(max(0.25, settings.diameter * BrushStroke.spacingFraction(settings.hardness)))),
                counts: SIMD4(UInt32(rect.width), UInt32(rect.height), UInt32(settled.count), UInt32(segments.count)))
            encoder.setBuffer(tile.permanent, offset: 0, index: 0)
            encoder.setBuffer(staging, offset: copy.offset, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
        return Batch(command: command, staging: staging, copies: copies)
    }

    /// Copies a finished batch's coverage out of its staging buffer.
    static func deliver(_ batch: Batch) throws {
        guard batch.command.status == .completed else { throw batch.command.error ?? ExportError.render }
        for copy in batch.copies {
            // CGContext owns its memory so makeImage's copy-on-write snapshots stay immutable.
            guard let destination = copy.context.data else { throw ExportError.render }
            memcpy(destination, batch.staging.contents().advanced(by: copy.offset), copy.count)
        }
    }

    // Compile once with the system Metal compiler; no optional Xcode Metal toolchain required.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

struct BrushUniforms {
    float4 mapping; // a, b, c, d
    float4 geometry; // document origin of tile, radius, hardness
    float4 canvas; // width, height, antialias width, deposition spacing
    uint4 counts; // tile width, height, committed segment count, total segment count
};

float segmentDistanceSquared(float2 p, float4 segment) {
    float2 v = segment.zw - segment.xy;
    float t = clamp(dot(p - segment.xy, v) / max(dot(v, v), 1e-12f), 0.0f, 1.0f);
    float2 delta = p - (segment.xy + t * v);
    return dot(delta, delta);
}

float brushCoverage(float distanceSquared, constant BrushUniforms &u) {
    float distance = sqrt(distanceSquared);
    float radius = u.geometry.z;
    if (u.geometry.w >= 1.0f) {
        return clamp((radius - distance) / u.canvas.z + 0.5f, 0.0f, 1.0f);
    }
    float t = clamp((distance / radius - u.geometry.w) / (1.0f - u.geometry.w), 0.0f, 1.0f);
    return max(0.0f, (exp(-2.5f * t * t) - exp(-2.5f)) / (1.0f - exp(-2.5f)));
}

// Integrate paint deposition by distance travelled, not pointer-event count or
// spline subdivision count. Optical density adds; coverage is 1 - exp(-density).
// This is the continuous form of source-over soft dabs at the shared deposition spacing.
float tipDensity(float distanceSquared, constant BrushUniforms &u) {
    return -log(max(1.0f - brushCoverage(distanceSquared, u), 0.001f));
}

float segmentDensity(float2 p, float4 segment, constant BrushUniforms &u) {
    float2 v = segment.zw - segment.xy;
    float length = metal::length(v);
    if (length < 1e-6f) return tipDensity(dot(p - segment.xy, p - segment.xy), u); // initial click
    float2 direction = v / length;
    float projection = dot(p - segment.xy, direction);
    float2 perpendicular = p - segment.xy - projection * direction;
    float perpendicularSquared = dot(perpendicular, perpendicular);
    float radiusSquared = u.geometry.z * u.geometry.z;
    if (perpendicularSquared >= radiusSquared) return 0.0f;
    float reach = sqrt(radiusSquared - perpendicularSquared);
    float lo = max(0.0f, projection - reach), hi = min(length, projection + reach);
    if (hi <= lo) return 0.0f;
    float midpoint = (lo + hi) * 0.5f, halfLength = (hi - lo) * 0.5f;
    // Eight-point Gauss-Legendre quadrature, clipped to the tip's support.
    // Long sparse events and short dense events produce the same paint coverage.
    constexpr float nodes[4] = {0.1834346425f, 0.5255324099f, 0.7966664774f, 0.9602898565f};
    constexpr float weights[4] = {0.3626837834f, 0.3137066459f, 0.2223810345f, 0.1012285363f};
    float integral = 0.0f;
    for (uint i = 0; i < 4; ++i) {
        float a = midpoint - halfLength * nodes[i] - projection;
        float b = midpoint + halfLength * nodes[i] - projection;
        integral += weights[i] * (tipDensity(perpendicularSquared + a * a, u)
                                + tipDensity(perpendicularSquared + b * b, u));
    }
    return integral * halfLength / u.canvas.w;
}

// Permanent paint and the replaceable tail are separate. Tail previews are never
// accumulated into permanent paint, including at self-intersections.
kernel void continuousBrush(device float *permanent [[buffer(0)]],
                            device uchar *preview [[buffer(1)]],
                            constant BrushUniforms &u [[buffer(2)]],
                            device const float4 *segments [[buffer(3)]],
                            uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= u.counts.x || pixel.y >= u.counts.y) return;
    uint index = pixel.y * u.counts.x + pixel.x;
    float2 local = float2(pixel) + 0.5f;
    float2 p = u.geometry.xy + local.x * u.mapping.xy + local.y * u.mapping.zw;
    if (any(p < 0.0f) || any(p >= u.canvas.xy)) { preview[index] = 0; return; }
    if (u.geometry.w >= 1.0f) {
        // Hard tips already have a solid interior. Preserve pixel-edge antialiasing.
        float settled = INFINITY, tail = INFINITY;
        for (uint i = 0; i < u.counts.z; ++i) settled = min(settled, segmentDistanceSquared(p, segments[i]));
        for (uint i = u.counts.z; i < u.counts.w; ++i) tail = min(tail, segmentDistanceSquared(p, segments[i]));
        float value = max(permanent[index], brushCoverage(settled, u));
        permanent[index] = value;
        preview[index] = uchar(round(255.0f * max(value, brushCoverage(tail, u))));
    } else {
        float value = permanent[index], tail = 0.0f;
        for (uint i = 0; i < u.counts.z; ++i) value += segmentDensity(p, segments[i], u);
        for (uint i = u.counts.z; i < u.counts.w; ++i) tail += segmentDensity(p, segments[i], u);
        permanent[index] = min(value, 20.0f);
        preview[index] = uchar(round(255.0f * (1.0f - exp(-min(value + tail, 20.0f)))));
    }
}
"""
}

/// One stroke's GPU work, handed on in the order it was asked for. A drag event commits its batch and returns;
/// the batch's coverage is copied out on the main thread once it and every batch before it have finished, so
/// results land in order and come out the same as waiting for each one would.
final class BrushCoverageQueue {
    private let gpu: MetalBrushCoverage
    /// In commit order. An event that touched no tiles has no batch, but still waits its turn.
    private var pending: [(batch: MetalBrushCoverage.Batch?, apply: () throws -> Void)] = []
    /// The first failure, kept for the next submit or settle to report: a stroke missing a batch would be wrong.
    private var failure: (any Error)?

    init(gpu: MetalBrushCoverage) { self.gpu = gpu }

    /// Commits one brush event. `apply` runs on the main thread after its coverage is in the tiles' contexts.
    func submit(_ tiles: [(MetalBrushCoverage.Tile, CGRect, CGContext)], settled: [SIMD4<Float>], tail: [SIMD4<Float>],
                mapping: CGAffineTransform, settings: BrushSettings, canvas: CGSize, apply: @escaping () throws -> Void) throws {
        if let failure { throw failure }
        let batch = try gpu.encode(tiles, settled: settled, tail: tail, mapping: mapping, settings: settings, canvas: canvas)
        pending.append((batch, apply))
        guard let batch else { land(); return }
        batch.command.addCompletedHandler { [weak self] _ in
            Task { @MainActor in self?.land() }
        }
        batch.command.commit()
    }

    /// Waits for everything committed so far and hands it on. For the end of a stroke, and for callers that read
    /// the stroke's pixels straight after painting.
    func settle() throws {
        while let first = pending.first {
            first.batch?.command.waitUntilCompleted()
            land()
        }
        if let failure { throw failure }
    }

    /// Hands on the finished batches at the front of the line; one still running holds back those after it.
    private func land() {
        while let first = pending.first, first.batch.map({ $0.command.status == .completed || $0.command.status == .error }) ?? true {
            pending.removeFirst()
            guard failure == nil else { continue }
            do {
                if let batch = first.batch { try MetalBrushCoverage.deliver(batch) }
                try first.apply()
            } catch { failure = error }
        }
    }
}
