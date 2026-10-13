import AppKit

final class LayerTableView: NSTableView {
    weak var session: EditorSession?
    private var clippingTracking: NSTrackingArea?
    private var clippingMonitor: Any?
    private var clippingCursorActive = false
    private static func clippingCursor(releasing: Bool) -> NSCursor {
        // A symbol missing from this system leaves the plain arrow rather than a crash.
        guard let arrow = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil),
              let box = NSImage(systemSymbolName: releasing ? "rectangle.badge.minus" : "rectangle.badge.plus",
                                accessibilityDescription: nil) else { return .arrow }
        let image = NSImage(size: NSSize(width: 30, height: 28), flipped: false) { _ in
            func drawOutlined(_ symbol: NSImage, in rect: NSRect) {
                guard let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white])),
                      let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black])) else { return }
                for step in 0..<16 {
                    let angle = CGFloat(step) * .pi / 8
                    white.draw(in: rect.offsetBy(dx: cos(angle), dy: sin(angle)))
                }
                black.draw(in: rect)
            }
            drawOutlined(arrow, in: NSRect(x: 1, y: 11, width: 16, height: 15))
            drawOutlined(box, in: NSRect(x: 10, y: 1, width: 19, height: 17))
            return true
        }
        image.accessibilityDescription = releasing ? "Release clipping mask" : "Create clipping mask"
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 3))
    }
    private static let createClippingCursor = clippingCursor(releasing: false)
    private static let releaseClippingCursor = clippingCursor(releasing: true)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let clippingTracking { removeTrackingArea(clippingTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area); clippingTracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clippingMonitor { NSEvent.removeMonitor(clippingMonitor); self.clippingMonitor = nil }
        if window != nil {
            clippingMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                self.refreshClippingCursor(event.modifierFlags)
                // A modifier change is not a mouse event: AppKit restores its own cursor once this one is handled,
                // so the cursor is worked out again right after, from wherever the pointer is by then.
                DispatchQueue.main.async { [weak self] in self?.refreshClippingCursor(NSEvent.modifierFlags) }
                return event
            }
        }
    }
    /// Keeps the cursor right over the layer list: with Option held, the clipping cursor over the bottom quarter
    /// of a row, as in Photoshop, and the duplicate cursor over the rest of it (a mask thumbnail copies the mask); a thumbnail's own cursor with Command held over
    /// it; otherwise the arrow — even when a
    /// tool's cursor followed the mouse in. `location` is in window coordinates; without one
    /// (a modifier change) the current mouse position is used.
    func refreshClippingCursor(_ flags: NSEvent.ModifierFlags, at location: NSPoint? = nil) {
        guard let window else { return }
        let point = convert(location ?? window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = visibleRect.contains(point)
        guard inside, flags.contains(.option), !flags.contains(.command) else {
            // Outside the list, a modifier change must not touch another view's cursor.
            if clippingCursorActive || (inside && !thumbnailOwnsCursor(at: point, flags: flags)) { NSCursor.arrow.set() }
            clippingCursorActive = false
            return
        }
        clippingCursorActive = true
        (clippingCursor(at: point) ?? .arrow).set()
    }

    /// With Option held, the cursor for whatever is under `point`: the clipping cursor over the bottom of a row,
    /// the duplicate cursor over the rest of it and over a mask thumbnail an Option-drag can copy.
    private func clippingCursor(at point: NSPoint) -> NSCursor? {
        let index = row(at: point)
        guard let session, session.layerRows.indices.contains(index) else { return nil }
        let layer = session.layerRows[index].layer
        if let thumbnail = thumbnail(at: point), thumbnail.isMaskTarget, !thumbnail.isHidden {
            return session.canEditLayers ? CanvasView.duplicateCursor : NSCursor.arrow
        }
        guard isClippingZone(point, row: index) else {
            return session.canEditLayers ? CanvasView.duplicateCursor : NSCursor.arrow
        }
        guard session.canToggleClippingMask(layer.id) else { return NSCursor.arrow }
        return layer.maskSourceID == nil ? Self.createClippingCursor : Self.releaseClippingCursor
    }

    /// Option-click clips along the bottom edge of a row: a fixed strip, not a share of the row's height, so a row
    /// listing several effects keeps the rest of itself free for Option-dragging those effects.
    private static let clippingStrip: CGFloat = 10
    private func isClippingZone(_ point: NSPoint, row: Int) -> Bool {
        guard row >= 0 else { return false }
        if let entries = session?.layerRows, entries.indices.contains(row), entries[row].layer.isGroup == true { return false }
        let rect = rect(ofRow: row)
        return point.y >= rect.maxY - min(Self.clippingStrip, rect.height / 3)
    }
    /// Command held over a thumbnail that loads a selection: that thumbnail shows its cursor.
    private func thumbnailOwnsCursor(at point: NSPoint, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let thumbnail = thumbnail(at: point) else { return false }
        return thumbnail.cmdClickLoads && thumbnail.isEnabled
    }
    /// The layer or mask thumbnail under a point in this view's coordinates, if any.
    private func thumbnail(at point: NSPoint) -> LayerThumbnailButton? {
        guard let superview else { return nil }
        var view = superview.hitTest(convert(point, to: superview))
        while let current = view, current !== self {
            if let thumbnail = current as? LayerThumbnailButton { return thumbnail }
            view = current.superview
        }
        return nil
    }
    override func mouseEntered(with event: NSEvent) { refreshClippingCursor(event.modifierFlags, at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { refreshClippingCursor(event.modifierFlags, at: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { refreshClippingCursor(event.modifierFlags, at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        // Reloading rows (after a brush stroke, say) rebuilds the tracking areas, which sends an exit even though
        // the pointer never left: taking the cursor back then makes it flicker. Only a real exit resets it.
        if let window, visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            refreshClippingCursor(NSEvent.modifierFlags)
            return
        }
        if clippingCursorActive { NSCursor.arrow.set(); clippingCursorActive = false }
    }

    /// Effect rows are interactive subviews. In the clipping zone, Option-click belongs to the table
    /// instead, so the same region that advertises the clipping cursor also handles the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil else { return nil }
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let local = convert(point, from: superview)
        guard flags.contains(.option), !flags.contains(.command),
              isClippingZone(local, row: row(at: local)) else { return hit }
        // Option-dragging a mask thumbnail must still copy its mask.
        var target = hit
        while let view = target, view !== self {
            if let thumbnail = view as? LayerThumbnailButton, thumbnail.isMaskTarget { return hit }
            target = view.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        // Handle clipping before effect selection: effects occupy the lower portion of taller rows.
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command), isClippingZone(point, row: row),
           thumbnail(at: point)?.isMaskTarget != true,
           let entries = session?.layerRows, entries.indices.contains(row) {
            session?.effectSelection = nil
            session?.toggleClippingMask(entries[row].layer.id)
            refreshClippingCursor(event.modifierFlags)
            return
        }
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell,
           cell.selectEffect(at: event.locationInWindow, editing: event.clickCount > 1) {
            window?.makeFirstResponder(self)
            return
        }
        session?.effectSelection = nil
        if row >= 0, event.modifierFlags.intersection([.command, .shift]).isEmpty,
           !(selectedRowIndexes.count > 1 && selectedRowIndexes.contains(row)) {
            // Paint selection before AppKit enters its click/drag tracking loop.
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window?.makeFirstResponder(self)
            displayIfNeeded()
        }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let event = ShortcutSettings.shared.canvasEvent(event) else { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if event.keyCode == 53, session?.transformEdit != nil {
            session?.cancelTransform()
        } else if [36, 76].contains(event.keyCode), let session, session.transformEdit != nil {
            Task { await session.applyTransform() }
        } else if let session, ToolShortcutDispatcher.perform(event, in: session) {
            // Tool keys, Tab, the opacity digits and [ ] { }: the same as on the canvas.
        // With the Move tool the arrows move the layer, as on the canvas, rather than changing the row selection.
        } else if plain, session?.transformEdit != nil || session?.tool == .move, [123, 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session?.nudgeLayer(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if [51, 117].contains(event.keyCode), plain {
            session?.deleteKeyPressed()
        } else { super.keyDown(with: event) }
    }
}
