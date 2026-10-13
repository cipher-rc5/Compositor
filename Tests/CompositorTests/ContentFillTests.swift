import AppKit
import Testing
@testable import Compositor

/// Content-Aware Fill works on the selection and a ring of image around it, not the whole layer. These hold it to
/// what filling from the whole layer gave: the same pixels outside the hole, and a fill as close to the truth.
@MainActor
struct ContentFillTests {
    private static let side = 360

    /// Diagonal stripes, 6 px a period, in four colors: a texture whose continuation into a hole is known exactly.
    private func stripes() throws -> CGImage {
        let side = Self.side
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        let colors: [[UInt8]] = [[230, 50, 25, 255], [25, 150, 230, 255], [240, 230, 50, 255], [50, 50, 64, 255]]
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<side { for x in 0..<side {
            for channel in 0..<4 { pixels[y * context.bytesPerRow + x * 4 + channel] = colors[(x + y) / 6 % 4][channel] }
        } }
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        #expect(context.bytesPerRow == image.width * 4)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func job(_ image: CGImage, hole: CGRect) throws -> FilterJob {
        let selection = try DocumentSelection(path: CGPath(rect: hole, transform: nil), antialiased: false, feather: 0)
            .clip(canvas: CGSize(width: image.width, height: image.height))
        return FilterJob(kind: .contentAwareFill, image: image, settings: FilterSettings(), scale: 1, selection: selection, mapping: .identity)
    }

    @Test func fillingFromAroundTheSelectionMatchesFillingFromTheWholeLayer() throws {
        let side = Self.side, image = try stripes(), truth = try bytes(image)
        let hole = CGRect(x: 170, y: 170, width: 14, height: 14)
        let regional = try bytes(ContentFill.run(job(image, hole: hole)))
        // What the fill did before: the kernel over every pixel of the layer.
        var whole = truth
        var mask = [UInt8](repeating: 0, count: side * side)
        for y in Int(hole.minY)..<Int(hole.maxY) { for x in Int(hole.minX)..<Int(hole.maxX) { mask[y * side + x] = 255 } }
        let status = whole.withUnsafeMutableBufferPointer { content_fill($0.baseAddress!, side * 4, mask, side, Int32(side), Int32(side)) }
        #expect(status == 1)
        func inHole(_ index: Int) -> Bool { mask[index / 4] != 0 }
        #expect(regional.indices.allSatisfy { inHole($0) || regional[$0] == truth[$0] }, "nothing outside the hole changes")
        // Mean difference from the stripes the hole covered, per channel level.
        func error(_ result: [UInt8]) -> Double {
            let indices = result.indices.filter(inHole)
            return Double(indices.map { abs(Int(result[$0]) - Int(truth[$0])) }.reduce(0, +)) / Double(indices.count)
        }
        #expect(error(regional) <= error(whole) * 1.5 + 4, "as close as the whole-layer fill: \(error(regional)) vs \(error(whole))")
    }

    /// A hole with nothing opaque in the ring around it still fills, from the rest of the layer, as it did before.
    @Test func aHoleWithNothingAroundItStillFillsFromTheWholeLayer() throws {
        let side = Self.side
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: side))
        let image = try #require(context.makeImage())
        let hole = CGRect(x: 300, y: 300, width: 10, height: 10)
        let filled = try bytes(ContentFill.run(job(image, hole: hole)))
        let inside = (300 * side + 305) * 4
        #expect(filled[inside + 3] == 255, "filled with opaque pixels from the far side of the layer")
        #expect(abs(Int(filled[inside + 2]) - 179) <= 2)
    }

    /// No selected pixels on the layer, and the layer comes back as it was.
    @Test func aSelectionOffTheLayerLeavesItAlone() throws {
        let image = try stripes()
        let job = try job(image, hole: CGRect(x: 500, y: 500, width: 10, height: 10))
        #expect(try ContentFill.run(job) === image)
    }
}
