import CoreGraphics
import Testing
@testable import Compositor

/// The guided filter moved to C (`MattePixels.c`); it must give exactly what the Swift it replaced gave.
struct GuidedMatteTests {
    /// The Swift as it was, kept to check the C against.
    private enum Reference {
        static func box(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
            let span = Float(radius * 2 + 1)
            var pass = [Float](repeating: 0, count: width * height)
            for y in 0..<height {
                let row = y * width
                var sum: Float = 0
                for x in -radius...radius { sum += source[row + min(width - 1, max(0, x))] }
                for x in 0..<width {
                    pass[row + x] = sum / span
                    sum -= source[row + min(width - 1, max(0, x - radius))]
                    sum += source[row + min(width - 1, max(0, x + radius + 1))]
                }
            }
            var result = [Float](repeating: 0, count: width * height)
            for x in 0..<width {
                var sum: Float = 0
                for y in -radius...radius { sum += pass[min(height - 1, max(0, y)) * width + x] }
                for y in 0..<height {
                    result[y * width + x] = sum / span
                    sum -= pass[min(height - 1, max(0, y - radius)) * width + x]
                    sum += pass[min(height - 1, max(0, y + radius + 1)) * width + x]
                }
            }
            return result
        }

        static func filter(mask: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) -> [Float] {
            let count = width * height
            let meanGuide = box(guide, width: width, height: height, radius: radius)
            let meanMask = box(mask, width: width, height: height, radius: radius)
            var squares = [Float](repeating: 0, count: count), products = [Float](repeating: 0, count: count)
            for i in 0..<count { squares[i] = guide[i] * guide[i]; products[i] = guide[i] * mask[i] }
            let meanSquares = box(squares, width: width, height: height, radius: radius)
            let meanProducts = box(products, width: width, height: height, radius: radius)
            var slope = [Float](repeating: 0, count: count), offset = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let variance = meanSquares[i] - meanGuide[i] * meanGuide[i]
                let covariance = meanProducts[i] - meanGuide[i] * meanMask[i]
                slope[i] = covariance / (variance + epsilon)
                offset[i] = meanMask[i] - slope[i] * meanGuide[i]
            }
            let meanSlope = box(slope, width: width, height: height, radius: radius)
            let meanOffset = box(offset, width: width, height: height, radius: radius)
            var result = [Float](repeating: 0, count: count)
            for i in 0..<count { result[i] = min(1, max(0, meanSlope[i] * guide[i] + meanOffset[i])) }
            return result
        }
    }

    /// Levels 0–1 in steps of 1/255, as `GuidedMatte.levels` reads them, with hard edges and soft ramps.
    private func levels(width: Int, height: Int, seed: UInt32) -> [Float] {
        var state = seed
        func next() -> UInt32 { state = state &* 1_664_525 &+ 1_013_904_223; return state >> 8 }
        return (0..<(width * height)).map { index in
            let x = index % width, y = index / width
            let base = (x * 7 + y * 3) % 256 < 128 ? 0 : 255
            let noisy = next() % 3 == 0 ? Int(next() % 256) : base
            return Float(noisy) / 255
        }
    }

    @Test(arguments: [(1, 1, 0), (1, 7, 2), (9, 1, 3), (5, 4, 0), (31, 17, 1), (40, 33, 4), (16, 12, 30)])
    func theFilterMatchesTheSwiftItReplacedBitForBit(_ shape: (Int, Int, Int)) throws {
        let (width, height, radius) = shape
        for (seed, epsilon) in [(UInt32(3), Float(1e-4)), (11, 1e-2), (29, 0.5)] {
            let mask = levels(width: width, height: height, seed: seed)
            let guide = levels(width: width, height: height, seed: seed &+ 100)
            let fast = try GuidedMatte.filter(mask: mask, guide: guide, width: width, height: height, radius: radius, epsilon: epsilon)
            let slow = Reference.filter(mask: mask, guide: guide, width: width, height: height, radius: radius, epsilon: epsilon)
            #expect(fast.map(\.bitPattern) == slow.map(\.bitPattern), "\(width)×\(height) r\(radius) seed \(seed)")
        }
    }

    @Test func mismatchedSizesAreRefusedRatherThanRead() {
        #expect(throws: (any Error).self) {
            try GuidedMatte.filter(mask: [0, 1], guide: [0, 1, 0], width: 2, height: 1, radius: 1, epsilon: 1e-4)
        }
        #expect(throws: (any Error).self) {
            try GuidedMatte.filter(mask: [], guide: [], width: 0, height: 0, radius: 1, epsilon: 1e-4)
        }
    }
}
