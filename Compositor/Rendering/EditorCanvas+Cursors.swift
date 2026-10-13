import AppKit

extension CanvasView {
    private var lassoCursor: NSCursor { lassoCursor(flags: NSEvent.modifierFlags) }

    /// In New mode over the selection, the move cursor; otherwise the badged crosshair. Over the
    /// selection, Cmd shows the scissors (cut and move its pixels) and Cmd-Option the copy cursor.
    /// `location` is the pointer in view coordinates, when an event supplies it.
    func lassoCursor(flags: NSEvent.ModifierFlags, at location: CGPoint? = nil) -> NSCursor {
        let mode = session.lassoCursorMode(shift: flags.contains(.shift), option: flags.contains(.option))
        if selectionDragStart != nil { return Self.moveSelectionCursor }
        if pixelDragStart != nil { return pixelDragCursor(duplicate: session.pixelMove?.duplicate == true) }
        if flags.contains(.command) || mode == .replace, let document = session.document,
           let point = location ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) }),
           session.canMoveSelection(at: session.viewport.documentPoint(from: point, documentSize: document.size)) {
            return flags.contains(.command) ? pixelDragCursor(duplicate: flags.contains(.option)) : Self.moveSelectionCursor
        }
        if session.tool == .wand, session.wandMode == .wand { return Self.wandCursors[mode] ?? .crosshair }
        let icon: SelectionIcon = session.tool == .wand ? .objectSelection : session.tool == .marquee
            ? (session.marqueeKind == .ellipse ? .ellipseMarquee : .rectangleMarquee)
            : (session.lassoKind == .polygonal ? .polygonalLasso : .freehandLasso)
        return Self.selectionCursors[icon]?[mode] ?? .crosshair
    }

    /// Cmd-dragging the selection cuts and moves its pixels (scissors); with Option it copies them.
    func pixelDragCursor(duplicate: Bool) -> NSCursor { duplicate ? Self.duplicateCursor : Self.movePixelsCursor }

    /// Re-applies the lasso cursor now if the pointer is over the canvas.
    func refreshLassoCursor(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        window?.invalidateCursorRects(for: self)
        guard session.tool.isSelectionTool, !spaceHeld, !picking, let window,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        lassoCursor(flags: flags).set()
    }

    func addCanvasCursorRects() {
        if let dragCursor { addCursorRect(bounds, cursor: dragCursor); return }
        if picking { addCursorRect(bounds, cursor: Self.eyedropperCursor); return }
        if session.hueTargeting { addCursorRect(bounds, cursor: .resizeLeftRight); return }
        if session.tool.isSelectionTool, !spaceHeld { addCursorRect(bounds, cursor: lassoCursor); return }
        // Clone Stamp with a source: the brush circle, its preview and the source crosshair stand in
        // for the cursor. Holding Option to pick a new source brings the crosshair back.
        if session.tool == .cloneStamp, session.cloneSource != nil, !optionHeld, !spaceHeld {
            addCursorRect(bounds, cursor: Self.hiddenCursor)
            return
        }
        let cursor: NSCursor = spaceHeld || session.tool == .hand ? .openHand
            // The Move tool's cursor depends on the pointer (handles, Option to duplicate), so match it here.
            : session.tool == .move ? window.map { transformCursor(at: convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? .arrow
            : session.tool == .type ? .iBeam
            : session.tool == .idle ? .arrow
            : session.tool == .zoom ? (optionHeld ? Self.zoomOutCursor : Self.zoomInCursor)
            : .crosshair
        addCursorRect(bounds, cursor: cursor)
        guard session.tool == .crop, !spaceHeld else { return }
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        for region in transformOverlay.cropResizeRegions.reversed() {
            let rect = region.rect.intersection(bounds)
            if !rect.isEmpty && !rect.isNull {
                addCursorRect(rect, cursor: .frameResize(position: positions[region.index], directions: [.inward, .outward]))
            }
        }
    }
    func handleCursorUpdate(with event: NSEvent) {
        if picking { Self.eyedropperCursor.set() }
        else if session.tool.isSelectionTool, !spaceHeld { lassoCursor.set() }
        // Cursor-update events carry no modifier flags (AppKit sends one after every key change), so read
        // the keys as they are now; the event's flags would undo Option's duplicate cursor straight away.
        else if session.tool == .move { updateTransformCursor(at: convert(event.locationInWindow, from: nil), flags: NSEvent.modifierFlags) }
        else { super.cursorUpdate(with: event) }
    }
    func updateTransformCursor(at point: CGPoint, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        transformCursor(at: point, flags: flags).set()
    }

    /// The Move tool's cursor at a view point. Option over anything a drag would move shows the
    /// copy cursor, since Option-dragging duplicates the layer. Guides sit under handles, over a layer drag.
    private func transformCursor(at point: CGPoint, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> NSCursor {
        if let dragCursor { return dragCursor }
        guard !spaceHeld else { return .openHand }
        guard !session.isProjectBusy, !session.isImporting else { return .arrow }
        let duplicate = flags.contains(.option)
        if let geometry = transformOverlay.geometry, let hit = geometry.hit(point) {
            switch hit {
            case .resize(let index):
                // Distorting (Cmd held, or already distorted) moves corners freely: the white arrow says so.
                let distorting = session.transformEdit?.corners != nil || flags.contains(.command)
                return distorting ? Self.distortCursor : geometry.resizeCursor(for: index)
            case .rotate: return Self.rotationCursor
            case .move: return duplicate ? Self.duplicateCursor : Self.moveCursor
            case .distort: return Self.distortCursor
            }
        }
        if let guide = session.hitGuide(at: point) {
            return guide.axis == .vertical ? .resizeLeftRight : .resizeUpDown
        }
        guard pressMovesLayer(at: point, flags: flags) else { return .arrow }
        return duplicate ? Self.duplicateCursor : Self.moveCursor
    }
}
