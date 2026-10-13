import AppKit
import CoreImage
import os

/// A layer's effects kept at full resolution while it is painted, and brought up to date only where the paint
/// changed. Rebuilding every effect over a whole layer for each dab is what made painting drag; the cost here
/// follows the brush instead, so a small brush on a big layer is cheap however large the layer is.
///
/// The work runs on a worker, never in the canvas's draw: until the first pass lands there is no `image` and the
/// canvas draws the layer as it was, and after that it draws the last finished image while the next is made.
@MainActor final class LayerEffectsSurface {
    let layerID: UUID
    /// The grid the stroke paints in, in layer pixels, and where the layer's own pixels sit inside it.
    let grid: CGSize
    let sourceRect: CGRect
    /// The room the effects need around the pixels.
    let margin: CGFloat
    private let effects: LayerEffects
    private let pixels: SurfacePixels
    /// Which tile images have already been taken in, so only new paint is redone.
    private var taken: [String: ObjectIdentifier] = [:]
    private var started = false
    /// One pass at a time, in order. Paint that arrives meanwhile waits here, merged into one more pass.
    private var running = false
    private var queued: Pass?
    private var settled: [() -> Void] = []
    private(set) var image: CGImage?
    /// Where the surface was last drawn, so what it holds can be handed on when the stroke ends.
    var placement: LayerTransform?
    /// Told each time a pass lands, with the document area it covers — nil before the surface has been drawn
    /// anywhere, when there is no telling.
    var onUpdate: ((CGRect?) -> Void)?

    private static let worker = DispatchQueue(label: "com.compositor.effects-surface", qos: .userInteractive)

    init?(layerID: UUID, effects: LayerEffects, grid: CGSize, sourceRect: CGRect) {
        let margin = LayerEffectsRenderer.margin(for: effects)
        let width = Int(grid.width + margin * 2), height = Int(grid.height + margin * 2)
        guard width > 0, height > 0, width * height <= 80_000_000,
              let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        self.layerID = layerID
        self.effects = effects
        self.grid = grid
        self.sourceRect = sourceRect
        self.margin = margin
        pixels = SurfacePixels(context: context, effects: effects, grid: grid, sourceRect: sourceRect, margin: margin)
    }

    /// Whether this surface still fits the stroke and settings it was made for.
    func matches(layerID: UUID, effects: LayerEffects, grid: CGSize, sourceRect: CGRect) -> Bool {
        self.layerID == layerID && self.effects == effects && self.grid == grid && self.sourceRect == sourceRect
    }

    /// Brings the surface up to date: everything on the first pass, and after that only where the paint changed.
    /// `base` is the layer's committed pixels and `patches` the stroke's tiles as they stand. Returns at once; the
    /// pass lands later.
    func update(base: CGImage?, patches: [BrushPatch], mask: CGImage?) {
        var dirty: CGRect?
        var seen: [String: ObjectIdentifier] = [:]
        for patch in patches {
            let key = "\(Int(patch.rect.minX)),\(Int(patch.rect.minY))"
            seen[key] = ObjectIdentifier(patch.image)
            if taken[key] != ObjectIdentifier(patch.image) { dirty = dirty.map { $0.union(patch.rect) } ?? patch.rect }
        }
        let first = !started
        started = true
        taken = seen
        let region = first ? CGRect(origin: .zero, size: grid).insetBy(dx: -margin, dy: -margin) : dirty
        guard let region else { return }
        // The newest pixels serve for everything waiting: outside what changed since, they are what an older pass had.
        let pass = Pass(region: queued.map { $0.region.union(region) } ?? region, base: base, patches: patches, mask: mask)
        if running { queued = pass } else { start(pass) }
    }

    /// Runs `body` once every pass asked for so far has landed — straight away if none is waiting.
    func whenSettled(_ body: @escaping () -> Void) {
        if running { settled.append(body) } else { body() }
    }

    private func start(_ pass: Pass) {
        running = true
        let pixels = pixels
        Self.worker.async { [weak self] in
            let landed = autoreleasepool { pixels.draw(pass) }
            Task { @MainActor [weak self] in self?.land(landed) }
        }
    }

    private func land(_ landed: Landed) {
        running = false
        if let image = landed.image {
            self.image = image
            if !landed.area.isNull, !landed.area.isEmpty { onUpdate?(documentArea(landed.area)) }
        }
        if let next = queued {
            queued = nil
            start(next)
        } else {
            let waiting = settled
            settled = []
            waiting.forEach { $0() }
        }
    }

    /// Surface pixels on the document, by where the surface was last drawn.
    private func documentArea(_ area: CGRect) -> CGRect? {
        guard let placement, let image else { return nil }
        return area.applying(BrushRaster.pixelToDocument(placement, width: image.width, height: image.height))
    }
}

/// One update's inputs: the grid region to redo and the layer as the stroke has it. Images never change once made.
nonisolated private struct Pass: Sendable {
    var region: CGRect
    var base: CGImage?
    var patches: [BrushPatch]
    var mask: CGImage?
}

/// A finished pass: the surface as it now stands, and the surface pixels that changed.
nonisolated private struct Landed: Sendable {
    let image: CGImage?
    let area: CGRect
}

/// The surface's pixels, only ever touched on its worker. Unchecked because the context and `reported` are mutable:
/// after `init` they are used only from `LayerEffectsSurface.worker`, a serial queue, so never from two threads at once.
nonisolated private final class SurfacePixels: @unchecked Sendable {
    private let context: CGContext
    private let effects: LayerEffects
    private let grid: CGSize
    private let sourceRect: CGRect
    private let margin: CGFloat
    /// What has gone wrong already, so a failure repeated on every dab is logged once per stroke.
    private var reported = Set<String>()
    private static let log = Logger.compositor("Effects")

    init(context: CGContext, effects: LayerEffects, grid: CGSize, sourceRect: CGRect, margin: CGFloat) {
        self.context = context
        self.effects = effects
        self.grid = grid
        self.sourceRect = sourceRect
        self.margin = margin
    }

    /// How far a pixel can reach into its surroundings: everything within this of a change may need redoing.
    private var reach: CGFloat {
        var reach: CGFloat = 1
        if let stroke = effects.stroke, stroke.isEnabled { reach = max(reach, stroke.size + 2) }
        if let shadow = effects.shadow, shadow.isEnabled { reach = max(reach, shadow.distance + shadow.blur * 3 + 2) }
        if let glow = effects.outerGlow, glow.isEnabled { reach = max(reach, glow.size * 3 + 2) }
        if let glow = effects.innerGlow, glow.isEnabled { reach = max(reach, glow.size * 3 + 2) }
        return ceil(reach)
    }

    /// Redraws one pass's region and snapshots the surface.
    func draw(_ pass: Pass) -> Landed {
        let area = compose(pass.region.integral, base: pass.base, patches: pass.patches, mask: pass.mask)
        return Landed(image: context.makeImage(), area: area)
    }

    /// Redraws one region of the surface: the effects there, then the pixels over them. Returns the surface
    /// pixels it redrew.
    private func compose(_ region: CGRect, base: CGImage?, patches: [BrushPatch], mask: CGImage?) -> CGRect {
        let bounds = CGRect(origin: .zero, size: grid).insetBy(dx: -margin, dy: -margin)
        let inner = region.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds)
        guard !inner.isNull, inner.width >= 1, inner.height >= 1 else { return .null }
        // Everything that can reach into `inner` has to be looked at.
        let outer = inner.insetBy(dx: -reach, dy: -reach).integral
        guard let pixels = window(outer, base: base, patches: patches, mask: mask) else { return .null }
        // In one pass on the GPU when it is available: the outline's reach and the shadow's blur are what cost.
        if let metal = MetalLayerEffects.shared {
            do {
                let built = try metal.render(pixels, effects: effects)
                context.saveGState()
                context.clip(to: inner.offsetBy(dx: margin, dy: margin))
                context.clear(inner.offsetBy(dx: margin, dy: margin))
                BrushRaster.draw(built, in: outer.offsetBy(dx: margin, dy: margin), mask: false, context: context)
                context.restoreGState()
                return inner.offsetBy(dx: margin, dy: margin)
            } catch {
                report("GPU", "The stroke's effects fell back to the CPU: the GPU render failed", error)
            }
        }
        // In the surface's own coordinates, the grid starts at the margin.
        func placed(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: margin, dy: margin) }
        context.saveGState()
        context.clip(to: placed(inner))
        context.clear(placed(inner))
        // An effect that can't be made is left out of the stroke's preview, and said so in the log.
        func made(_ kind: LayerEffectKind, _ make: () throws -> CGImage) -> CGImage? {
            do { return try make() } catch {
                report(kind.rawValue, "The stroke's \(kind.rawValue) was left out of its preview", error)
                return nil
            }
        }
        if let shadow = effects.shadow, shadow.isEnabled, shadow.opacity > 0,
           let coverage = made(.shadow, { try LayerEffectsRenderer.shadowCoverage(pixels, in: outer.size, offset: shadow.offset, blur: shadow.blur) }) {
            fill(shadow.color, alpha: shadow.opacity, coverage: coverage, in: placed(outer))
        }
        if let glow = effects.outerGlow, glow.isEnabled, glow.opacity > 0,
           let coverage = made(.outerGlow, {
               try LayerEffectsRenderer.outerGlowCoverage(pixels, placed: CGRect(origin: .zero, size: outer.size), size: outer.size, glow: glow)
           }) {
            fill(glow.color, alpha: glow.opacity, coverage: coverage, in: placed(outer))
        }
        let stroke = effects.stroke.flatMap { $0.isEnabled && $0.size > 0 && $0.opacity > 0 ? $0 : nil }
        if let stroke, !stroke.inside,
           let ring = made(.stroke, { try LayerEffectsRenderer.ringCoverage(pixels, in: outer.size, stroke: stroke) }) {
            fill(stroke.color, alpha: stroke.opacity, coverage: ring, in: placed(outer))
        }
        BrushRaster.draw(pixels, in: placed(outer), mask: false, context: context)
        if let glow = effects.innerGlow, glow.isEnabled, glow.size > 0, glow.opacity > 0,
           let coverage = made(.innerGlow, {
               try LayerEffectsRenderer.innerGlowCoverage(pixels, placed: CGRect(origin: .zero, size: outer.size), size: outer.size, glow: glow)
           }) {
            fill(glow.color, alpha: glow.opacity, coverage: coverage, in: placed(outer))
        }
        if let stroke, stroke.inside,
           let ring = made(.stroke, { try LayerEffectsRenderer.ringCoverage(pixels, in: outer.size, stroke: stroke) }) {
            fill(stroke.color, alpha: stroke.opacity, coverage: ring, in: placed(outer))
        }
        context.restoreGState()
        return placed(inner)
    }

    private func report(_ key: String, _ message: String, _ error: Error) {
        guard reported.insert(key).inserted else { return }
        Self.log.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    /// The layer as the stroke has it, over one region: its committed pixels, the tiles painted since, and its mask.
    private func window(_ region: CGRect, base: CGImage?, patches: [BrushPatch], mask: CGImage?) -> CGImage? {
        guard region.width >= 1, region.height >= 1,
              let window = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false) else { return nil }
        window.translateBy(x: -region.minX, y: -region.minY)
        func drawPixels() {
            if let base { BrushRaster.draw(base, in: sourceRect, mask: false, context: window) }
            for patch in patches where patch.rect.intersects(region) {
                BrushRaster.draw(patch.image, in: patch.rect, mask: false, context: window)
            }
        }
        if let mask {
            // The layer's own pixels are shown through its mask; paint laid down past them is not masked at all.
            window.saveGState()
            window.clip(to: sourceRect, mask: mask)
            drawPixels()
            window.restoreGState()
            window.saveGState()
            let outside = CGMutablePath()
            outside.addRect(region)
            outside.addRect(sourceRect)
            window.addPath(outside)
            window.clip(using: .evenOdd)
            drawPixels()
            window.restoreGState()
        } else {
            drawPixels()
        }
        return window.makeImage()
    }

    private func fill(_ color: PaletteColor, alpha: Double, coverage: CGImage, in rect: CGRect) {
        context.saveGState()
        context.clip(to: rect, mask: coverage)
        context.setAlpha(alpha)
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.fill(rect)
        context.restoreGState()
    }
}
