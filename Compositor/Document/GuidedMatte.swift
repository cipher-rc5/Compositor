import CoreGraphics
import Foundation

/// Guided filtering (He, Sun & Tang): a mask pulled onto the edges of the image it came from, which is what recovers
/// hair and fur that a segmentation model cuts straight through. Core Image's own `CIGuidedFilter` does nothing on
/// this system and its edge-preserving upsample barely moves the mask, so this does the arithmetic directly.
nonisolated enum GuidedMatte {
    /// `mask` refined by `guide` (both 0–1, the same size). A bigger radius reaches further for detail; `epsilon`
    /// decides how much of an edge in the guide counts, so a small one follows fine strands. In C
    /// (`MattePixels.c`): it makes a dozen passes over every pixel.
    static func filter(mask: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) throws -> [Float] {
        let count = width * height
        guard width > 0, height > 0, radius >= 0, mask.count == count, guide.count == count else { throw ExportError.render }
        var result = [Float](repeating: 0, count: count)
        let status = mask.withUnsafeBufferPointer { mask in
            guide.withUnsafeBufferPointer { guide in
                result.withUnsafeMutableBufferPointer { out in
                    matte_guided_filter(mask.baseAddress, guide.baseAddress, width, height, radius, epsilon, out.baseAddress)
                }
            }
        }
        guard status == 0 else { throw MagicWand.Failure.memory }
        return result
    }

    /// The gray levels of `image` drawn at `width` × `height`, as 0–1.
    static func levels(of image: CGImage, width: Int, height: Int) throws -> [Float] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * context.bytesPerRow
            for x in 0..<width { result[y * width + x] = Float(bytes[row + x]) / 255 }
        }
        return result
    }

    /// 0–1 levels back to a gray image.
    static func image(_ levels: [Float], width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw ExportError.render }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for y in 0..<height {
            let row = y * context.bytesPerRow
            for x in 0..<width { bytes[row + x] = UInt8(min(255, max(0, levels[y * width + x] * 255 + 0.5))) }
        }
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// `mask` refined against `guide`, both full size. Done on a copy no larger than `limit` on its longest side
    /// (the radius shrinks with it), then drawn back up: fine detail comes from the guide either way, and a preview
    /// stays quick to redraw while a slider moves.
    static func refine(mask: CGImage, guide: CGImage, radius: Double, limit: CGFloat) throws -> CGImage {
        let full = CGSize(width: mask.width, height: mask.height)
        let factor = min(1, limit / max(full.width, full.height))
        let width = max(1, Int((full.width * factor).rounded())), height = max(1, Int((full.height * factor).rounded()))
        let steps = max(1, Int((radius * Double(factor)).rounded()))
        let refined = try filter(mask: try levels(of: mask, width: width, height: height),
                             guide: try levels(of: guide, width: width, height: height),
                             width: width, height: height, radius: steps, epsilon: 1e-4)
        let small = try image(refined, width: width, height: height)
        guard width != Int(full.width) || height != Int(full.height) else { return small }
        guard let context = CGContext(data: nil, width: Int(full.width), height: Int(full.height), bitsPerComponent: 8,
                                      bytesPerRow: Int(full.width), space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(origin: .zero, size: full))
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
}
