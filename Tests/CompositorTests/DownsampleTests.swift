import AppKit
import Testing
@testable import Compositor

/// Shrinking layers by large factors must stay sharp and clean, as Photoshop's resampling does.
@MainActor
struct DownsampleTests {
    /// An opaque RGBA image whose pixel colors come from `gray(x, y)`.
    private func image(width: Int, height: Int, gray: (Int, Int) -> UInt8) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let value = gray(x, y), i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }
    /// Draws `image` through the layer renderer, shrunk to `width` × `height`, with High quality sampling.
    private func drawn(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        var transform = LayerTransform(origin: .zero, size: CGSize(width: image.width, height: image.height))
        transform.sampling = .high
        let scale = CGFloat(width) / CGFloat(image.width)
        LayerRenderer.draw(image, transform: transform, center: CGPoint(x: transform.center.x * scale, y: transform.center.y * scale),
                           scale: scale, in: context)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    @Test func halvingsAreReusedAndOnlyUsedForLargeReductions() throws {
        let source = try image(width: 1024, height: 512) { x, _ in x % 2 == 0 ? 0 : 255 }
        #expect(DownsampleCache.shared.image(source, drawnAt: 0.6) === source, "half size and up draws the image itself")
        let eighth = DownsampleCache.shared.image(source, drawnAt: 0.125)
        #expect(eighth.width == 128 && eighth.height == 64)
        #expect(DownsampleCache.shared.image(source, drawnAt: 0.3).width == 512, "0.3 uses the half, leaving less than 2× to Core Graphics")
        #expect(DownsampleCache.shared.image(source, drawnAt: 0.125) === eighth, "copies are cached")
    }

    @Test func aHardEdgeStaysSharpShrunkEightTimes() throws {
        let source = try image(width: 4096, height: 64) { x, _ in x < 2048 ? 0 : 255 }
        let pixels = try drawn(source, width: 512, height: 8)
        let row = (0..<512).map { Int(pixels[(4 * 512 + $0) * 4]) }
        let soft = row.filter { $0 > 40 && $0 < 215 }.count
        #expect(soft <= 3, "the edge smears across \(soft) pixels")
        #expect(row[250] < 10 && row[262] > 245)
    }

    @Test func fineStripesAverageToFlatGrayWithoutShimmer() throws {
        let source = try image(width: 2048, height: 256) { x, _ in x % 2 == 0 ? 0 : 255 }
        let pixels = try drawn(source, width: 256, height: 32)
        // The outermost pixels fade into the transparent edge; judge the inside.
        let values = (4..<252).map { Double(pixels[(16 * 256 + $0) * 4]) }
        let mean = values.reduce(0, +) / Double(values.count)
        let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        #expect(abs(mean - 127.5) < 8, "mean \(mean)")
        #expect(spread < 6, "stripes shimmer after shrinking: spread \(spread)")
    }

    @Test func translucentEdgesStayValidAndMasksStayGray() throws {
        let context = try BrushRaster.context(width: 512, height: 512, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 128, y: 128, width: 256, height: 256))
        let translucent = try #require(context.makeImage())
        let shrunk = try bytes(DownsampleCache.shared.image(translucent, drawnAt: 0.25))
        #expect(stride(from: 0, to: shrunk.count, by: 4).allSatisfy { shrunk[$0] <= shrunk[$0 + 3] }, "no color above its alpha")

        let maskContext = try BrushRaster.context(width: 512, height: 512, mask: true)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: 256, height: 512))
        let mask = try #require(maskContext.makeImage())
        let level = DownsampleCache.shared.image(mask, drawnAt: 0.25)
        #expect(level.width == 128 && level.colorSpace?.model == .monochrome && level.alphaInfo == .none)
    }

    /// The budget covers the full-size images entries keep alive, not just their halvings; and an entry over the
    /// budget on its own isn't kept, though its caller still gets the reduction it asked for.
    @Test func cacheBudgetsCountTheirSourcesAndDropAnEntryTooBigToKeep() throws {
        let source = try image(width: 200, height: 100) { x, y in UInt8((x + y) % 256) }
        let halvings = 100 * 50 + 50 * 25
        let roomy = DownsampleCache(pixelBudget: 200 * 100 + halvings)
        let reduced = roomy.image(source, level: 2)
        #expect(reduced.level == 2 && reduced.image.width == 50)
        #expect(roomy.holds(source))
        #expect(roomy.retainedPixels == 200 * 100 + halvings)
        // A second image pushes the first out: the two sources don't both fit.
        let other = try image(width: 200, height: 100) { x, _ in UInt8(x % 256) }
        _ = roomy.image(other, level: 2)
        #expect(!roomy.holds(source) && roomy.holds(other))
        #expect(roomy.retainedPixels <= roomy.pixelBudget)

        let tight = DownsampleCache(pixelBudget: halvings)
        let unkept = tight.image(source, level: 2)
        #expect(unkept.level == 2 && unkept.image.width == 50)
        #expect(!tight.holds(source))
        #expect(tight.retainedPixels == 0)

        // A painted layer's pieces count the snapshot they hold as well.
        let patch = BrushPatch(rect: CGRect(x: 0, y: 0, width: 64, height: 64), image: try image(width: 64, height: 64) { _, _ in 255 })
        let raster = RasterSnapshot(width: 200, height: 100, base: source, baseRect: CGRect(x: 0, y: 0, width: 200, height: 100), patches: [patch])
        let pieces = TiledPieceCache(pixelBudget: 200 * 100)
        #expect(pieces.pieces(for: raster, level: 0)?.isEmpty == false)
        #expect(!pieces.holds(raster, level: 0), "its base alone fills the budget")
        let room = TiledPieceCache(pixelBudget: 1_000_000)
        _ = room.pieces(for: raster, level: 0)
        #expect(room.holds(raster, level: 0))
        #expect(room.retainedPixels > 200 * 100 + 64 * 64)
    }
}
