import Foundation
import Testing
@testable import Compositor

/// The C kernels behind Spot Healing, the Magic Wand and the brushes, at the edges of what they're given: images one
/// pixel wide, nothing to work on, and rows padded past the image.
struct PixelKernelEdgeTests {
    /// Opaque gray stripes, `stride` bytes per row.
    private func stripes(width: Int, height: Int, stride: Int? = nil) -> [UInt8] {
        let stride = stride ?? width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let gray: UInt8 = (x + y) % 3 == 0 ? 90 : 140
                for k in 0..<3 { bytes[y * stride + x * 4 + k] = gray }
                bytes[y * stride + x * 4 + 3] = 255
            }
        }
        return bytes
    }

    private func isPremultiplied(_ rgba: [UInt8]) -> Bool {
        // A loop rather than one chained expression, which Swift 6.3 can't type-check in reasonable time.
        for index in Swift.stride(from: 0, to: rgba.count, by: 4) {
            let alpha = rgba[index + 3]
            if rgba[index] > alpha || rgba[index + 1] > alpha || rgba[index + 2] > alpha { return false }
        }
        return true
    }

    // MARK: Spot Healing

    @Test(arguments: [0, 1, 2])
    func healingNothingLeavesTheImageAlone(mode: Int32) {
        let original = stripes(width: 24, height: 16)
        var rgba = original
        let coverage = [UInt8](repeating: 0, count: 24 * 16)
        #expect(spot_heal(&rgba, 24 * 4, coverage, 24, 24, 16, 1, mode, 1) == 0)
        #expect(rgba == original)
    }

    @Test(arguments: [0, 1, 2])
    func healingOnePixelWideImagesStaysInBounds(mode: Int32) {
        for (width, height) in [(1, 1), (1, 20), (20, 1)] {
            var rgba = stripes(width: width, height: height)
            // The middle of a long image, so there is a ring of texture around the spot; all of a single pixel.
            let coverage = (0..<(width * height)).map { width * height == 1 || (8..<12).contains($0) ? UInt8(255) : 0 }
            #expect(spot_heal(&rgba, width * 4, coverage, width, width, height, 1, mode, 9) == 0, "\(width)×\(height)")
            #expect(isPremultiplied(rgba), "\(width)×\(height)")
        }
    }

    @Test(arguments: [0, 1, 2])
    func healingReadsCoverageByItsOwnStride(mode: Int32) {
        let width = 30, height = 20, coverageStride = 32
        var coverage = [UInt8](repeating: 0, count: coverageStride * height)
        // The row padding is marked, the image itself isn't: nothing is in the spot.
        for y in 0..<height { coverage[y * coverageStride + width] = 255; coverage[y * coverageStride + width + 1] = 255 }
        let original = stripes(width: width, height: height, stride: width * 4 + 12)
        var rgba = original
        #expect(spot_heal(&rgba, width * 4 + 12, coverage, coverageStride, width, height, 1, mode, 3) == 0)
        #expect(rgba == original)
        // A real spot, read through the same padded rows, heals only where it is.
        for y in 8..<12 { for x in 12..<16 { coverage[y * coverageStride + x] = 255 } }
        for y in 8..<12 { for x in 12..<16 { rgba[y * (width * 4 + 12) + x * 4] = 255; rgba[y * (width * 4 + 12) + x * 4 + 1] = 0 } }
        #expect(spot_heal(&rgba, width * 4 + 12, coverage, coverageStride, width, height, 1, mode, 3) == 0)
        for y in 0..<height {
            for x in 0..<width where !((8..<12).contains(y) && (12..<16).contains(x)) {
                let index = y * (width * 4 + 12) + x * 4
                #expect(Array(rgba[index..<(index + 4)]) == Array(original[index..<(index + 4)]), "(\(x), \(y)) changed outside the spot")
            }
        }
        #expect(rgba[10 * (width * 4 + 12) + 13 * 4] < 200, "the red spot wasn't healed")
    }

    @Test func coverageBoundsOfNothingIsEmpty() {
        var bounds = [Int](repeating: 7, count: 4)
        heal_coverage_bounds([UInt8](repeating: 0, count: 5), 1, 5, 1, &bounds)
        #expect(bounds == [0, 0, 0, 0])
        var column = [UInt8](repeating: 0, count: 5)
        column[3] = 9
        heal_coverage_bounds(column, 1, 5, 1, &bounds)
        #expect(bounds == [0, 3, 1, 4])
    }

    // MARK: Magic Wand

    @Test func wandOnOnePixelWideImages() {
        // A column of grays 90, 140, 140, 90, 140, 140, 90, with row 3's red taken out.
        var rgba = stripes(width: 1, height: 7)
        rgba[3 * 4] = 0
        var mask = [UInt8](repeating: 7, count: 7)
        #expect(wand_mask(rgba, 1, 7, 4, 0, 0, 2, 0, 1, &mask) == 0) // A 5 × 5 average, clipped to rows 0–2, matches no pixel.
        #expect(wand_mask(rgba, 1, 7, 4, 0, 1, 0, 0, 1, &mask) == 2) // A point sample at row 1 runs down into row 2.
        #expect(mask == [0, 255, 255, 0, 0, 0, 0])
        #expect(wand_mask(rgba, 1, 7, 4, 0, 0, 0, 60, 1, &mask) == 3) // Tolerant: down to the odd pixel out.
        #expect(mask == [255, 255, 255, 0, 0, 0, 0])
        #expect(wand_mask(rgba, 1, 7, 4, 0, 0, 0, 60, 0, &mask) == 6) // Not contiguous: past it too.
        #expect(wand_mask(rgba, 1, 7, 4, 0, 9, 0, 60, 1, &mask) == 0) // Seed off the image.
        #expect(mask.allSatisfy { $0 == 0 })
        var single = [UInt8](repeating: 1, count: 1)
        #expect(wand_mask(stripes(width: 1, height: 1), 1, 1, 4, 0, 0, 3, 0, 1, &single) == 1 && single == [255])
    }

    @Test func tracingNothingGivesNoLoops() {
        for (width, height) in [(1, 1), (1, 9), (9, 1), (6, 4)] {
            var points: UnsafeMutablePointer<Int32>?, loops: UnsafeMutablePointer<Int32>?
            var pointCount = 5, loopCount = 5
            let status = wand_trace([UInt8](repeating: 0, count: width * height), width, height, &points, &pointCount, &loops, &loopCount)
            defer { free(points); free(loops) }
            #expect(status == 0 && pointCount == 0 && loopCount == 0, "\(width)×\(height)")
        }
    }

    @Test func tracingOnePixelWideMasks() throws {
        // A whole column, and a single pixel, are each one clockwise rectangle.
        for (mask, width, height, corners) in [([UInt8](repeating: 255, count: 5), 1, 5, [0, 0, 1, 0, 1, 5, 0, 5]),
                                               ([255], 1, 1, [0, 0, 1, 0, 1, 1, 0, 1]),
                                               ([0, 0, 255, 0], 4, 1, [2, 0, 3, 0, 3, 1, 2, 1])] {
            var points: UnsafeMutablePointer<Int32>?, loops: UnsafeMutablePointer<Int32>?
            var pointCount = 0, loopCount = 0
            #expect(wand_trace(mask, width, height, &points, &pointCount, &loops, &loopCount) == 0)
            defer { free(points); free(loops) }
            let traced = try #require(points)
            #expect(loopCount == 1 && (0..<(pointCount * 2)).map { Int(traced[$0]) } == corners, "\(width)×\(height)")
        }
    }

    @Test func thresholdingPicksTheChannelAndSide() {
        // RGBA rows padded by 4 bytes; alpha is every 4th byte from offset 3.
        let width = 3, height = 2, stride = width * 4 + 4
        var rgba = [UInt8](repeating: 200, count: stride * height)
        let alphas: [UInt8] = [0, 127, 128, 255, 10, 200]
        for (index, alpha) in alphas.enumerated() { rgba[(index / width) * stride + (index % width) * 4 + 3] = alpha }
        var mask = [UInt8](repeating: 1, count: width * height)
        let count = rgba.withUnsafeBufferPointer { wand_threshold($0.baseAddress! + 3, width, height, stride, 4, 128, 0, &mask) }
        #expect(count == 3 && mask == [0, 0, 255, 255, 0, 255])
        let below = rgba.withUnsafeBufferPointer { wand_threshold($0.baseAddress! + 3, width, height, stride, 4, 128, 1, &mask) }
        #expect(below == 3 && mask == [255, 255, 0, 0, 255, 0])
        var nothing = [UInt8](repeating: 1, count: 0)
        #expect(wand_threshold(rgba, 0, 0, stride, 4, 128, 0, &nothing) == 0)
    }

    // MARK: Brushes

    @Test func alphaBoundsOfNothingAndOfAColumn() {
        var bounds = [Int](repeating: 9, count: 4)
        brush_alpha_bounds([UInt8](repeating: 0, count: 4 * 6), 1, 6, 4, &bounds)
        #expect(bounds == [0, 0, 0, 0])
        var column = [UInt8](repeating: 0, count: 4 * 6)
        column[2 * 4 + 3] = 1
        column[4 * 4 + 3] = 255
        brush_alpha_bounds(column, 1, 6, 4, &bounds)
        #expect(bounds == [0, 2, 1, 5])
        brush_alpha_bounds([], 0, 0, 0, &bounds)
        #expect(bounds == [0, 0, 0, 0])
    }

    @Test func alphaRoundTripsOnAOnePixelWideLayer() {
        var rgba: [UInt8] = [50, 25, 0, 100, 0, 0, 0, 0, 255, 255, 255, 255]
        var alpha = [UInt8](repeating: 0, count: 3)
        layer_extract_alpha(rgba, 4, &alpha, 1, 1, 3)
        #expect(alpha == [100, 0, 255])
        layer_unpremultiply_opaque(&rgba, 4, 1, 3)
        #expect(rgba == [128, 64, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255])
        layer_restore_alpha(&rgba, 4, alpha, 1, 1, 3)
        #expect(rgba == [50, 25, 0, 100, 0, 0, 0, 0, 255, 255, 255, 255])
    }

    @Test func dabsOnOnePixelImagesAndFullyOffTheImage() {
        var pixel: [UInt8] = [10, 20, 30, 40]
        var carried = [Float](repeating: -1, count: 3 * 3 * 4)
        warp_pick_up(pixel, 1, 1, 4, 0, 0, 1, &carried)
        #expect(carried.enumerated().allSatisfy { $0.offset / 4 == 4 ? $0.element == Float(pixel[$0.offset % 4]) : $0.element == 0 })
        warp_smudge(&pixel, 1, 1, 4, 5, 5, 1, 1, 0, 1, &carried) // Wholly off the image: nothing to do.
        #expect(pixel == [10, 20, 30, 40])
        var scratch: UnsafeMutablePointer<UInt8>?, size = 0
        defer { free(scratch) }
        // One pixel has nothing to sample between, so a push leaves it as it is.
        #expect(warp_push(&pixel, 1, 1, 4, 0, 0, 3, 3, 0, 2, 2, &scratch, &size) == 0)
        #expect(pixel == [10, 20, 30, 40])
        #expect(warp_push(&pixel, 1, 1, 4, -50, -50, 3, 3, 0, 2, 2, &scratch, &size) == 0)
        #expect(pixel == [10, 20, 30, 40])
    }
}
