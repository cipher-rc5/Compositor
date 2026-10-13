import AppKit
import Testing
@testable import Compositor

@MainActor
struct MaskTracingTests {
    /// A gray image from rows of 0/1 (1 is white), top row first.
    private func mask(_ rows: [[UInt8]]) throws -> CGImage {
        let width = rows[0].count, height = rows.count
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for (y, row) in rows.enumerated() { for (x, value) in row.enumerated() { bytes[y * context.bytesPerRow + x] = value * 255 } }
        return try #require(context.makeImage())
    }

    /// Which pixels `path` fills with the winding rule, without antialiasing — what a selection from it covers.
    private func filled(_ path: CGPath, width: Int, height: Int) throws -> [[UInt8]] {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setShouldAntialias(false)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath(using: .winding)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<height).map { y in (0..<width).map { x in bytes[y * context.bytesPerRow + x] > 127 ? 1 : 0 } }
    }

    private func blob(width: Int, height: Int, seed: UInt32) -> [[UInt8]] {
        var state = seed
        return (0..<height).map { _ in
            (0..<width).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return state >> 30 == 0 ? 0 : 1
            }
        }
    }

    @Test func aRectangleTracesToItsFourCorners() throws {
        var rows = [[UInt8]](repeating: [UInt8](repeating: 0, count: 10), count: 8)
        for y in 2..<5 { for x in 3..<7 { rows[y][x] = 1 } }
        let path = try #require(try MaskTracing.whitePixels(in: mask(rows)))
        #expect(path.boundingBoxOfPath == CGRect(x: 3, y: 2, width: 4, height: 3))
        var points = 0
        path.applyWithBlock { if $0.pointee.type != .closeSubpath { points += 1 } }
        #expect(points == 4)
        #expect(try filled(path, width: 10, height: 8) == rows)
    }

    /// Holes, islands in holes, pixels touching only at a corner, and noise all come back exactly as the mask.
    @Test func outlinesFillBackToExactlyTheMask() throws {
        let ring: [[UInt8]] = [
            [1, 1, 1, 1, 1, 1, 1],
            [1, 0, 0, 0, 0, 0, 1],
            [1, 0, 1, 1, 1, 0, 1],
            [1, 0, 1, 0, 1, 0, 1],
            [1, 0, 1, 1, 1, 0, 1],
            [1, 0, 0, 0, 0, 0, 1],
            [1, 1, 1, 1, 1, 1, 1],
        ]
        let corners: [[UInt8]] = [[1, 0, 1], [0, 1, 0], [1, 0, 1]]
        for rows in [ring, corners, blob(width: 37, height: 29, seed: 4), blob(width: 1, height: 13, seed: 8), blob(width: 13, height: 1, seed: 2)] {
            let image = try mask(rows)
            let white = try #require(try MaskTracing.whitePixels(in: image))
            #expect(try filled(white, width: image.width, height: image.height) == rows)
            let dark = try #require(try MaskTracing.darkPixels(in: image))
            #expect(try filled(dark, width: image.width, height: image.height) == rows.map { $0.map { 1 - $0 } })
        }
    }

    @Test func nothingToTraceIsNil() throws {
        let black = try mask([[0, 0, 0], [0, 0, 0]])
        #expect(try MaskTracing.whitePixels(in: black) == nil)
        let full = try #require(try MaskTracing.darkPixels(in: black))
        #expect(full.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 3, height: 2))
        #expect(try MaskTracing.whitePixels(in: mask([[0]])) == nil)
        #expect(try MaskTracing.darkPixels(in: mask([[1]])) == nil)
    }

    @Test func opaquePixelsReadsAlphaAtHalf() throws {
        let context = try BrushRaster.context(width: 4, height: 1, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for (x, alpha) in [UInt8(0), 127, 128, 255].enumerated() { bytes[x * 4 + 3] = alpha }
        let image = try #require(context.makeImage())
        let path = try #require(try MaskTracing.opaquePixels(in: image))
        #expect(path.boundingBoxOfPath == CGRect(x: 2, y: 0, width: 2, height: 1))
    }
}
