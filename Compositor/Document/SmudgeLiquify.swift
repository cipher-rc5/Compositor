import AppKit
import os

/// The Brush tool's modes.
nonisolated enum BrushToolMode: String, CaseIterable, Sendable {
    case paint = "Paint"
    case erase = "Erase"
}

/// The Blur tool's modes. Smudge and Liquify push the active layer's pixels around under the brush.
nonisolated enum BlurToolMode: String, CaseIterable, Sendable {
    case liquify = "Liquify"
    case blur = "Blur"
    case smudge = "Smudge"
}

/// A Smudge or Liquify stroke in progress. It works on the active layer as the canvas shows it, at document size,
/// changing it dab by dab; the canvas shows that working copy in place of the layer. When the stroke ends, the result
/// is painted into the layer's own pixels along the stroke's path (see `EditorSession.finishWarp`). The dabs run in C
/// (`BrushPixels.c`): a brush can be 2000 pixels across.
final class WarpStroke {
    let layer: ImageLayer
    let mode: BlurToolMode
    let diameter: CGFloat
    let hardness: CGFloat
    let strength: CGFloat
    let width: Int
    let height: Int
    let context: CGContext
    /// The layer as the stroke found it, at document size: what the canvas draws under `patches`.
    let base: CGImage
    private let pixels: UnsafeMutablePointer<UInt8>
    /// Every dab's center, for painting the result into the layer.
    private(set) var points: [CGPoint] = []
    private var shown: CGImage?
    private var last: CGPoint?
    /// Smudge: the color the brush carries, a (2r+1)² RGBA square.
    private var carried: [Float] = []
    private let scratch = WarpScratch()
    /// Tiles (keys `row * columns + column`) the dabs changed since the canvas last asked for `patches`.
    private var dirtyTiles = Set<Int>()
    private var published: [Int: BrushPatch] = [:]
    static let tileSize = 256
    private static let log = Logger.compositor("Tools")

    init(layer: ImageLayer, image: CGImage, transform: LayerTransform, canvas: CGSize, mode: BlurToolMode, settings: BrushSettings) throws {
        self.layer = layer
        self.mode = mode
        diameter = max(2, settings.diameter)
        hardness = min(0.98, max(0, settings.hardness))
        strength = min(1, max(0.01, settings.opacity))
        width = Int(canvas.width); height = Int(canvas.height)
        context = try BrushRaster.context(width: width, height: height, mask: false)
        LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        guard let data = context.data else { throw ExportError.render }
        // Top-left rows: a document point's row is its y.
        pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        base = try Self.copy(pixels, stride: context.bytesPerRow, CGRect(x: 0, y: 0, width: width, height: height))
    }

    private var radius: Int { Int((diameter / 2).rounded(.up)) }
    private var columns: Int { (width + Self.tileSize - 1) / Self.tileSize }

    /// The working copy, whole, for painting the result into the layer (and for tests). A copy: the dabs keep
    /// writing the stroke's own pixels, and an image is read on other threads (`DownsampleCache` halves on a worker),
    /// so no image may stand on pixels that still change. Kept until the next change.
    var image: CGImage? {
        if let shown { return shown }
        do { shown = try Self.copy(pixels, stride: context.bytesPerRow, CGRect(x: 0, y: 0, width: width, height: height)) }
        catch { Self.log.error("Couldn’t copy the \(self.mode.rawValue, privacy: .public) stroke: \(error.localizedDescription, privacy: .public)") }
        return shown
    }

    /// What the stroke has changed, as tiles to draw over `base` (see `TiledLayerRenderer.drawStroke`). Each tile is an
    /// immutable copy, remade only after a dab touches it, so a mouse event copies the few tiles under the brush rather
    /// than the document, and nothing the canvas or its caches hold changes underneath them.
    var patches: [BrushPatch] {
        let columns = columns
        for key in dirtyTiles {
            let x = key % columns * Self.tileSize, y = key / columns * Self.tileSize
            let rect = CGRect(x: x, y: y, width: min(Self.tileSize, width - x), height: min(Self.tileSize, height - y))
            do {
                published[key] = BrushPatch(rect: rect, image: try Self.copy(pixels, stride: context.bytesPerRow, rect))
            } catch {
                // The tile keeps its last copy; the next draw tries again.
                Self.log.error("Couldn’t copy a \(self.mode.rawValue, privacy: .public) tile: \(error.localizedDescription, privacy: .public)")
                continue
            }
            dirtyTiles.remove(key)
        }
        return Array(published.values)
    }

    /// `rect` (whole pixels) of the top-down RGBA rows at `pixels`, as an image with pixels of its own.
    private static func copy(_ pixels: UnsafeMutablePointer<UInt8>, stride: Int, _ rect: CGRect) throws -> CGImage {
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        let copy = try BrushRaster.context(width: w, height: h, mask: false)
        guard let data = copy.data else { throw ExportError.render }
        let into = data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            memcpy(into + row * copy.bytesPerRow, pixels + (y + row) * stride + x * 4, w * 4)
        }
        guard let image = copy.makeImage() else { throw ExportError.render }
        return image
    }

    /// Marks the tiles a dab at `center` can change: the (2r+1)² square around it, as the C dabs clip it.
    private func touched(_ cx: Int, _ cy: Int) {
        let r = radius
        let x0 = max(0, cx - r), x1 = min(width - 1, cx + r), y0 = max(0, cy - r), y1 = min(height - 1, cy + r)
        guard x0 <= x1, y0 <= y1 else { return }
        let columns = columns
        for row in (y0 / Self.tileSize)...(y1 / Self.tileSize) {
            for column in (x0 / Self.tileSize)...(x1 / Self.tileSize) { dirtyTiles.insert(row * columns + column) }
        }
    }

    /// Continues the stroke to `point`, dabbing along the way.
    func append(_ point: CGPoint) throws {
        // Finite and within reach before any Int(_:), which traps on NaN and infinity (as `BrushStroke.append`).
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 10_000_000, abs(point.y) <= 10_000_000 else { return }
        guard let from = last else {
            last = point
            if mode == .smudge { pickUp(at: point) }
            return
        }
        let distance = hypot(point.x - from.x, point.y - from.y)
        let spacing = max(1, diameter * (mode == .smudge ? 0.08 : 0.025))
        guard distance >= spacing else { return }
        let steps = Int((distance / spacing).rounded(.up))
        var previous = from
        shown = nil
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            if mode == .smudge { smudge(at: next) } else { try push(from: previous, to: next) }
            points.append(next)
            previous = next
        }
        last = point
    }

    private func pickUp(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        carried = [Float](repeating: 0, count: side * side * 4)
        carried.withUnsafeMutableBufferPointer {
            warp_pick_up(pixels, width, height, context.bytesPerRow, Int(center.x.rounded()), Int(center.y.rounded()), r, $0.baseAddress)
        }
    }

    private func smudge(at center: CGPoint) {
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        carried.withUnsafeMutableBufferPointer {
            warp_smudge(pixels, width, height, context.bytesPerRow, cx, cy, radius,
                        Float(diameter / 2), Float(hardness), Float(strength), $0.baseAddress)
        }
        touched(cx, cy)
    }

    /// Forward warp: pixels under the brush move with it, most at its center, fading to none at its rim.
    private func push(from a: CGPoint, to b: CGPoint) throws {
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        let status = warp_push(pixels, width, height, context.bytesPerRow, cx, cy, radius,
                               Float(diameter / 2), Float(hardness),
                               Float(b.x - a.x) * Float(strength), Float(b.y - a.y) * Float(strength),
                               &scratch.bytes, &scratch.size)
        guard status == 0 else { throw ProjectError.tooLarge }
        touched(cx, cy)
    }
}

/// Liquify's copy of the area under a dab, kept between dabs.
private nonisolated final class WarpScratch {
    var bytes: UnsafeMutablePointer<UInt8>?
    var size = 0
    deinit { free(bytes) }
}

extension EditorSession {
    func beginWarp(at point: CGPoint) {
        guard canPaint, !isMaskSelected, let layer = activeLayer, let image = layer.asset?.image, let document else {
            if isMaskSelected { brushError = "Smudge and Liquify work on a layer's pixels, not its mask." }
            return
        }
        finishOpacityEdit()
        do {
            let stroke = try WarpStroke(layer: layer, image: image, transform: displayedTransform(for: layer),
                                        canvas: document.size, mode: blurMode, settings: brushSettings)
            try stroke.append(point)
            warpStroke = stroke
            lastBrushPoint = (point, layer.id, false)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    /// Paints the finished Smudge or Liquify result into the layer's pixels along the stroke, as one undo step.
    func finishWarp() {
        guard let warp = warpStroke else { return }
        warpStroke = nil
        brushRevision += 1
        guard !warp.points.isEmpty, let result = warp.image else { return }
        guard let current = document?.layers.first(where: { $0.id == warp.layer.id }),
              current.asset?.image === warp.layer.asset?.image, current.transform == warp.layer.transform else {
            ToolLog.staleResult(warp.mode.rawValue)
            return
        }
        do {
            var settings = brushSettings
            // A hard tip a little wider than the brush covers everything the stroke moved.
            settings.diameter = warp.diameter + 4
            settings.hardness = 1
            settings.opacity = 1
            let stroke = try makeRasterEdit(for: current, settings: settings)
            stroke.clone = (result, .zero)
            stroke.replacesWithClone = true
            stroke.editName = warp.mode.rawValue
            // Every dab's coverage is queued on the GPU without waiting; `flush` waits once, for all of them.
            stroke.deliversCoverageLater = true
            for point in warp.points { try stroke.append(point) }
            try stroke.flush()
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
    }
}
