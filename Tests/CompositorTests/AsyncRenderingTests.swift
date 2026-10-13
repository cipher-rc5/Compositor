import AppKit
import Metal
import Synchronization
import Testing
@testable import Compositor

/// Work moved off the main thread and out of the canvas's draw: it has to land, in order, as the same pixels the
/// synchronous path makes, and a failure must not take away what was already showing.
@MainActor @Suite(.timeLimit(.minutes(5)))
struct AsyncRenderingTests {
    private func square(size: Int = 48, inset: Int = 12) throws -> CGImage {
        let context = try BrushRaster.context(width: size, height: size, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2))
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * context.height))
    }

    private func largestDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    /// Polls the main actor until `done`, giving landed work its turn. Generous, as the whole suite shares the main
    /// actor and can hold it for seconds at a time: each turn queues behind every main-actor test still waiting to run,
    /// which under the sanitizers on a busy machine kept a 90-second wait from seeing even the first render land.
    private func wait(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(240)
        while !done() {
            #expect(ContinuousClock.now < deadline, "timed out")
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: Brush coverage

    private func stroke() throws -> BrushStroke {
        let session = EditorSession()
        session.createDocument(width: 600, height: 400)
        session.addBlankLayer()
        return try BrushStroke(layer: #require(session.activeLayer), mask: false,
            settings: BrushSettings(diameter: 60, hardness: 0.3, red: 0.2, green: 0.4, blue: 1, opacity: 0.8),
            canvas: CGSize(width: 600, height: 400))
    }

    private func raster(_ stroke: BrushStroke) throws -> [UInt8] {
        let context = try BrushRaster.context(width: 600, height: 400, mask: false)
        LayerRenderer.drawBrushPreview(nil, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches,
            pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: false, in: context)
        return try bytes(try #require(context.makeImage()))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
    func liveBrushCoverageLandsInOrderAsTheSamePixels() async throws {
        let points = (0...24).map { CGPoint(x: 40 + CGFloat($0) * 21, y: 200 + 120 * sin(CGFloat($0) / 3)) }
        let waited = try stroke()
        for point in points { try waited.append(point) }

        let live = try stroke()
        live.deliversCoverageLater = true
        var landed = 0
        live.onCoverage = { landed += 1 }
        for point in points { try live.append(point) }
        // Every event is told once, after its paint is in the stroke.
        try await wait { landed == points.count }
        #expect(landed == points.count)
        #expect(try raster(live) == raster(waited), "the live stroke landed as different pixels")

        // The end of a stroke settles whatever is still out, and comes out the same.
        try live.append(CGPoint(x: 560, y: 80))
        try waited.append(CGPoint(x: 560, y: 80))
        try live.flush()
        try waited.flush()
        #expect(try raster(live) == raster(waited))
    }

    // MARK: Effects while painting

    private var paintEffects: LayerEffects {
        LayerEffects(stroke: StrokeEffect(size: 3, red: 0, green: 0, blue: 1, opacity: 1),
                     outerGlow: OuterGlowEffect(size: 6, red: 1, green: 1, blue: 0, opacity: 0.8))
    }

    private func settled(_ surface: LayerEffectsSurface) async {
        await withCheckedContinuation { continuation in surface.whenSettled { continuation.resume() } }
    }

    @Test func strokeEffectsRenderOffTheDrawAndMatchASynchronousRender() async throws {
        let base = try square()
        let grid = CGSize(width: base.width, height: base.height)
        let surface = try #require(LayerEffectsSurface(layerID: UUID(), effects: paintEffects, grid: grid,
                                                       sourceRect: CGRect(origin: .zero, size: grid)))
        var updates: [CGRect?] = []
        surface.onUpdate = { updates.append($0) }
        surface.update(base: base, patches: [], mask: nil)
        // Nothing has been drawn yet: the canvas shows the layer as it was until the pass lands.
        #expect(surface.image == nil)
        await settled(surface)
        let built = try #require(surface.image)
        let reference = try LayerEffectsRenderer.render(base, mask: nil, effects: paintEffects)
        #expect(reference.inset == surface.margin)
        #expect(built.width == reference.image.width && built.height == reference.image.height)
        #expect(largestDifference(try bytes(built), try bytes(reference.image)) <= 2)
        // Never drawn, so there is no telling where it is on the document: the whole canvas is to redraw.
        #expect(updates == [nil])
    }

    @Test func strokeEffectsPassesLandInOrderAsAFreshRenderWould() async throws {
        let base = try square(size: 96, inset: 30)
        let grid = CGSize(width: base.width, height: base.height)
        let rect = CGRect(origin: .zero, size: grid)
        func patch(_ x: Int, _ color: CGColor) throws -> BrushPatch {
            let context = try BrushRaster.context(width: 16, height: 16, mask: false)
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            return BrushPatch(rect: CGRect(x: x, y: 8, width: 16, height: 16), image: try #require(context.makeImage()))
        }
        let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let first = try patch(8, green), second = try patch(56, gray), repainted = try patch(8, gray)

        // Updates arriving while a pass runs are merged into the next one, using the newest tiles.
        let painted = try #require(LayerEffectsSurface(layerID: UUID(), effects: paintEffects, grid: grid, sourceRect: rect))
        painted.update(base: base, patches: [], mask: nil)
        painted.update(base: base, patches: [first], mask: nil)
        painted.update(base: base, patches: [first, second], mask: nil)
        painted.update(base: base, patches: [repainted, second], mask: nil)
        await settled(painted)

        let fresh = try #require(LayerEffectsSurface(layerID: UUID(), effects: paintEffects, grid: grid, sourceRect: rect))
        fresh.update(base: base, patches: [repainted, second], mask: nil)
        await settled(fresh)
        #expect(try bytes(#require(painted.image)) == bytes(#require(fresh.image)))
    }

    // MARK: Effects previews

    /// A renderer that fails on the calls listed, and otherwise renders as the canvas does.
    nonisolated private final class FlakyRenderer: Sendable {
        private let count = Mutex(0)
        private let failing: Set<Int>
        init(failing: Set<Int>) { self.failing = failing }
        var calls: Int { count.withLock { $0 } }
        func render(_ pixels: EffectsPreviewCache.Source, _ mask: EffectsPreviewCache.Source?, _ effects: LayerEffects,
                    _ sideLimit: Int) throws -> (image: CGImage, inset: CGFloat) {
            let call = count.withLock { $0 += 1; return $0 }
            if failing.contains(call) { throw ExportError.render }
            return try EffectsPreviewCache.render(pixels, mask: mask, effects: effects, sideLimit: sideLimit)
        }
    }

    @Test func aFailedPreviewKeepsWhatWasShowingAndIsTriedAgain() async throws {
        let flaky = FlakyRenderer(failing: [2, 3])
        let cache = EffectsPreviewCache(renderer: { try flaky.render($0, $1, $2, $3) }, firstRetry: .milliseconds(20))
        let image = try square()
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Square"), origin: .zero)
        layer.effects = paintEffects
        var completions = 0
        func preview() -> CGImage? {
            cache.preview(for: layer, mask: nil, transform: layer.transform, maskPlacement: nil,
                          completion: { completions += 1 })?.image
        }

        #expect(preview() == nil)
        try await wait { completions == 1 }
        let shown = try #require(preview())

        // New settings over the same pixels: the old preview stands in while they render, and keeps standing when
        // that fails.
        layer.effects?.outerGlow?.opacity = 0.4
        #expect(preview() === shown)
        try await wait { flaky.calls == 2 }
        // The failure asks for a redraw once its wait is over, and that redraw tries again.
        try await wait { completions == 2 }
        #expect(cache.rendered(layer.id)?.image === shown)
        #expect(preview() === shown)
        try await wait { flaky.calls == 3 }
        try await wait { completions == 3 }
        #expect(preview() === shown)
        try await wait { completions == 4 }
        #expect(flaky.calls == 4)
        let fresh = try #require(preview())
        #expect(fresh !== shown)
    }

    // MARK: Buffers

    @Test(.enabled(if: MetalLayerEffects.shared != nil, "needs a Metal device"))
    func effectsAllocateOnlyTheBuffersTheyUse() throws {
        let metal = try #require(MetalLayerEffects.shared)
        let pixels = try square()
        func planes(_ effects: LayerEffects) throws -> Int { try metal.renderCountingPlanes(pixels, effects: effects).planes }
        // The shape's own coverage is always needed.
        #expect(try planes(LayerEffects(colorOverlay: ColorOverlayEffect())) == 1)
        // A glow: its softened coverage and the blur's scratch.
        #expect(try planes(LayerEffects(outerGlow: OuterGlowEffect())) == 3)
        // A stroke: the reached shape and the ring; a shadow after it borrows the reached shape for its blur.
        #expect(try planes(LayerEffects(stroke: StrokeEffect())) == 3)
        #expect(try planes(LayerEffects(stroke: StrokeEffect(), shadow: ShadowEffect())) == 4)
        // Everything at once shares one scratch plane across all its blurs.
        let everything = LayerEffects(stroke: StrokeEffect(), shadow: ShadowEffect(), colorOverlay: ColorOverlayEffect(),
                                      innerShadow: InnerShadowEffect(), outerGlow: OuterGlowEffect(), innerGlow: InnerGlowEffect())
        #expect(try planes(everything) == 9)
    }

    // MARK: Separable blends

    @Test func separableBlendsOnlyRedoTheClippedArea() throws {
        func backdrop() throws -> CGContext {
            let context = try BrushRaster.context(width: 64, height: 64, mask: false)
            for x in 0..<64 {
                context.setFillColor(CGColor(srgbRed: CGFloat(x) / 63, green: 0.4, blue: 1 - CGFloat(x) / 63, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 64))
            }
            return context
        }
        func layer(_ context: CGContext) {
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.6, blue: 0.3, alpha: 0.7))
            context.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        }
        let whole = try backdrop(), clipped = try backdrop(), untouched = try backdrop()
        #expect(SeparableBlend.draw(.colorDodge, in: whole, body: layer))
        let area = CGRect(x: 10, y: 20, width: 30, height: 17)
        clipped.clip(to: area)
        #expect(SeparableBlend.draw(.colorDodge, in: clipped, body: layer))
        let a = try bytes(#require(whole.makeImage())), b = try bytes(#require(clipped.makeImage()))
        let c = try bytes(#require(untouched.makeImage()))
        var inside = 0, outside = 0
        // Context rows run top-down; the clip is in the flipped top-left space BrushRaster sets up.
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                let delta = (0..<4).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max()!
                let unchanged = (0..<4).allSatisfy { b[i + $0] == c[i + $0] }
                if area.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    inside = max(inside, delta)
                } else if !unchanged {
                    outside += 1
                }
            }
        }
        #expect(inside == 0, "inside the clip the blend differs from the whole one by \(inside)")
        #expect(outside == 0, "\(outside) pixels outside the clip changed")
    }
}
