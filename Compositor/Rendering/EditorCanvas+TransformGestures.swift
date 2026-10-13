import AppKit

extension CanvasView {
    /// Whether a press that misses the transform handles would drag a layer (see `transformPressLayer`).
    func pressMovesLayer(at point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        guard let document = session.document else { return false }
        return transformPressLayer(at: session.viewport.documentPoint(from: point, documentSize: document.size), flags: flags) != nil
    }

    /// The layer a press that misses the transform handles drags, and whether it was picked from under
    /// the pointer. Cmd picks the layer under the pointer; otherwise the active layer, unless auto-select
    /// finds another layer there — including one stacked above a selected background that also contains
    /// the press. A press on empty canvas still drags the active layer: it need not land inside the layer's bounds.
    private func transformPressLayer(at pixel: CGPoint, flags: NSEvent.ModifierFlags) -> (id: UUID, picked: Bool)? {
        guard session.canEditLayers || session.transformEdit != nil, let document = session.document else { return nil }
        let underPointer = document.renderLayers.reversed().first { $0.asset != nil && $0.transform.contains(pixel) }?.id
        let active = session.activeLayer.flatMap { layer in
            layer.asset != nil && !layer.isGroup && document.effectiveVisibleIDs.contains(layer.id) ? layer : nil
        }
        let picks = session.transformEdit == nil
        if flags.contains(.command), picks, let underPointer { return (underPointer, true) }
        // Several layers selected, or a folder: a press inside their box drags them all, and so does one outside it
        // unless auto-select finds a layer there.
        if session.transformsAsGroup, let id = session.activeLayerID {
            let box = session.transformEdit?.draft ?? session.groupTransformBox
            if box?.contains(pixel) == true || !(picks && session.transformAutoSelect) || underPointer == nil { return (id, false) }
        }
        if let active, session.editedTransform(for: active).contains(pixel) {
            // `renderLayers` is bottom to top, so a later index is painted above. Prefer that layer
            // when auto-select is on; a full-canvas background contains every press, and keeping it
            // would hide a foreground layer stacked on top of it.
            if picks, session.transformAutoSelect, let underPointer, underPointer != active.id,
               let top = document.renderLayers.lastIndex(where: { $0.id == underPointer }),
               let current = document.renderLayers.lastIndex(where: { $0.id == active.id }),
               top > current {
                return (underPointer, true)
            }
            return (active.id, false)
        }
        if picks, session.transformAutoSelect || flags.contains(.command), let underPointer { return (underPointer, true) }
        return active.map { ($0.id, false) }
    }

    func beginCropDrag(at point: CGPoint) {
        guard let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        let rect = session.visibleCropRect ?? CGRect(origin: pixel, size: .zero)
        let mode: CropDrag.Mode
        if let region = transformOverlay.cropResizeRegions.first(where: { $0.rect.contains(point) }) {
            mode = .resize(region.index)
        } else if session.cropRect?.contains(pixel) == true,
                  rect != CGRect(origin: .zero, size: document.size) { mode = .move }
        else { mode = .create; session.cropRect = nil }
        cropDrag = CropDrag(start: pixel, original: rect, mode: mode)
        let targets = session.cropSnapTargets()
        cropSnap = CropSnap(xs: targets.xs, ys: targets.ys, tolerance: Self.cropSnapDistance / max(session.viewport.pointsPerPixel, 0.0001))
        dragCursor = .current
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
    }

    /// Reshapes the crop frame for the pointer at `point` (view coordinates): Option keeps the frame's center
    /// fixed, and edges snap to nearby layer and canvas edges unless Control is held.
    func dragCrop(_ drag: CropDrag, to point: CGPoint, flags: NSEvent.ModifierFlags, documentSize: CGSize) {
        let pixel = session.viewport.documentPoint(from: point, documentSize: documentSize)
        let symmetric = flags.contains(.option)
        var next = drag.updated(to: pixel, ratio: session.cropRatio, symmetric: symmetric)
        if let cropSnap, session.snapEnabled, !flags.contains(.control) {
            next = cropSnap.apply(next, drag: drag, point: pixel, ratio: session.cropRatio, symmetric: symmetric)
        }
        if CropGeometry.valid(next) { session.cropRect = next }
    }

    func beginGuideDrag(at point: CGPoint) -> Bool {
        guard session.canEditGuides, let guide = session.hitGuide(at: point) else { return false }
        session.beginGuideMove(guide)
        guideDragging = true
        dragCursor = guide.axis == .vertical ? .resizeLeftRight : .resizeUpDown
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
        return true
    }

    /// Released on the top or left ruler strip, which sits just outside the canvas.
    func isOverRuler(_ point: CGPoint) -> Bool {
        session.showsRulers && (point.x < 0 || point.y < 0)
    }

    func documentPosition(axis: CanvasGuide.Axis, at point: CGPoint) -> Double? {
        guard let document = session.document else { return nil }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        return Double(axis == .vertical ? pixel.x : pixel.y)
    }

    func beginTransformDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard session.canEditLayers || session.transformEdit != nil, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        var mode = transformOverlay.geometry?.hit(point)
        if mode == nil, let target = transformPressLayer(at: pixel, flags: modifiers) {
            // Cmd-Shift-click adds the layer under the pointer to the selection (and takes it out again); Cmd-click
            // on its own selects just that one.
            if target.picked, modifiers.contains(.command), modifiers.contains(.shift) {
                session.extendSelection(with: target.id)
            } else if target.picked {
                session.selectLayer(target.id)
            }
            mode = .move
        }
        guard var mode else { return }
        if case .move = mode { duplicatesTransformOnDrag = modifiers.contains(.option) }
        else { duplicatesTransformOnDrag = false }
        if session.transformEdit == nil { session.beginTransform(persistent: false) }
        // Cmd-dragging a handle distorts, as in Photoshop; once distorted, handles keep distorting.
        if case .resize(let index) = mode, modifiers.contains(.command) || session.transformEdit?.corners != nil {
            session.beginDistort()
            if session.transformEdit?.corners != nil { mode = .distort(index) }
        }
        guard let transform = session.transformEdit?.draft else { return }
        transformDrag = TransformDrag(original: transform, start: pixel, mode: mode, originalCorners: session.transformEdit?.corners)
        switch mode {
        case .resize(let index): dragCursor = transformOverlay.geometry?.resizeCursor(for: index) ?? .arrow
        case .rotate: dragCursor = Self.rotationCursor
        case .move: dragCursor = duplicatesTransformOnDrag ? Self.duplicateCursor : Self.moveCursor
        case .distort: dragCursor = Self.distortCursor
        }
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
    }

    func releaseDragCursor() {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, dragCursor != nil else { return }
        dragCursor = nil
        cursorLockWindow?.enableCursorRects()
        cursorLockWindow?.invalidateCursorRects(for: self)
        cursorLockWindow = nil
        if let window, session.tool == .move {
            updateTransformCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
}
