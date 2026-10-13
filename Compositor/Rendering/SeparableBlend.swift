import CoreGraphics
import CoreImage

/// The blend modes Core Graphics can't draw, computed by Core Image instead.
///
/// Two kinds end up here. Core Graphics gets Color Burn and Color Dodge wrong: its versions ignore how transparent
/// the source is, so a soft brush comes out with a hard edge. And it has no equivalent at all for Linear Burn,
/// Linear Dodge, Vivid Light, Linear Light, Pin Light, Hard Mix, Subtract or Divide. Either way the layer is drawn
/// into a copy of the canvas, blended there, and the result put back.
nonisolated enum SeparableBlend {
    /// Whether this mode has to be composited through a surface rather than drawn straight on.
    static func needsSurface(_ mode: LayerBlendMode) -> Bool { mode.coreImageFilter != nil }
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Core Image works in a linear space unless told otherwise, and these two modes are not separable from
    // the gamma they are computed in: over 40% grey, an 80% grey layer dodges to 62% instead of Photoshop's
    // 100%, and burns to 0% instead of 25%. The blend has to happen in the same sRGB the canvas is in.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space])

    /// Draws one layer into `context` in `mode`. `body` draws it as it would be drawn normally, into a context laid
    /// out exactly like `context`. Only a bitmap-backed context can be read back, so anywhere else this reports
    /// false and the caller draws with Core Graphics as before.
    ///
    /// Only the part of the context its clip can reach is read back, blended and put back: every mode here works
    /// pixel by pixel, and a canvas redraw usually covers a small dirty rect of a large surface.
    static func draw(_ mode: LayerBlendMode, in context: CGContext, body: (CGContext) -> Void) -> Bool {
        guard let name = mode.coreImageFilter, context.data != nil, context.width > 0, context.height > 0,
              let filter = CIFilter(name: name) else { return false }
        let full = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        // In the bitmap's pixels, origin at the bottom left: through the CTM, which is what gets undone to put the
        // result back. (`convertToDeviceSpace` measures from the top instead.)
        let frame = context.boundingBoxOfClipPath.applying(context.ctm).integral.intersection(full)
        guard !frame.isNull, !frame.isEmpty else { return true }
        guard let backdrop = backdrop(of: context, in: frame),
              let surface = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height), bitsPerComponent: 8,
                                      bytesPerRow: Int(frame.width) * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        // The same placement as the canvas it will be blended into, moved so the frame's corner is the origin.
        surface.translateBy(x: -frame.minX, y: -frame.minY)
        surface.concatenate(context.ctm)
        body(surface)
        guard let source = surface.makeImage() else { return false }
        filter.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter.setValue(CIImage(cgImage: backdrop), forKey: kCIInputBackgroundImageKey)
        let local = CGRect(origin: .zero, size: frame.size)
        guard let output = filter.outputImage,
              let blended = ciContext.createCGImage(output, from: local, format: .RGBA8, colorSpace: space) else { return false }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.setBlendMode(.copy)
        context.setAlpha(1)
        context.draw(blended, in: frame)
        context.restoreGState()
        return true
    }

    /// A copy of the context's pixels inside `frame` (bitmap pixels, bottom-left origin). Copying just those rows
    /// leaves the context alone: `makeImage` would share its memory, and the draw back into it would then copy
    /// the whole surface.
    private static func backdrop(of context: CGContext, in frame: CGRect) -> CGImage? {
        guard let data = context.data, context.bitsPerPixel % 8 == 0, let colorSpace = context.colorSpace else { return nil }
        let bytesPerPixel = context.bitsPerPixel / 8
        let width = Int(frame.width), height = Int(frame.height)
        let rowBytes = width * bytesPerPixel
        // Memory runs top row first.
        let top = context.height - Int(frame.maxY)
        var copy = Data(count: rowBytes * height)
        copy.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(base + row * rowBytes,
                       data + (top + row) * context.bytesPerRow + Int(frame.minX) * bytesPerPixel, rowBytes)
            }
        }
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: context.bitsPerComponent,
                       bitsPerPixel: context.bitsPerPixel, bytesPerRow: rowBytes, space: colorSpace,
                       bitmapInfo: context.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
