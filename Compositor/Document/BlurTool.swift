import AppKit
import CoreImage

/// What a Blur stroke softens, captured on the main actor so it can be rendered on any thread (see `render`).
nonisolated struct BlurSampleSource: Sendable {
    let width: Int
    let height: Int
    let sigma: Double
    /// The mask, where it sits, and its thumbnail (for the tone it keeps past its pixels); nil for the layer's pixels.
    var mask: (image: CGImage, placement: LayerTransform, thumbnail: CGImage)?
    var layer: (image: CGImage, transform: LayerTransform)?

    /// The sample at document size. Throws when it can't be made, which on a large canvas is usually memory.
    func render() throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        if let mask {
            let context = try BrushRaster.context(width: width, height: height, mask: true)
            // Past its pixels a mask keeps its edge tone, so blurring near its edge doesn't pull in the wrong one.
            context.setFillColor(gray: LayerMask.background(of: mask.thumbnail), alpha: 1)
            context.fill(extent)
            // Coverage only adds white, so the mask's own area starts black.
            let placement = mask.placement
            context.saveGState()
            context.translateBy(x: placement.center.x, y: placement.center.y)
            context.rotate(by: placement.radians)
            context.scaleBy(x: placement.flipX ? -1 : 1, y: placement.flipY ? 1 : -1)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: -placement.size.width / 2, y: -placement.size.height / 2,
                                width: placement.size.width, height: placement.size.height))
            context.restoreGState()
            LayerRenderer.drawCoverage(mask.image, transform: placement, in: context)
            guard let sharp = context.makeImage() else { throw ExportError.render }
            let soft = CIImage(cgImage: sharp).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            return try PixelAdjust.render(soft, width: sharp.width, height: sharp.height, isMask: true)
        }
        guard let layer else { throw ExportError.render }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        LayerRenderer.draw(layer.image, transform: layer.transform, center: layer.transform.center, in: context)
        guard let sharp = context.makeImage() else { throw ExportError.render }
        // Clamped like the mask: past the canvas's edge the blur reads the edge pixels again rather than
        // transparency, so a layer that reaches the edge doesn't fade out there.
        let soft = CIImage(cgImage: sharp).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        return try PixelAdjust.render(soft, width: sharp.width, height: sharp.height, isMask: false)
    }
}

extension EditorSession {
    /// What a Blur stroke paints: the active layer (or, with `mask`, its mask) as the canvas shows it, at document
    /// size, softened by an amount that follows the brush size. It is taken when the stroke starts, so going over an
    /// area again in a new stroke softens it further, as in Photoshop. Only captured here; `render` draws and
    /// softens it, off the main thread for a stroke (see `beginBrush`).
    func blurSource(_ document: CanvasDocument, mask: Bool = false) throws -> BlurSampleSource {
        guard let layer = activeLayer else { throw ExportError.render }
        var source = BlurSampleSource(width: document.width, height: document.height,
                                      sigma: min(30, max(1.5, Double(brushSettings.diameter) / 10)))
        if mask {
            guard let owned = layer.mask else { throw ExportError.render }
            source.mask = (owned.asset.image, layer.maskTransform, owned.asset.thumbnail)
        } else {
            guard let image = layer.asset?.image else { throw ExportError.render }
            source.layer = (image, displayedTransform(for: layer))
        }
        return source
    }

    /// The Blur sample made at once, on the calling thread.
    func blurSample(_ document: CanvasDocument, mask: Bool = false) throws -> CGImage {
        try blurSource(document, mask: mask).render()
    }
}
