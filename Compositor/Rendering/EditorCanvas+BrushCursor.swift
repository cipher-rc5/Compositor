import AppKit

extension CanvasView {
    func updateBrushCursor() {
        let shows = session.tool.isBrushTool && !spaceHeld && !picking && middlePanPoint == nil
        let diameter = session.brushStroke?.settings.diameter ?? session.brushSettings.diameter
        // Clone Stamp also marks where it is copying from and, between strokes, previews inside
        // the circle what a click would stamp there.
        var sample: CGPoint?
        var preview: CGImage?
        if shows, session.tool == .cloneStamp, let pointer = brushPointer, let document = session.document {
            let point = session.viewport.documentPoint(from: pointer, documentSize: document.size)
            if let source = session.cloneSamplePoint(for: point) {
                sample = session.viewport.viewPoint(from: source, documentSize: document.size)
            }
            if session.brushStroke == nil, !optionHeld, let offset = session.cloneStrokeOffset(at: point) {
                preview = clonePreview(center: CGPoint(x: point.x + offset.width, y: point.y + offset.height),
                                       diameter: diameter, document: document)
            }
        }
        brushCursor.update(point: shows ? brushPointer : nil, diameter: max(1, diameter * session.viewport.pointsPerPixel),
                           sample: sample, preview: preview, previewOpacity: session.brushSettings.opacity,
                           tip: preview == nil ? nil : cloneTip(diameter: diameter, hardness: session.brushSettings.hardness),
                           hardness: brushTipDrag?.hardnessShown == true ? session.brushSettings.hardness : nil)
    }

    /// One click's coverage at the current brush size and hardness, painted by the brush engine
    /// itself, so the preview softens exactly as a click would. Rebuilt only when they change.
    private func cloneTip(diameter: CGFloat, hardness: CGFloat) -> CGImage? {
        if let cache = cloneTipCache, cache.diameter == diameter, cache.hardness == hardness { return cache.image }
        var image: CGImage?
        let side = max(1, Int(diameter.rounded(.up)))
        let size = CGSize(width: side, height: side)
        let settings = BrushSettings(diameter: diameter, hardness: hardness, red: 1, green: 1, blue: 1)
        if let stroke = try? BrushStroke(layer: ImageLayer(name: "Tip", blankSize: size), mask: false, settings: settings, canvas: size),
           (try? stroke.append(CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2))) != nil,
           (try? stroke.flush()) != nil,
           let painted = try? stroke.paintSnapshot(),
           let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            BrushRaster.draw(painted.asset.image, in: painted.bounds, mask: false, context: context)
            image = context.makeImage()
        }
        cloneTipCache = (diameter, hardness, image)
        return image
    }

    struct ClonePreviewKey: Equatable {
        let center: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let revision: Int
        let undoCount: Int
        let allLayers: Bool
        let layerID: UUID?
    }

    /// What a Clone Stamp click would copy into the brush circle: the source around `center`
    /// (document pixels), rendered for just that area at screen resolution and reused until the
    /// pointer, zoom, brush, or document changes.
    private func clonePreview(center: CGPoint, diameter: CGFloat, document: CanvasDocument) -> CGImage? {
        let scale = session.viewport.pointsPerPixel * session.viewport.backingScale
        let key = ClonePreviewKey(center: center, diameter: diameter, scale: scale, revision: session.brushRevision,
                                  undoCount: session.history.undoCount, allLayers: session.cloneSettings.sampleAllLayers,
                                  layerID: session.activeLayerID)
        if let cache = clonePreviewCache, cache.key == key { return cache.image }
        let side = min(1024, max(1, Int((diameter * scale).rounded(.up))))
        var image: CGImage?
        if diameter > 0, let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            let perPixel = CGFloat(side) / diameter
            context.scaleBy(x: perPixel, y: perPixel)
            context.translateBy(x: diameter / 2 - center.x, y: diameter / 2 - center.y)
            context.interpolationQuality = .medium
            if session.cloneSettings.sampleAllLayers {
                session.drawLiveComposite(document, in: context)
            } else if let layer = session.activeLayer, let source = layer.asset?.image {
                let transform = session.displayedTransform(for: layer)
                LayerRenderer.draw(source, transform: transform, center: transform.center, in: context)
            }
            image = context.makeImage()
        }
        clonePreviewCache = (key, image)
        return image
    }
    func handleRightMouseDown(with event: NSEvent) {
        guard session.tool.isBrushTool, session.brushStroke == nil, session.warpStroke == nil, !spaceHeld else {
            super.rightMouseDown(with: event); return
        }
        let point = convert(event.locationInWindow, from: nil)
        brushTipDrag = (point, session.brushSettings.diameter, session.brushSettings.hardness, event.modifierFlags.contains(.shift))
        brushPointer = point
        updateBrushCursor()
    }
    func handleRightMouseDragged(with event: NSEvent) {
        guard let drag = brushTipDrag else { super.rightMouseDragged(with: event); return }
        brushTipDrag?.hardnessShown = event.modifierFlags.contains(.shift)
        let dx = convert(event.locationInWindow, from: nil).x - drag.start.x
        if event.modifierFlags.contains(.shift) {
            // The full range across 200 points.
            session.brushSettings.hardness = min(1, max(0, drag.hardness + dx / 200))
            session.brushSettings.diameter = drag.diameter
        } else {
            // The circle's edge follows the pointer: each point moved widens the radius by a point on screen.
            let perPixel = max(0.0001, session.viewport.pointsPerPixel)
            session.brushSettings.diameter = min(2000, max(1, (drag.diameter + 2 * dx / perPixel).rounded()))
            session.brushSettings.hardness = drag.hardness
        }
        brushPointer = drag.start
        updateBrushCursor()
    }
    func handleRightMouseUp(with event: NSEvent) {
        guard brushTipDrag != nil else { super.rightMouseUp(with: event); return }
        brushTipDrag = nil
        brushPointer = convert(event.locationInWindow, from: nil)
        updateBrushCursor()
    }
}
