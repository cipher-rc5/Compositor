import AppKit
import Testing
@testable import Compositor

/// The adjustment kernels called directly, at the shapes the Swift callers rarely produce: a single row or column, a
/// single pixel, rows padded past their pixels, and masks that select nothing.
struct PixelKernelTests {
    /// Premultiplied RGBA in rows `padding` bytes longer than their pixels, the padding filled with a marker a kernel
    /// must neither count as pixels nor overwrite.
    struct Padded {
        static let marker: UInt8 = 0xAB
        let width: Int, height: Int, stride: Int
        var bytes: [UInt8]
        init(width: Int, height: Int, padding: Int = 12, _ pixel: (Int, Int) -> [UInt8]) {
            self.width = width; self.height = height; stride = width * 4 + padding
            bytes = Array(repeating: Self.marker, count: max(1, stride * height))
            for y in 0..<height { for x in 0..<width { bytes.replaceSubrange((y * stride + x * 4)..<(y * stride + x * 4 + 4), with: pixel(x, y)) } }
        }
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * stride + x * 4)..<(y * stride + x * 4 + 4)]) }
        var paddingIsIntact: Bool {
            (0..<height).allSatisfy { y in bytes[(y * stride + width * 4)..<((y + 1) * stride)].allSatisfy { $0 == Self.marker } }
        }
        mutating func run(_ kernel: (UnsafeMutablePointer<UInt8>, Int) -> Void) {
            let stride = stride
            bytes.withUnsafeMutableBufferPointer { kernel($0.baseAddress!, stride) }
        }
    }

    // MARK: Levels

    @Test(arguments: [(1, 1), (1, 5), (5, 1), (3, 2)])
    func levelsApplyStaysInsideEachRow(width: Int, height: Int) {
        let inverted = (0..<3).flatMap { _ in (0...255).map { 1 - Float($0) / 255 } }
        var image = Padded(width: width, height: height) { x, y in [UInt8(x * 40), UInt8(y * 40), 200, 255] }
        image.run { levels_apply($0, width, height, $1, inverted) }
        #expect(image.paddingIsIntact, "the padding between rows is not pixels")
        #expect(image.pixel(width - 1, height - 1) == [UInt8(255 - (width - 1) * 40), UInt8(255 - (height - 1) * 40), 55, 255])
    }

    @Test func levelsHistogramReadsBothStridesAndWeighsCoverage() {
        // Two opaque mid-gray pixels a row, the second row's coverage half.
        let image = Padded(width: 2, height: 2) { _, _ in [128, 128, 128, 255] }
        let coverageStride = 5
        var coverage = [UInt8](repeating: 0xFF, count: coverageStride * 2)
        coverage[0] = 255; coverage[1] = 255; coverage[coverageStride] = 128; coverage[coverageStride + 1] = 128
        var bins = [Double](repeating: 0, count: 1024)
        levels_histogram(image.bytes, 2, 2, image.stride, coverage, coverageStride, &bins)
        let expected = 2 + 2 * 128.0 / 255
        #expect(abs(bins[256 + 128] - expected) < 1e-9, "only the four pixels count, each by its coverage")
        #expect(abs(bins.reduce(0, +) - 4 * expected) < 1e-9, "RGB plus three channels, nothing from the padding")
        var uncovered = [Double](repeating: 0, count: 1024)
        levels_histogram(image.bytes, 2, 2, image.stride, nil, 0, &uncovered)
        #expect(uncovered[256 + 128] == 4)
    }

    // MARK: Vectorscope

    /// Where the exact angle puts a pixel, as the scope was first computed with `cos` and `sin` per pixel.
    private func exactCell(_ pixel: [UInt8], side: Int) -> Int? {
        let alpha = Double(pixel[3])
        guard alpha > 0 else { return nil }
        let r = min(1, Double(pixel[0]) / alpha), g = min(1, Double(pixel[1]) / alpha), b = min(1, Double(pixel[2]) / alpha)
        let high = max(r, g, b), chroma = high - min(r, g, b)
        guard chroma > 1e-4, high > 1e-4 else { return nil }
        var hue = high == r ? (g - b) / chroma : high == g ? 2 + (b - r) / chroma : 4 + (r - g) / chroma
        hue /= 6
        if hue < 0 { hue += 1 }
        let saturation = chroma / high
        let column = min(side - 1, max(0, Int((0.5 + cos(hue * 2 * .pi) * saturation * 0.48) * Double(side))))
        let row = min(side - 1, max(0, Int((0.5 + sin(hue * 2 * .pi) * saturation * 0.48) * Double(side))))
        return row * side + column
    }

    @Test func vectorscopeTableAgreesWithTheExactAngles() {
        // Every hue at every saturation: a 96 x 96 sweep.
        let image = Padded(width: 96, height: 96) { x, y in
            let hue = Double(x) / 96 * 6, chroma = Double(y + 1) / 96
            let second = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
            let rgb: (Double, Double, Double) = switch Int(hue) {
            case 0: (chroma, second, 0)
            case 1: (second, chroma, 0)
            case 2: (0, chroma, second)
            case 3: (0, second, chroma)
            case 4: (second, 0, chroma)
            default: (chroma, 0, second)
            }
            let low = 1 - chroma
            return [UInt8(((rgb.0 + low) * 255).rounded()), UInt8(((rgb.1 + low) * 255).rounded()), UInt8(((rgb.2 + low) * 255).rounded()), 255]
        }
        let side = CameraRawScope.scopeSide
        var exact = [Double](repeating: 0, count: side * side)
        for y in 0..<96 { for x in 0..<96 { if let cell = exactCell(image.pixel(x, y), side: side) { exact[cell] += 1 } } }
        var table = [Double](repeating: 0, count: side * side)
        levels_vectorscope(image.bytes, 96, 96, image.stride, 1, Int32(side), &table)
        let total = exact.reduce(0, +)
        #expect(abs(table.reduce(0, +) - total) < 1e-9, "the same pixels counted")
        let moved = zip(exact, table).map { abs($0 - $1) }.reduce(0, +) / 2
        #expect(moved / total < 0.01, "a few pixels on a cell boundary may land next door: \(moved) of \(total)")
        // Sampling every other pixel of every other row keeps the whole image's weight and the same shape.
        var sampled = [Double](repeating: 0, count: side * side)
        levels_vectorscope(image.bytes, 96, 96, image.stride, 2, Int32(side), &sampled)
        #expect(abs(sampled.reduce(0, +) - total) / total < 0.05)
    }

    @Test func vectorscopeEdgeCases() {
        let side = 8
        var bins = [Double](repeating: 0, count: side * side)
        // One red pixel: on the right, halfway down, at full weight. Gray, black, and transparent pixels plot nothing.
        let column = Padded(width: 1, height: 4) { _, y in [[255, 0, 0, 255], [128, 128, 128, 255], [0, 0, 0, 255], [0, 0, 0, 0]][y] }
        levels_vectorscope(column.bytes, 1, 4, column.stride, 1, Int32(side), &bins)
        #expect(bins.reduce(0, +) == 1)
        #expect(bins[side / 2 * side + side - 1] == 1)
        // A step larger than the image samples its first pixel; no side draws nothing.
        bins = [Double](repeating: 0, count: side * side)
        levels_vectorscope(column.bytes, 1, 4, column.stride, 16, Int32(side), &bins)
        #expect(bins.reduce(0, +) == 256)
        levels_vectorscope(column.bytes, 1, 4, column.stride, 1, 0, &bins)
        #expect(bins.reduce(0, +) == 256)
    }

    @Test func cameraRawScopeSamplesLargeImagesToTheSameShape() throws {
        // A red-green split: half the weight on each side of the scope, whichever pixels are counted.
        let context = try BrushRaster.context(width: 1200, height: 900, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 600, y: 0, width: 600, height: 900))
        let image = try #require(context.makeImage())
        let scope = try #require(CameraRawScope.make(image))
        let total = scope.vectorscope.reduce(0, +)
        #expect(abs(total - 1200 * 900) / (1200 * 900) < 0.01, "sampled counts are scaled to the whole image")
        let side = CameraRawScope.scopeSide
        let right = scope.vectorscope.indices.filter { $0 % side >= side / 2 }.map { scope.vectorscope[$0] }.reduce(0, +)
        #expect(abs(right / total - 0.5) < 0.01, "red on the right, green on the left, evenly")
    }

    // MARK: Noise and lens

    @Test(arguments: [(1, 1), (1, 6), (6, 1)])
    func noiseKeepsAlphaPaddingAndTransparency(width: Int, height: Int) {
        var image = Padded(width: width, height: height) { x, y in (x + y) % 2 == 0 ? [100, 100, 100, 255] : [0, 0, 0, 0] }
        image.run { noise_add_at($0, width, height, $1, 50, 1, 0, 7, -3, 5) }
        #expect(image.paddingIsIntact)
        for y in 0..<height { for x in 0..<width {
            #expect(image.pixel(x, y)[3] == ((x + y) % 2 == 0 ? 255 : 0))
            if (x + y) % 2 == 1 { #expect(image.pixel(x, y) == [0, 0, 0, 0]) }
        } }
    }

    @Test(arguments: [(1, 1), (1, 6), (6, 1), (4, 3)])
    func lensDistortCopiesAtZeroAndStaysInsideItsRows(width: Int, height: Int) {
        let source = Padded(width: width, height: height) { x, y in [UInt8(x * 30), UInt8(y * 30), 77, 255] }
        for k in [0.0, 0.35, -0.35] {
            var destination = Padded(width: width, height: height) { _, _ in [1, 2, 3, 4] }
            destination.run { lens_distort(source.bytes, $0, width, height, $1, k) }
            #expect(destination.paddingIsIntact)
            if k == 0 { #expect(destination.bytes == source.bytes, "k = 0 copies the pixels exactly") }
        }
    }

    // MARK: Content fill

    @Test func contentFillWithNothingSelectedLeavesThePixels() {
        var image = Padded(width: 4, height: 3) { x, _ in [UInt8(x * 50), 0, 0, 255] }
        let before = image.bytes
        let mask = [UInt8](repeating: 0, count: 4 * 3)
        image.run { #expect(content_fill($0, $1, mask, 4, 4, 3) == 1) }
        #expect(image.bytes == before)
        // Nor does an empty region touch anything.
        image.run { #expect(content_fill($0, $1, mask, 4, 0, 3) == 1) }
        #expect(image.bytes == before)
    }

    @Test func contentFillWithNothingToCopyFromLeavesThePixels() {
        var image = Padded(width: 3, height: 2) { _, _ in [10, 20, 30, 255] }
        let before = image.bytes
        let everything = [UInt8](repeating: 255, count: 3 * 2)
        image.run { #expect(content_fill($0, $1, everything, 3, 3, 2) == 0) }
        #expect(image.bytes == before)
    }

    @Test func contentFillFillsASingleColumnInsideItsRows() {
        // A column of red with its lower half selected, in rows longer than one pixel and a mask with its own stride.
        var image = Padded(width: 1, height: 8, padding: 20) { _, y in y < 4 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let maskStride = 3
        var mask = [UInt8](repeating: 0x7F, count: maskStride * 8)
        for y in 0..<8 { mask[y * maskStride] = y < 4 ? 0 : 255 }
        image.run { #expect(content_fill($0, $1, mask, maskStride, 1, 8) == 1) }
        #expect((4..<8).allSatisfy { image.pixel(0, $0) == [255, 0, 0, 255] }, "filled from the only source there is")
        #expect(image.paddingIsIntact)
    }

    @Test func contentFillWorksOnARegionOfALargerImage() {
        // A 16 x 16 region at (2, 2) of a 20 x 20 image, passed as its corner and the image's stride: nothing outside
        // it changes, and the hole is filled from the region alone.
        var image = Padded(width: 20, height: 20) { x, y in
            (2..<18).contains(x) && (2..<18).contains(y) ? [0, 200, 0, 255] : [200, 0, 0, 255]
        }
        let before = image
        var mask = [UInt8](repeating: 0, count: 16 * 16)
        for y in 4..<6 { for x in 4..<6 { mask[y * 16 + x] = 255 } }
        image.run { pixels, stride in
            #expect(content_fill(pixels + 2 * stride + 2 * 4, stride, mask, 16, 16, 16) == 1)
        }
        let hole = 6..<8
        for y in 0..<20 { for x in 0..<20 where !(hole.contains(x) && hole.contains(y)) {
            #expect(image.pixel(x, y) == before.pixel(x, y), "(\(x), \(y)) is outside the hole")
        } }
        #expect(hole.allSatisfy { y in hole.allSatisfy { image.pixel($0, y) == [0, 200, 0, 255] } }, "filled from the region")
        #expect(image.paddingIsIntact)
    }

    // MARK: Adjustments

    @Test(arguments: [(1, 1), (1, 9), (9, 1), (5, 4)])
    func adjustmentKernelsStayInsideTheirRows(width: Int, height: Int) {
        // A transparent first column, since several kernels skip or sample around transparent pixels.
        let source = Padded(width: width, height: height) { x, y in x == 0 && width > 1 ? [0, 0, 0, 0] : [UInt8(40 + x * 20), UInt8(200 - y * 20), 90, 255] }
        func check(_ name: String, _ kernel: (UnsafeMutablePointer<UInt8>, Int) -> Void) {
            var image = source
            image.run(kernel)
            #expect(image.paddingIsIntact, "\(name) at \(width) x \(height)")
        }
        let table: [UInt8] = (0...255).flatMap { level -> [UInt8] in [UInt8(level), UInt8(255 - level), 128] }
        check("gradient map") { adjust_gradient_map($0, width, height, $1, table) }
        check("grain") { adjust_grain($0, width, height, $1, 50, 4, 50, 3, 0, 0, 1) }
        check("black & white") { adjust_black_white($0, width, height, $1, [0.4, 0.6, 0.4, 0.6, 0.2, 0.8], 1, 30, 0.2) }
        check("color balance") { adjust_color_balance($0, width, height, $1, [0.2, 0, 0], [0, 0.3, 0], [0, 0, -0.2], 1) }
        check("light and color") { adjust_camera_raw($0, width, height, $1, 1.1, 1, 0.9, 0.5, 20, -30, 30, 10, -10, 20, 10, 0) }
        check("clip overlay") { adjust_camera_raw_clip_overlay($0, width, height, $1, 1, 1) }
        check("effects") {
            #expect(adjust_camera_raw_effects($0, width, height, $1, 40, 40, 30, 50, 1, 50, 50, 20, -40, 50, 0, 50, 20, 0, 1) == 0)
        }
        check("detail") { #expect(adjust_camera_raw_detail($0, width, height, $1, 80, 1.5, 40, 20, 50, 50, 20, 40, 50, 50, 1) == 0) }
        check("sharpen mask") { #expect(adjust_camera_raw_sharpen_mask_overlay($0, width, height, $1, 1.5, 40, 20, 1) == 0) }
        check("optics") {
            #expect(adjust_camera_raw_optics($0, width, height, $1, 1, 1, 30, 50, 0.1, 50, 270, 330, 50, 90, 150, 30, 50, 1) == 0)
        }
        check("calibration") { adjust_camera_raw_calibration($0, width, height, $1, 20, 10, 20, -10, 10, 5, -5, 2) }
    }
}
