import AppKit
import Synchronization
import os

/// Canvas-only previews. Full-resolution export continues to use LayerEffectsRenderer.render on its worker.
/// A single worker, superseded-request cancellation and a fixed pixel budget keep slider drags off the UI thread.
@MainActor
final class EffectsPreviewCache {
    /// Pixels to preview: an image, and for a painted layer (or mask) the raster snapshot behind it, which is
    /// reduced straight from its tiles (`RasterSnapshot.reduced`) — drawing the image itself would make and keep a
    /// full-size copy of the layer for as long as the snapshot lives.
    nonisolated struct Source: Sendable {
        let image: CGImage
        var raster: RasterSnapshot? = nil
    }
    nonisolated private final class Request: Sendable {
        let id = UUID()
        let image: CGImage
        let raster: RasterSnapshot?
        let mask: CGImage?
        let maskRaster: RasterSnapshot?
        let maskSource: CGImage?
        let placement: LayerTransform?
        let transform: LayerTransform
        let effects: LayerEffects
        let sideLimit: Int
        private let cancelled = Mutex(false)
        init(image: CGImage, raster: RasterSnapshot?, mask: CGImage?, maskRaster: RasterSnapshot?, maskSource: CGImage?,
             placement: LayerTransform?, transform: LayerTransform, effects: LayerEffects, sideLimit: Int) {
            self.image = image; self.raster = raster; self.mask = mask; self.maskRaster = maskRaster; self.maskSource = maskSource
            self.placement = placement; self.transform = transform; self.effects = effects; self.sideLimit = sideLimit
        }
        func cancel() { cancelled.withLock { $0 = true } }
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func matches(_ other: Request) -> Bool {
            // Effects are rendered in layer pixels; moving, scaling or rotating the layer
            // only changes where the cached image is drawn. An independently placed mask
            // is the exception: its coverage must be resampled when either transform changes.
            let sameMaskGeometry = maskSource == nil && other.maskSource == nil
                || (placement == nil && other.placement == nil)
                || (placement == other.placement && transform == other.transform)
            return image === other.image && maskSource === other.maskSource && sameMaskGeometry
                && effects == other.effects && sideLimit == other.sideLimit
        }
    }
    nonisolated private struct Rendered: Sendable {
        let image: CGImage
        let inset: CGFloat
        /// Set only on a seeded result: where that image belongs on the document, which an inset can't express
        /// when the layer's own box was cropped as well as warped.
        var placement: LayerTransform? = nil
    }
    private struct Entry {
        let request: Request
        var result: Rendered?
        /// Renders of this request that failed in a row; the last result stays up meanwhile.
        var failures = 0
        /// When the next try may start, after a failure.
        var retryAt: ContinuousClock.Instant?
    }
    /// Renders a layer's pixels (and mask) with `effects` within `sideLimit` pixels: the effects image, and how far
    /// it reaches past the pixels on each side.
    typealias Renderer = @Sendable (_ pixels: Source, _ mask: Source?, _ effects: LayerEffects, _ sideLimit: Int) throws
        -> (image: CGImage, inset: CGFloat)
    nonisolated private static let worker = DispatchQueue(label: "com.compositor.effects-preview", qos: .userInitiated)
    nonisolated private static let log = Logger.compositor("Effects")
    /// A failing render is tried this many times, further apart each time, before waiting for the layer to change.
    static let attempts = 4
    private let renderer: Renderer
    /// The wait before the first retry; each one after waits twice as long.
    private let firstRetry: Duration
    private var entries: [UUID: Entry] = [:]
    /// A result handed in from elsewhere — the effects warped with a distortion as it is applied — shown until the
    /// worker has rendered the layer's new pixels, so the effects don't blink off for a frame.
    private var seeds: [UUID: Rendered] = [:]
    private var sideLimit = 1536

    init(renderer: @escaping Renderer = EffectsPreviewCache.render, firstRetry: Duration = .milliseconds(250)) {
        self.renderer = renderer
        self.firstRetry = firstRetry
    }

    /// Shows `image` at `placement` for a layer until a fresh preview is ready.
    func seed(_ id: UUID, image: CGImage, placement: LayerTransform) {
        // Whatever is being rendered is for the pixels this replaces, and landing later would drop the seed.
        entries.removeValue(forKey: id)?.request.cancel()
        seeds[id] = Rendered(image: image, inset: 0, placement: placement)
    }

    /// Swaps a seed still on screen for a newer picture of the same pixels, leaving any render under way alone.
    func refreshSeed(_ id: UUID, image: CGImage, placement: LayerTransform) {
        guard let seed = seeds[id], seed.image !== image else { return }
        let fresh = Rendered(image: image, inset: 0, placement: placement)
        seeds[id] = fresh
        if entries[id]?.result?.image === seed.image { entries[id]?.result = fresh }
    }

    /// What is already rendered for a layer, without asking for anything new.
    func rendered(_ id: UUID) -> (image: CGImage, inset: CGFloat, placement: LayerTransform?)? {
        (entries[id]?.result ?? seeds[id]).map { ($0.image, $0.inset, $0.placement) }
    }

    func prepare(layers: [ImageLayer]) {
        let ids = Set(layers.filter { $0.effects?.visible.isEmpty == false }.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) { entries.removeValue(forKey: id)?.request.cancel() }
        for id in Array(seeds.keys) where !ids.contains(id) { seeds.removeValue(forKey: id) }
        // Share a ~64 MiB output budget across all effect layers. Do not evict visible layers in a
        // redraw cycle: that would repeatedly rebuild evicted previews when more layers are visible.
        sideLimit = min(1536, max(32, Int(sqrt(Double(16_777_216) / Double(max(1, ids.count))))))
    }

    func preview(for layer: ImageLayer, mask: CGImage?, transform: LayerTransform, maskPlacement: LayerTransform?,
                 completion: @escaping @MainActor @Sendable () -> Void) -> (image: CGImage, inset: CGFloat, placement: LayerTransform?)? {
        guard let image = layer.asset?.image, let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else {
            entries.removeValue(forKey: layer.id)?.request.cancel()
            return nil
        }
        // The mask's own snapshot only when the mask is drawn as it is stored, not resampled to a placement.
        let maskRaster = mask != nil && mask === layer.mask?.asset.image ? layer.mask?.asset.raster : nil
        let request = Request(image: image, raster: layer.asset?.raster, mask: mask, maskRaster: maskRaster,
                              maskSource: layer.mask?.enabledImage, placement: maskPlacement, transform: transform,
                              effects: effects, sideLimit: sideLimit)
        if let entry = entries[layer.id], entry.request.matches(request) {
            // A failed render is tried again once its wait is over, with whatever it last showed still up.
            if let retryAt = entry.retryAt, ContinuousClock.now >= retryAt {
                entries[layer.id]?.retryAt = nil
                schedule(entry.request, for: layer.id, completion: completion)
            }
            return entry.result.map { ($0.image, $0.inset, $0.placement) }
        }
        let old = entries[layer.id]
        old?.request.cancel()
        // Keep effects visible during transforms and setting changes on the same pixels.
        // For an independently placed mask, retain the last preview until its updated
        // coverage finishes rendering on the worker. Hiding one of several effects changes
        // which kinds are visible but not the pixels underneath, and the effects still shown
        // shouldn't blink off while the rest of them are rebuilt — so the last preview stands
        // in for those few frames, one effect too many rather than none at all.
        let previous = old.flatMap { entry in
            entry.request.image === image && entry.request.maskSource === request.maskSource
                ? entry.result : nil
        } ?? seeds[layer.id]
        entries[layer.id] = Entry(request: request, result: previous)
        schedule(request, for: layer.id, completion: completion)
        return previous.map { ($0.image, $0.inset, $0.placement) }
    }

    private func schedule(_ request: Request, for layerID: UUID, completion: @escaping @MainActor @Sendable () -> Void) {
        let renderer = renderer
        Self.worker.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard !request.isCancelled else { return }
            let outcome = autoreleasepool { Result { try Self.render(request, with: renderer) } }
            guard !request.isCancelled else {
                Self.log.debug("Dropped an effects preview for layer \(layerID, privacy: .public): superseded while it rendered")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.entries[layerID]?.request.id == request.id else {
                    // The layer changed while this rendered; the render for what it is now is on its way.
                    Self.log.debug("Dropped a stale effects preview for layer \(layerID, privacy: .public)")
                    return
                }
                switch outcome {
                case .success(let rendered):
                    self.entries[layerID]?.result = rendered
                    self.entries[layerID]?.failures = 0
                    self.seeds.removeValue(forKey: layerID)
                    completion()
                case .failure(let error):
                    // What was on screen stays there: dropping it would make the effects vanish without a word.
                    let failures = (self.entries[layerID]?.failures ?? 0) + 1
                    self.entries[layerID]?.failures = failures
                    Self.log.error("Effects preview for layer \(layerID, privacy: .public) failed (attempt \(failures)): \(String(describing: error), privacy: .public)")
                    guard failures < Self.attempts else { return }
                    let wait = self.firstRetry * (1 << (failures - 1))
                    self.entries[layerID]?.retryAt = ContinuousClock.now + wait
                    // Nothing else may redraw the canvas in the meantime, so ask for the draw that tries again.
                    Task { @MainActor in
                        try? await Task.sleep(for: wait)
                        completion()
                    }
                }
            }
        }
    }

    nonisolated private static func render(_ request: Request, with renderer: Renderer) throws -> Rendered {
        let rendered = try renderer(Source(image: request.image, raster: request.raster),
                                    request.mask.map { Source(image: $0, raster: request.maskRaster) },
                                    request.effects, request.sideLimit)
        return Rendered(image: rendered.image, inset: rendered.inset)
    }

    /// The canvas's renderer: the layer scaled to fit `sideLimit`, its effects scaled with it.
    nonisolated static func render(_ image: CGImage, mask: CGImage?, effects: LayerEffects, sideLimit: Int) throws
        -> (image: CGImage, inset: CGFloat) {
        try render(Source(image: image), mask: mask.map { Source(image: $0) }, effects: effects, sideLimit: sideLimit)
    }

    nonisolated static func render(_ source: Source, mask: Source?, effects: LayerEffects, sideLimit: Int) throws
        -> (image: CGImage, inset: CGFloat) {
        let image = source.image
        let margin = LayerEffectsRenderer.margin(for: effects)
        // Include stroke/shadow margins in the budget; even a 500px stroke stays bounded.
        let factor = min(1, CGFloat(sideLimit - 8) / (CGFloat(max(image.width, image.height)) + 2 * margin))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        func resized(_ source: Source, mask: Bool) throws -> CGImage {
            // A snapshot is reduced from its tiles, even at full size, so its whole-image bytes are never asked for.
            if let raster = source.raster, raster.width == source.image.width, raster.height == source.image.height {
                return try raster.reduced(width: width, height: height)
            }
            guard factor < 1 else { return source.image }
            let context = try BrushRaster.context(width: width, height: height, mask: mask)
            context.interpolationQuality = .high
            // For a grayscale mask, draw its stored coverage values directly.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(source.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw ExportError.render }
            return result
        }
        let pixels = try resized(source, mask: false)
        let scaledMask = try mask.map { try resized($0, mask: true) }
        var effects = effects
        effects.stroke?.size *= factor
        effects.shadow?.distance *= factor
        effects.shadow?.blur *= factor
        return try LayerEffectsRenderer.render(pixels, mask: scaledMask, effects: effects)
    }
}
