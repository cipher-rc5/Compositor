import AppKit

extension CanvasView {
    private func blendMode(of layer: ImageLayer) -> LayerBlendMode {
        layer.id == normalBlendLayerID ? .normal : session.displayedBlendMode(for: layer)
    }

    /// The transparency checkerboard's two grays, 10-point squares, the lighter one at the canvas's top-left corner.
    static let checkerSquare: CGFloat = 10
    static let checkerDark = NSColor(white: 0.30, alpha: 1)
    static let checkerLight = NSColor(white: 0.35, alpha: 1)
    /// Two squares by two, a pixel to the point, tiled when drawn: one draw per redraw where filling every light
    /// square took thousands at low zoom on a big window. (Core Graphics tiles a 2 × 2 gray image wrongly, dropping
    /// a row, so the tile isn't made any smaller.)
    private static let checkerTile: CGImage? = {
        let side = Int(checkerSquare) * 2, square = checkerSquare
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(checkerDark.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // Drawn into the flipped canvas the tile comes out upside down, so the light squares go bottom-left and
        // top-right here to land top-left and bottom-right on screen.
        context.setFillColor(checkerLight.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: square, height: square))
        context.fill(CGRect(x: square, y: square, width: square, height: square))
        return context.makeImage()
    }()

    /// Fills the context's clip with the checkerboard, its squares counted from `origin` (in a flipped context, as the
    /// canvas's is).
    static func drawCheckerboard(anchoredAt origin: CGPoint, in context: CGContext) {
        guard let tile = checkerTile else {
            context.setFillColor(checkerDark.cgColor)
            context.fill(context.boundingBoxOfClipPath)
            return
        }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(tile, in: CGRect(origin: origin, size: CGSize(width: checkerSquare * 2, height: checkerSquare * 2)),
                     byTiling: true)
        context.restoreGState()
    }

    func drawCanvas(_ dirtyRect: NSRect) {
        defer { drawTextBoxDraft() }
        NSColor(white: 0.105, alpha: 1).setFill()
        dirtyRect.fill()
        guard let document = session.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let pixels = renderBounds ?? CGRect(origin: .zero, size: document.size)
        let rect = CGRect(origin: session.viewport.viewPoint(from: pixels.origin, documentSize: document.size),
                          size: CGSize(width: pixels.width * session.viewport.pointsPerPixel,
                                       height: pixels.height * session.viewport.pointsPerPixel))
        guard rect.intersects(bounds), rect.intersects(dirtyRect) else { return }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 14,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(NSColor(white: 0.26, alpha: 1).cgColor)
        context.fill(rect)
        context.restoreGState()
        context.saveGState()
        context.clip(to: rect.intersection(dirtyRect))
        let visible = rect.intersection(bounds).intersection(dirtyRect)
        Self.drawCheckerboard(anchoredAt: rect.origin, in: context)
        if session.viewport.zoom >= Self.crispZoom, !visible.isNull, !visible.isEmpty {
            drawDocumentPixels(covering: visible, clippedTo: pixels, document: document, in: context)
        } else {
            // Draw native-resolution assets into the same document/view mapping as navigation.
            // The AppKit view is flipped; flip each image locally so its top stays at the top.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawLayers(document, scale: session.viewport.pointsPerPixel,
                       center: { self.session.viewport.viewPoint(from: $0, documentSize: document.size) }, in: context)
            context.endTransparencyLayer()
        }
        if session.showsPixelGrid, session.viewport.zoom >= Self.pixelGridZoom, !visible.isNull, !visible.isEmpty {
            drawPixelGrid(in: visible, document: document, context: context)
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        context.setLineWidth(1 / session.viewport.backingScale)
        context.stroke(rect)
    }

    /// From 200% (2 screen pixels per document pixel) the canvas shows hard-edged
    /// document pixels, as Photoshop does; the pixel grid appears from 800%.
    static let crispZoom: CGFloat = 2
    static let pixelGridZoom: CGFloat = 8

    /// A copy of a layer image sized for how large it lands in `context` (`drawnWidth` in the context's units),
    /// from the shared cache of sharp halvings. Core Graphics resamples the whole source on every draw — a
    /// 4000 px layer costs ~24 ms per frame even when only a small patch is dirty — and blurs big reductions.
    private func displayImage(_ image: CGImage, width drawnWidth: CGFloat, in context: CGContext) -> CGImage {
        DownsampleCache.shared.image(image, drawnAt: drawnWidth * LayerRenderer.deviceScale(of: context) / CGFloat(max(1, image.width)))
    }

    private func drawLayers(_ document: CanvasDocument, scale: CGFloat, center: @escaping (CGPoint) -> CGPoint, in context: CGContext, onSurface: Bool = false) {
        session.effectsPreviews.prepare(layers: document.layers)
        // Color Burn and Color Dodge are blended by hand against the pixels under them, which needs a surface to
        // read back (see SeparableBlend).
        if !onSurface, document.layers.contains(where: { $0.adjustment != nil
            || SeparableBlend.needsSurface(session.displayedBlendMode(for: $0)) }) {
            let visible = document.effectiveVisibleIDs
            let padding = document.layers.filter { visible.contains($0.id) }
                .compactMap(\.adjustment).map(\.samplingMargin).max() ?? 0
            AdjustmentSurface.draw(in: context, padding: padding * scale) {
                self.drawLayers(document, scale: scale, center: center, in: $0, onSurface: true)
            }
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        func drawOwn(_ id: UUID, _ context: CGContext) {
            guard let layer = byID[id], layer.id != session.textDraft?.layerID else { return }
            // A folder the layer sits in dims it along with everything else inside (see LayerOpacity).
            let opacity = layer.effectiveOpacity(in: byID)
            let mode = session.displayedBlendMode(for: layer)
            if SeparableBlend.needsSurface(mode), normalBlendLayerID != id {
                normalBlendLayerID = id
                defer { normalBlendLayerID = nil }
                if SeparableBlend.draw(mode, in: context, body: { drawOwn(id, $0) }) { return }
            }
            let stroke = session.brushStroke?.layer.id == layer.id ? session.brushStroke
                : session.gradientEdit?.raster.layer.id == layer.id ? session.gradientEdit?.raster
                : session.pixelMove?.raster.layer.id == layer.id ? session.pixelMove?.raster : nil
            guard layer.asset != nil || stroke != nil else { return }
            // A gradient line dragged over a layer shown much smaller than its pixels: a reduced picture of the layer
            // under it, until the drag ends and the tiles are painted (see BrushStroke.previewGradient).
            if let edit = session.gradientEdit?.raster, edit.layer.id == layer.id, let preview = edit.gradientPreview {
                let transform = edit.paintTransform
                LayerRenderer.draw(preview, transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            // Smudge or Liquify in progress: the layer as the stroke has reshaped it so far, across the canvas.
            // Drawn as the layer it started from plus copies of the tiles it changed, never the pixels the dabs write.
            if let warp = session.warpStroke, warp.layer.id == layer.id {
                let canvas = LayerTransform(origin: .zero, size: document.size)
                let mask = layer.mask?.clipImage(placement: layer.maskTransform, over: canvas, width: warp.width, height: warp.height, limit: 2048)
                TiledLayerRenderer.drawStroke(width: warp.width, height: warp.height,
                    sourceRect: CGRect(x: 0, y: 0, width: warp.width, height: warp.height),
                    patches: warp.patches, image: warp.base, raster: nil, transform: canvas, center: center(canvas.center),
                    scale: scale, opacity: opacity, blendMode: blendMode(of: layer), mask: mask, in: context)
                return
            }
            // A pending distortion shows the layer warped into its new shape — with its effects warped along with
            // it, so they stay on while the corners move.
            if stroke == nil, layer.effects?.visible.isEmpty == false,
               let effects = session.effectsPreviews.preview(for: layer, mask: layer.mask?.enabledImage,
                    transform: layer.transform, maskPlacement: session.displayedMaskPlacement(for: layer),
                    completion: { [weak self] in self?.needsDisplay = true }),
               let warped = session.distortedEffects(for: layer, effects: effects.image, inset: effects.inset) {
                LayerRenderer.draw(warped.image, transform: warped.transform, center: center(warped.transform.center),
                    scale: scale, opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            if stroke == nil, let distorted = session.distortPreview(for: layer) {
                LayerRenderer.draw(distorted.image, transform: distorted.transform, center: center(distorted.transform.center),
                    scale: scale, opacity: opacity, blendMode: blendMode(of: layer),
                    mask: distorted.mask, in: context)
                return
            }
            // A mask stroke paints the mask's grid; the layer itself stays put.
            let transform = (stroke?.isMask == true ? nil : stroke?.paintTransform) ?? session.displayedTransform(for: layer)
            // A mask placed apart from its layer is resampled into the grid the layer draws in (at most 2048 pixels
            // across while something moves, else about the size it's drawn).
            let mask: CGImage? = {
                guard let owned = layer.mask else { return nil }
                if let distorted = session.maskDistortPreview(for: layer) { return distorted }
                guard let placement = session.displayedMaskPlacement(for: layer) else { return owned.enabledImage }
                let owner = stroke?.layer ?? layer
                let base = stroke == nil ? transform : owner.transform
                let drawn = max(base.size.width, base.size.height) * scale * LayerRenderer.deviceScale(of: context)
                let steady = pow(2, ceil(log2(max(64, drawn))))
                return owned.clipImage(placement: placement, over: base,
                    width: owner.asset?.image.width ?? Int(base.size.width.rounded()),
                    height: owner.asset?.image.height ?? Int(base.size.height.rounded()),
                    limit: session.transformEdit != nil ? min(2048, steady) : steady)
            }()
            // A stroke or drop shadow is drawn around the layer's pixels, on a canvas grown to hold it.
            if stroke == nil, layer.asset != nil,
               let effects = session.effectsPreviews.preview(for: layer, mask: mask, transform: transform,
                    maskPlacement: session.displayedMaskPlacement(for: layer), completion: { [weak self] in
                        self?.needsDisplay = true
                    }) {
                // A seeded preview carries the place it belongs; everything else is the layer's box plus its margin.
                let grown = effects.placement ?? LayerEffectsRenderer.placed(transform, image: effects.image, inset: effects.inset)
                LayerRenderer.draw(effects.image, transform: grown, center: center(grown.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            if stroke == nil, let shaped = session.shapeTransformPreview(for: layer, transform: transform) {
                LayerRenderer.draw(shaped, transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: mask, in: context)
            } else if let stroke, !stroke.isMask {
                // The effects follow the paint: a surface kept at full resolution, redone only where the brush has
                // just been (see LayerEffectsSurface). It already holds the wet pixels with the effects over them —
                // a color overlay and an inner shadow go over the layer, so drawing the paint again on top of it
                // would cover them — so nothing more is drawn for this layer.
                if let surface = strokeSurface(layer: layer, stroke: stroke, mask: mask), let built = surface.image {
                    let grown = LayerEffectsRenderer.placed(transform, image: built, inset: surface.margin)
                    surface.placement = grown
                    LayerRenderer.draw(built, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                    return
                }
                if let effects = session.effectsPreviews.rendered(layer.id) {
                    let grown = effects.placement
                        ?? LayerEffectsRenderer.placed(layer.transform, image: effects.image, inset: effects.inset)
                    LayerRenderer.draw(effects.image, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                }
                // Painting pixels previews exactly as the finished layer will look, with the layer's own
                // sampling, so nothing shifts when a stroke starts or ends (see TiledLayerRenderer).
                let previous = stroke.layer.asset
                TiledLayerRenderer.drawStroke(width: stroke.width, height: stroke.height, sourceRect: stroke.sourceRect,
                    patches: stroke.patches, image: previous?.raster == nil ? previous?.image : nil, raster: previous?.raster,
                    transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            } else if let stroke, let placement = stroke.layer.mask?.placement {
                // A mask on its own placement is painted in its own grid: the layer draws through the mask as the
                // stroke leaves it, resampled into the layer's grid.
                let preview = stroke.placedMaskPreview(placement: placement)
                if let raster = stroke.layer.asset?.raster {
                    TiledLayerRenderer.drawRaster(raster, transform: transform, center: center(transform.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: preview, in: context)
                } else if let image = stroke.layer.asset?.image {
                    LayerRenderer.draw(image, transform: transform, center: center(transform.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: preview, in: context)
                }
            } else if let stroke {
                // Painting the mask shows the layer through the mask as it will be once committed, the same way.
                let previous = stroke.layer.asset
                TiledLayerRenderer.drawMaskStroke(width: stroke.width, height: stroke.height, sourceRect: stroke.sourceRect,
                    patches: stroke.patches, oldMask: stroke.layer.mask?.asset,
                    image: previous?.raster == nil ? previous?.image : nil, raster: previous?.raster,
                    transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), in: context)
            } else if let asset = layer.asset, let raster = asset.raster, session.hueSaturation?.previewImage(for: layer.id) == nil && session.levels?.previewImage(for: layer.id) == nil && session.filterEdit?.previewImage(for: layer.id) == nil {
                TiledLayerRenderer.drawRaster(raster, transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            } else if let image = session.filterEdit?.previewImage(for: layer.id) ?? session.levels?.previewImage(for: layer.id) ?? session.hueSaturation?.previewImage(for: layer.id) ?? layer.asset?.image {
                // LayerRenderer picks a sharp reduction for the image and its mask itself.
                LayerRenderer.draw(image, transform: transform,
                    center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            }
        }
        // The shape being dragged out previews where its layer will go — above the active layer — rather than over
        // everything, so the layers above it cover it as they will once it is made.
        func drawOwnWithDraft(_ id: UUID, _ context: CGContext) {
            drawOwn(id, context)
            guard id == session.activeLayerID else { return }
            drawShapeDraft(scale: scale, center: center, in: context)
        }
        let live = LiveMaskRenderer(bounds: context.boundingBoxOfClipPath, source: { byID[$0]?.maskSourceID }, drawOwn: drawOwnWithDraft)
        live.adjustment = { byID[$0]?.adjustment }
        live.adjustmentOpacity = { byID[$0]?.effectiveOpacity(in: byID) ?? 1 }
        live.adjustmentScale = scale
        let area = context.boundingBoxOfClipPath
        live.adjustmentClip = { [weak self] id, ctx in
            guard let self, let layer = byID[id], layer.mask?.isEnabled == true else { return }
            // Mid-stroke the mask exists only as the edit's tiles, so the adjustment is clipped by those, the same
            // way a folder's mask is — otherwise the stroke would only appear once it was committed.
            if let edit = self.liveMaskEdit(for: id),
               let clip = self.liveFolderMaskClip(edit, area: area, scale: scale, center: center, in: ctx) {
                clip(ctx)
                return
            }
            if let image = layer.mask?.enabledImage {
                FolderMaskClip(image: image, transform: layer.transform).apply(scale: scale, center: center(layer.transform.center), in: ctx)
            }
        }
        live.prepareStacks(document.renderLayers.map(\.id), parent: { byID[$0]?.parentID }, blend: { byID[$0].map { session.displayedBlendMode(for: $0) } ?? .normal })
        FolderMaskClip.draw(document.renderLayers.map(\.id), parent: { byID[$0]?.parentID }, clip: { id in
            guard let folder = byID[id], let mask = folder.mask, mask.isEnabled else { return nil }
            if let edit = liveMaskEdit(for: folder.id),
               let clip = liveFolderMaskClip(edit, area: area, scale: scale, center: center, in: context) {
                return clip
            }
            let transform = session.displayedTransform(for: folder)
            let clip = FolderMaskClip(image: displayImage(mask.asset.image, width: transform.size.width * scale, in: context), transform: transform)
            let origin = center(transform.center)
            return { clip.apply(scale: scale, center: origin, in: $0) }
        }, in: context) { live.drawComposite($0, in: context) }
    }

    /// The shape being dragged out with the Shape tool, drawn in the color it will be made in.
    private func drawShapeDraft(scale: CGFloat, center: (CGPoint) -> CGPoint, in context: CGContext) {
        // A flat or upright line has a box with no height or width, which is not "empty" for this purpose.
        guard let draft = session.shapeDraft,
              draft.kind == .line ? (draft.rect.width > 0 || draft.rect.height > 0) : !draft.rect.isEmpty else { return }
        let middle = center(CGPoint(x: draft.rect.midX, y: draft.rect.midY))
        let rect = CGRect(x: middle.x - draft.rect.width * scale / 2, y: middle.y - draft.rect.height * scale / 2,
                          width: draft.rect.width * scale, height: draft.rect.height * scale)
        context.saveGState()
        context.setFillColor(session.foregroundColor.nsColor.cgColor)
        if draft.kind == .line {
            guard let ends = session.shapeLineEnds else { context.restoreGState(); return }
            let thickness = max(1, CGFloat(session.shapeLineWidth) * scale)
            context.setStrokeColor(session.foregroundColor.nsColor.cgColor)
            context.setLineWidth(thickness)
            context.setLineCap(.round)
            // Exactly the two points being dragged between, so the start never shifts.
            context.move(to: center(ends.start))
            context.addLine(to: center(ends.end))
            context.strokePath()
        } else {
            context.addPath(draft.kind.path(in: rect, cornerRadius: draft.cornerRadius * scale))
            context.fillPath()
        }
        context.restoreGState()
    }

    private func strokeSurface(layer: ImageLayer, stroke: BrushStroke, mask: CGImage?) -> LayerEffectsSurface? {
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else { return nil }
        let grid = CGSize(width: stroke.width, height: stroke.height)
        if strokeSurface?.matches(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect) != true {
            strokeSurface = LayerEffectsSurface(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect)
            // The surface renders off the draw path; redraw where each pass lands.
            strokeSurface?.onUpdate = { [weak self] area in
                guard let self, let document = self.session.document else { return }
                guard let area else { self.needsDisplay = true; return }
                let origin = self.session.viewport.viewPoint(from: area.origin, documentSize: document.size)
                let scale = self.session.viewport.pointsPerPixel
                self.setNeedsDisplay(CGRect(origin: origin, size: CGSize(width: area.width * scale, height: area.height * scale)).insetBy(dx: -2, dy: -2))
            }
        }
        guard let surface = strokeSurface else { return nil }
        surface.update(base: stroke.layer.asset?.image, patches: stroke.patches, mask: mask)
        return surface
    }

    /// The raster edit painting this folder's mask, if one is in progress.
    private func liveMaskEdit(for id: UUID) -> BrushStroke? {
        [session.brushStroke, session.gradientEdit?.raster].compactMap { $0 }.first { $0.layer.id == id && $0.isMask }
    }

    /// While a folder's mask is being painted it exists only as the edit's tiles, so the clip
    /// for the layers inside is rendered from those tiles — just for the area being redrawn,
    /// at the context's device resolution — the same way a layer's own mask is previewed.
    private func liveFolderMaskClip(_ edit: BrushStroke, area: CGRect, scale: CGFloat,
                                    center: (CGPoint) -> CGPoint, in context: CGContext) -> ((CGContext) -> Void)? {
        let rect = area.integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let device = context.convertToDeviceSpace(rect)
        let width = Int(abs(device.width).rounded(.up)), height = Int(abs(device.height).rounded(.up))
        guard width >= 1, height >= 1, width * height <= 64_000_000,
              let coverage = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        // Outside the folder's mask bounds is hidden, as it is for a committed mask.
        coverage.setFillColor(gray: 0, alpha: 1)
        coverage.fill(CGRect(x: 0, y: 0, width: width, height: height))
        coverage.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        coverage.translateBy(x: -rect.minX, y: -rect.minY)
        var transform = edit.paintTransform
        transform.sampling = .nearest
        let base = edit.layer.mask?.asset
        LayerRenderer.drawBrushPreview(base.map { $0.raster == nil ? displayImage($0.image, width: transform.size.width * scale, in: coverage) : $0.image },
            transform: transform, center: center(transform.center), scale: scale, opacity: 1, blendMode: .normal, mask: nil,
            patches: edit.patches, pixelWidth: edit.width, pixelHeight: edit.height, paintingMask: false,
            sourceRect: edit.sourceRect, raster: base?.raster,
            rasterBase: base?.raster.flatMap { raster in raster.base.map { displayImage($0, width: transform.size.width * scale * raster.baseRect.width / CGFloat(max(1, raster.width)), in: coverage) } }, in: coverage)
        guard let image = coverage.makeImage() else { return nil }
        return { target in
            // CGImage rows run top-down; image clipping runs bottom-up in this flipped space.
            target.translateBy(x: 0, y: rect.minY * 2 + rect.height)
            target.scaleBy(x: 1, y: -1)
            target.clip(to: rect, mask: image)
            target.scaleBy(x: 1, y: -1)
            target.translateBy(x: 0, y: -(rect.minY * 2 + rect.height))
        }
    }

    /// Composites just the visible document pixels at 1:1 (the same rendering as export),
    /// then enlarges them without smoothing so each document pixel is a crisp square,
    /// even for scaled or rotated layers. Cost is proportional to what is on screen.
    private func drawDocumentPixels(covering view: CGRect, clippedTo pixels: CGRect, document: CanvasDocument, in context: CGContext) {
        let viewport = session.viewport
        let topLeft = viewport.documentPoint(from: view.origin, documentSize: document.size)
        let bottomRight = viewport.documentPoint(from: CGPoint(x: view.maxX, y: view.maxY), documentSize: document.size)
        let region = CGRect(x: floor(topLeft.x), y: floor(topLeft.y),
                            width: ceil(bottomRight.x) - floor(topLeft.x), height: ceil(bottomRight.y) - floor(topLeft.y))
            .intersection(pixels.integral)
        guard !region.isNull, region.width >= 1, region.height >= 1,
              let raster = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false) else { return }
        drawLayers(document, scale: 1, center: { CGPoint(x: $0.x - region.minX, y: $0.y - region.minY) }, in: raster)
        guard let image = raster.makeImage() else { return }
        let origin = viewport.viewPoint(from: region.origin, documentSize: document.size)
        let target = CGRect(origin: origin, size: CGSize(width: region.width * viewport.pointsPerPixel,
                                                         height: region.height * viewport.pointsPerPixel))
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }

    /// One-screen-pixel lines on document pixel boundaries, over the image only.
    private func drawPixelGrid(in view: CGRect, document: CanvasDocument, context: CGContext) {
        let viewport = session.viewport
        let canvas = CGRect(origin: viewport.viewPoint(from: .zero, documentSize: document.size),
                            size: CGSize(width: document.size.width * viewport.pointsPerPixel,
                                         height: document.size.height * viewport.pointsPerPixel))
        let area = view.intersection(canvas)
        guard !area.isNull, !area.isEmpty else { return }
        let first = viewport.documentPoint(from: area.origin, documentSize: document.size)
        let last = viewport.documentPoint(from: CGPoint(x: area.maxX, y: area.maxY), documentSize: document.size)
        let hairline = 1 / viewport.backingScale
        let path = CGMutablePath()
        for column in stride(from: Int(ceil(first.x)), through: Int(floor(last.x)), by: 1) {
            let x = viewport.viewPoint(from: CGPoint(x: CGFloat(column), y: 0), documentSize: document.size).x
            path.addRect(CGRect(x: x - hairline / 2, y: area.minY, width: hairline, height: area.height))
        }
        for row in stride(from: Int(ceil(first.y)), through: Int(floor(last.y)), by: 1) {
            let y = viewport.viewPoint(from: CGPoint(x: 0, y: CGFloat(row)), documentSize: document.size).y
            path.addRect(CGRect(x: area.minX, y: y - hairline / 2, width: area.width, height: hairline))
        }
        context.saveGState()
        context.addPath(path)
        context.setFillColor(NSColor(white: 0.55, alpha: 0.45).cgColor)
        context.fillPath()
        context.restoreGState()
    }
}
