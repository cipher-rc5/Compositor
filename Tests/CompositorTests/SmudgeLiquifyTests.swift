import AppKit
import Testing
@testable import Compositor

/// The Smudge and Liquify dabs as they were written in Swift, before they moved to C (`BrushPixels.c`): the
/// reference the C kernels must match byte for byte.
private struct ReferenceWarp {
    var pixels: [UInt8]
    let width: Int
    let height: Int
    let diameter: CGFloat
    let hardness: CGFloat
    let strength: CGFloat
    var carried: [Float] = []
    var scratch: [Float] = []

    var radius: Int { Int((diameter / 2).rounded(.up)) }
    func weight(_ u: Float) -> Float {
        guard u < 1 else { return 0 }
        let h = Float(hardness)
        guard u > h else { return 1 }
        let t = (1 - u) / (1 - h)
        return t * t * (3 - 2 * t)
    }

    mutating func pickUp(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        carried = [Float](repeating: 0, count: side * side * 4)
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 { carried[c + k] = Float(pixels[p + k]) }
            }
        }
    }

    mutating func smudge(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let keep = Float(strength), invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 {
                    let under = Float(pixels[p + k])
                    let painted = under + (carried[c + k] - under) * w
                    pixels[p + k] = UInt8(max(0, min(255, painted.rounded())))
                    carried[c + k] = painted + (carried[c + k] - painted) * keep
                }
            }
        }
    }

    mutating func push(from a: CGPoint, to b: CGPoint) {
        let r = radius
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        if scratch.count < cw * ch * 4 { scratch = [Float](repeating: 0, count: cw * ch * 4) }
        for y in 0..<ch {
            for x in 0..<cw {
                let p = ((y + y0) * width + x + x0) * 4, s = (y * cw + x) * 4
                for k in 0..<4 { scratch[s + k] = Float(pixels[p + k]) }
            }
        }
        let invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= y0, y <= y1 else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= x0, x <= x1 else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                let sx = min(Float(cw - 1), max(0, Float(x - x0) - move.x * w))
                let sy = min(Float(ch - 1), max(0, Float(y - y0) - move.y * w))
                let ix = min(cw - 2, Int(sx)), iy = min(ch - 2, Int(sy))
                guard ix >= 0, iy >= 0 else { continue }
                let fx = sx - Float(ix), fy = sy - Float(iy)
                let p = (y * width + x) * 4
                let s00 = (iy * cw + ix) * 4, s10 = s00 + 4, s01 = s00 + cw * 4, s11 = s01 + 4
                for k in 0..<4 {
                    let top = scratch[s00 + k] + (scratch[s10 + k] - scratch[s00 + k]) * fx
                    let bottom = scratch[s01 + k] + (scratch[s11 + k] - scratch[s01 + k]) * fx
                    pixels[p + k] = UInt8(max(0, min(255, (top + (bottom - top) * fy).rounded())))
                }
            }
        }
    }

    /// `WarpStroke.append`'s stepping, dab for dab.
    mutating func stroke(_ path: [CGPoint], smudging: Bool) {
        guard var from = path.first else { return }
        if smudging { pickUp(at: from) }
        for point in path.dropFirst() {
            let distance = hypot(point.x - from.x, point.y - from.y)
            let spacing = max(1, diameter * (smudging ? 0.08 : 0.025))
            guard distance >= spacing else { continue }
            let steps = Int((distance / spacing).rounded(.up))
            var previous = from
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
                if smudging { smudge(at: next) } else { push(from: previous, to: next) }
                previous = next
            }
            from = point
        }
    }
}

@MainActor
struct SmudgeLiquifyTests {
    /// Noise that is still valid premultiplied RGBA, the same every run.
    private func noise(width: Int, height: Int, seed: UInt32) -> [UInt8] {
        var state = seed
        func next() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let alpha = next()
            bytes[pixel * 4 + 3] = alpha
            for k in 0..<3 { bytes[pixel * 4 + k] = UInt8(UInt16(next()) * UInt16(alpha) / 255) }
        }
        return bytes
    }

    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let width: Int, height: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat
        var testDescription: String { "\(width)×\(height), ⌀\(diameter), hardness \(hardness), strength \(strength)" }
    }
    nonisolated private static let cases: [Case] = [
        Case(width: 31, height: 23, diameter: 13, hardness: 0.5, strength: 0.5),
        Case(width: 31, height: 23, diameter: 40, hardness: 0, strength: 1),
        Case(width: 31, height: 23, diameter: 2, hardness: 0.98, strength: 0.01),
        Case(width: 1, height: 9, diameter: 5, hardness: 0.3, strength: 0.7),
        Case(width: 9, height: 1, diameter: 5, hardness: 0.3, strength: 0.7),
        Case(width: 1, height: 1, diameter: 7, hardness: 0, strength: 1),
    ]
    /// Dab centers inside, on the edges, partly off and wholly off the canvas.
    private func centers(_ width: Int, _ height: Int) -> [CGPoint] {
        let w = CGFloat(width), h = CGFloat(height)
        return [CGPoint(x: w / 2, y: h / 2), CGPoint(x: 0, y: 0), CGPoint(x: w - 0.4, y: h / 3), CGPoint(x: -3.6, y: h / 2),
                CGPoint(x: w / 2, y: h + 2), CGPoint(x: w + 40, y: -40), CGPoint(x: 1.5, y: h - 1.5)]
    }

    @Test(arguments: cases)
    func smudgeDabsMatchTheSwiftTheyReplaced(_ c: Case) {
        var reference = ReferenceWarp(pixels: noise(width: c.width, height: c.height, seed: 7), width: c.width, height: c.height,
                                      diameter: c.diameter, hardness: c.hardness, strength: c.strength)
        var pixels = reference.pixels
        var carried: [Float] = []
        let r = reference.radius
        let points = centers(c.width, c.height)
        reference.pickUp(at: points[0])
        carried = [Float](repeating: -1, count: (2 * r + 1) * (2 * r + 1) * 4)
        carried.withUnsafeMutableBufferPointer {
            warp_pick_up(pixels, c.width, c.height, c.width * 4, Int(points[0].x.rounded()), Int(points[0].y.rounded()), r, $0.baseAddress)
        }
        #expect(carried == reference.carried)
        for point in points {
            reference.smudge(at: point)
            carried.withUnsafeMutableBufferPointer {
                warp_smudge(&pixels, c.width, c.height, c.width * 4, Int(point.x.rounded()), Int(point.y.rounded()), r,
                            Float(c.diameter / 2), Float(c.hardness), Float(c.strength), $0.baseAddress)
            }
            #expect(pixels == reference.pixels, "after a dab at \(point)")
            #expect(carried == reference.carried, "carried after a dab at \(point)")
        }
    }

    @Test(arguments: cases)
    func liquifyDabsMatchTheSwiftTheyReplaced(_ c: Case) {
        var reference = ReferenceWarp(pixels: noise(width: c.width, height: c.height, seed: 11), width: c.width, height: c.height,
                                      diameter: c.diameter, hardness: c.hardness, strength: c.strength)
        var pixels = reference.pixels
        var scratch: UnsafeMutablePointer<UInt8>?, size = 0
        defer { free(scratch) }
        var previous = CGPoint(x: CGFloat(c.width) / 3, y: CGFloat(c.height) / 3)
        for point in centers(c.width, c.height) {
            reference.push(from: previous, to: point)
            let status = warp_push(&pixels, c.width, c.height, c.width * 4, Int(point.x.rounded()), Int(point.y.rounded()), reference.radius,
                                   Float(c.diameter / 2), Float(c.hardness),
                                   Float(point.x - previous.x) * Float(c.strength), Float(point.y - previous.y) * Float(c.strength),
                                   &scratch, &size)
            #expect(status == 0)
            #expect(pixels == reference.pixels, "after a dab from \(previous) to \(point)")
            previous = point
        }
    }

    /// Rows padded past the image are neither read into the result nor written.
    @Test func dabsKeepToTheirRowsWhenRowsArePadded() {
        let width = 6, height = 5, stride = width * 4 + 8
        var padded = [UInt8](repeating: 0, count: stride * height)
        let source = noise(width: width, height: height, seed: 3)
        for y in 0..<height {
            for x in 0..<(width * 4) { padded[y * stride + x] = source[y * width * 4 + x] }
            for x in (width * 4)..<stride { padded[y * stride + x] = 0xAB }
        }
        var reference = ReferenceWarp(pixels: source, width: width, height: height, diameter: 6, hardness: 0.2, strength: 0.8)
        reference.push(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 4, y: 2))
        var scratch: UnsafeMutablePointer<UInt8>?, size = 0
        defer { free(scratch) }
        #expect(warp_push(&padded, width, height, stride, 4, 2, reference.radius, 3, 0.2, 3 * 0.8, 0, &scratch, &size) == 0)
        for y in 0..<height {
            #expect(Array(padded[(y * stride)..<(y * stride + width * 4)]) == Array(reference.pixels[(y * width * 4)..<((y + 1) * width * 4)]))
            #expect(padded[(y * stride + width * 4)..<((y + 1) * stride)].allSatisfy { $0 == 0xAB })
        }
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func layer(width: Int, height: Int) throws -> (ImageLayer, CGImage) {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let source = noise(width: width, height: height, seed: 5)
        for index in source.indices { data[index] = source[index] }
        let image = try #require(context.makeImage())
        return (ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Noise"), origin: .zero), image)
    }

    @Test(arguments: [BlurToolMode.smudge, .liquify])
    func strokesMatchTheSwiftTheyReplaced(mode: BlurToolMode) throws {
        let (layer, image) = try layer(width: 48, height: 32)
        let settings = BrushSettings(diameter: 18, hardness: 0.4, opacity: 0.6)
        let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 48, height: 32),
                                    mode: mode, settings: settings)
        let start = try #require(stroke.image)
        var reference = ReferenceWarp(pixels: try bytes(start), width: 48, height: 32,
                                      diameter: stroke.diameter, hardness: stroke.hardness, strength: stroke.strength)
        #expect(reference.pixels == (try bytes(image)))
        // Partly off the canvas at both ends.
        let path = [CGPoint(x: -4, y: 6), CGPoint(x: 20.3, y: 14.7), CGPoint(x: 31, y: 16), CGPoint(x: 52, y: 30)]
        var shown: [CGImage] = [start]
        for point in path {
            try stroke.append(point)
            shown.append(try #require(stroke.image))
        }
        reference.stroke(path, smudging: mode == .smudge)
        #expect(try bytes(try #require(stroke.image)) == reference.pixels)
        // Each change stands behind a new image; an unchanged stroke keeps the one it has.
        #expect(shown[0] !== shown[2] && shown[2] !== shown[3])
        #expect(stroke.image === shown.last)
    }

    @Test func aStrokeOnAOnePixelWideCanvasStaysInBounds() throws {
        for mode in [BlurToolMode.smudge, .liquify] {
            let (layer, image) = try layer(width: 1, height: 12)
            let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 1, height: 12),
                                        mode: mode, settings: BrushSettings(diameter: 30, hardness: 0, opacity: 1))
            var reference = ReferenceWarp(pixels: try bytes(image), width: 1, height: 12,
                                          diameter: stroke.diameter, hardness: stroke.hardness, strength: stroke.strength)
            let path = [CGPoint(x: 0, y: -5), CGPoint(x: 0.4, y: 6), CGPoint(x: 0, y: 20)]
            for point in path { try stroke.append(point) }
            reference.stroke(path, smudging: mode == .smudge)
            #expect(try bytes(try #require(stroke.image)) == reference.pixels, "\(mode)")
        }
    }

    @Test(arguments: [BlurToolMode.smudge, .liquify])
    func aStrokeIsOneUndoStepOnTheLayer(mode: BlurToolMode) async throws {
        let session = EditorSession()
        session.createDocument(width: 60, height: 40)
        let (_, image) = try layer(width: 60, height: 40)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Noise"))
        session.selectTool(.blur)
        session.blurMode = mode
        session.brushSettings = BrushSettings(diameter: 16, hardness: 0.5, opacity: 0.8)
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 10, y: 20))
        #expect(session.warpStroke != nil)
        session.continueBrush(at: CGPoint(x: 30, y: 22))
        session.continueBrush(at: CGPoint(x: 50, y: 20))
        let shown = try bytes(try #require(session.warpStroke?.image))
        await session.finishBrush()
        #expect(session.warpStroke == nil && session.brushError == nil)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == mode.rawValue)
        // The layer now holds what the stroke showed.
        let layer = try #require(session.activeLayer)
        let result = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(layer.asset?.image !== image)
        let after = try bytes(result)
        let changed = zip(after, try bytes(image)).filter { $0 != $1 }.count
        #expect(changed > 0)
        #expect(after == shown || zip(after, shown).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    /// The canvas draws the stroke as the layer it started from plus copies of the tiles the dabs changed: together
    /// they are the working copy, and a copy handed out never changes under whoever holds it (the canvas's caches
    /// read them on other threads) when later dabs write the stroke's own pixels.
    @Test(arguments: [BlurToolMode.smudge, .liquify])
    func theCanvasDrawsCopiesThatLaterDabsLeaveAlone(mode: BlurToolMode) throws {
        // Wider than a tile, so a stroke on the left leaves the right-hand tiles out.
        let (layer, image) = try layer(width: 600, height: 40)
        let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 600, height: 40),
                                    mode: mode, settings: BrushSettings(diameter: 20, hardness: 0.5, opacity: 0.8))
        #expect(stroke.patches.isEmpty)
        #expect(try bytes(stroke.base) == (try bytes(image)))
        for x in stride(from: 10, through: 60, by: 5) { try stroke.append(CGPoint(x: CGFloat(x), y: 20)) }
        let first = stroke.patches
        #expect(first.count == 1 && first.first?.rect == CGRect(x: 0, y: 0, width: 256, height: 40))
        let held = try first.map { try bytes($0.image) }
        // Base and tiles composed are the working copy.
        func composed() throws -> [UInt8] {
            let context = try BrushRaster.context(width: 600, height: 40, mask: false)
            BrushRaster.draw(stroke.base, in: CGRect(x: 0, y: 0, width: 600, height: 40), mask: false, context: context)
            for patch in stroke.patches { BrushRaster.draw(patch.image, in: patch.rect, mask: false, context: context) }
            return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 600 * 40 * 4))
        }
        #expect(try composed() == (try bytes(try #require(stroke.image))))
        for x in stride(from: 60, through: 300, by: 5) { try stroke.append(CGPoint(x: CGFloat(x), y: 22)) }
        #expect(try first.map { try bytes($0.image) } == held, "a tile already handed out changed")
        #expect(stroke.patches.count == 2)
        #expect(try composed() == (try bytes(try #require(stroke.image))))
        #expect(try bytes(stroke.base) == (try bytes(image)))
    }

    /// `Int(_:)` traps on NaN and infinity; a stroke handed one ignores it, as a brush stroke does.
    @Test(arguments: [BlurToolMode.smudge, .liquify])
    func nonFinitePointsAreIgnored(mode: BlurToolMode) throws {
        let (layer, image) = try layer(width: 48, height: 32)
        let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 48, height: 32),
                                    mode: mode, settings: BrushSettings(diameter: 12, hardness: 0.5, opacity: 1))
        let strange: [CGPoint] = [CGPoint(x: CGFloat.nan, y: 4), CGPoint(x: 4, y: CGFloat.infinity), CGPoint(x: -CGFloat.infinity, y: 4),
                                  CGPoint(x: 1e300, y: 4)]
        for point in strange { try stroke.append(point) }
        #expect(stroke.points.isEmpty && stroke.patches.isEmpty)
        // Started for real, then sent the same again: still nothing traps, and only real points are dabbed.
        try stroke.append(CGPoint(x: 10, y: 10))
        for point in strange { try stroke.append(point) }
        try stroke.append(CGPoint(x: 30, y: 12))
        #expect(!stroke.points.isEmpty && stroke.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x <= 30 })
    }
}

