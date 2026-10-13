import AppKit

extension CanvasView {
    /// How far, in points per frame, the view pans toward a pointer at `point`: nothing well inside the canvas,
    /// speeding up from the last few points before the edge to however far past it the pointer has gone.
    private func marqueeAutoscrollDelta(at point: CGPoint) -> CGSize {
        let rect = visibleRect, margin: CGFloat = 12
        func speed(_ past: CGFloat) -> CGFloat { past <= 0 ? 0 : min(40, 2 + past * 0.4) }
        let left = speed(rect.minX + margin - point.x), right = speed(point.x - (rect.maxX - margin))
        let top = speed(rect.minY + margin - point.y), bottom = speed(point.y - (rect.maxY - margin))
        // Pointer past the right edge: the document slides left to bring what's beyond into view.
        return CGSize(width: left - right, height: top - bottom)
    }
    func updateMarqueeAutoscroll(at point: CGPoint) {
        marqueeAutoscrollPoint = point
        guard marqueeAutoscrollDelta(at: point) != .zero else { stopMarqueeAutoscroll(); return }
        guard marqueeAutoscroll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMarqueeAutoscroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        marqueeAutoscroll = timer
    }
    private func stepMarqueeAutoscroll() {
        let marquee = session.lassoDraft.map { $0.kind == .rectangle || $0.kind == .ellipse } == true
        guard let point = marqueeAutoscrollPoint, let document = session.document,
              marquee || selectionDragStart != nil else { stopMarqueeAutoscroll(); return }
        let delta = marqueeAutoscrollDelta(at: point)
        guard delta != .zero else { stopMarqueeAutoscroll(); return }
        session.viewport.translate(by: delta)
        // The pointer hasn't moved, but the document has under it: the box's corner, or the moved selection, follows.
        if selectionDragStart != nil { dragSelection(to: point, flags: NSEvent.modifierFlags) }
        else { dragMarqueeDraft(to: session.viewport.documentPoint(from: point, documentSize: document.size), flags: NSEvent.modifierFlags) }
        synchronizeDisplay()
    }
    /// Moves a dragged selection so the pixel grabbed sits under `point`. Shift keeps the move on one axis:
    /// whichever way the drag has gone further.
    func dragSelection(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let start = selectionDragStart, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
        if flags.contains(.shift) {
            if abs(offset.width) >= abs(offset.height) { offset.height = 0 } else { offset.width = 0 }
        }
        session.moveSelection(by: offset)
    }
    func stopMarqueeAutoscroll() {
        marqueeAutoscroll?.invalidate()
        marqueeAutoscroll = nil
        marqueeAutoscrollPoint = nil
    }

    /// Reshapes the Marquee draft. Option subtracts (chosen at the press), so it never draws from the
    /// center. Shift squares the box — except a Shift already held when the drag began, which chose Add,
    /// until it has been let go and pressed again, as in Photoshop.
    func dragMarqueeDraft(to pixel: CGPoint, flags: NSEvent.ModifierFlags) {
        if !flags.contains(.shift) { marqueeConstrainArmed = true }
        marqueeDragPixel = pixel
        session.dragMarquee(to: pixel, square: marqueeConstrainArmed && flags.contains(.shift), fromCenter: false)
    }

    /// Freehand starts an outline to drag. Polygonal adds a corner per click and closes on
    /// a click near the first corner or a double-click. Modifiers at the first click pick
    /// the mode: Shift adds, Option subtracts.
    func lassoMouseDown(at point: CGPoint, event: NSEvent) {
        guard let document = session.document else { return }
        // A Shift held at the press means Add; for the Marquee it squares only once pressed afresh.
        marqueeConstrainArmed = !event.modifierFlags.contains(.shift)
        marqueeDragPixel = nil
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        guard let draft = session.lassoDraft, draft.kind == .polygonal else {
            // Cmd-drag inside the selection cuts and moves its pixels (Photoshop's temporary Move tool).
            if event.modifierFlags.contains(.command), session.canMoveSelection(at: pixel) {
                if session.beginPixelMove(duplicate: event.modifierFlags.contains(.option)) {
                    pixelDragStart = pixel
                    pixelDragCursor(duplicate: event.modifierFlags.contains(.option)).set()
                } else { NSSound.beep() }
                return
            }
            let mode = session.selectionMode(shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
            // In New mode, dragging inside the selection moves its outline instead of drawing.
            if mode == .replace, session.canMoveSelection(at: pixel), session.beginSelectionMove() {
                selectionDragStart = pixel
                Self.moveSelectionCursor.set()
                return
            }
            if session.tool == .wand, session.wandMode == .object {
                Task { await session.selectObject(at: pixel, mode: mode); synchronizeDisplay(); refreshLassoCursor() }
                return
            }
            if session.tool == .wand {
                Task { await session.magicWand(at: pixel, mode: mode); synchronizeDisplay(); refreshLassoCursor() }
                return
            }
            session.beginLasso(at: pixel, mode: mode)
            synchronizeDisplay()
            return
        }
        let first = session.viewport.viewPoint(from: draft.points[0], documentSize: document.size)
        if event.clickCount >= 2 || (draft.points.count >= 3 && hypot(point.x - first.x, point.y - first.y) <= 8) {
            session.finishLasso()
        } else {
            session.extendLasso(to: pixel)
        }
        synchronizeDisplay()
    }
}
