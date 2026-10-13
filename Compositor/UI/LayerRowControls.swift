import AppKit

/// An effect belongs visually to its layer but has its own selection and visibility control.
final class LayerEffectRow: NSView, NSDraggingSource {
    weak var session: EditorSession?
    let layerID: UUID
    let kind: LayerEffectKind
    private var copyDown: NSEvent?
    private let eye = NSButton()
    private let label: NSTextField
    init(session: EditorSession, layerID: UUID, kind: LayerEffectKind, enabled: Bool, indent: CGFloat) {
        self.session = session; self.layerID = layerID; self.kind = kind
        label = NSTextField(labelWithString: kind.rawValue)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        eye.isBordered = false
        eye.image = NSImage(systemSymbolName: enabled ? "eye" : "eye.slash", accessibilityDescription: nil)
        eye.imagePosition = .imageOnly
        eye.contentTintColor = .secondaryLabelColor
        eye.target = self; eye.action = #selector(toggle)
        eye.isEnabled = session.canEditLayers
        eye.setAccessibilityLabel((enabled ? "Hide " : "Show ") + kind.rawValue)
        label.font = .systemFont(ofSize: 11)
        label.textColor = enabled ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        for view in [eye, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            eye.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38 + indent),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 20), eye.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: eye.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        toolTip = "Click to select; double-click to edit; Option-drag to copy " + kind.rawValue.lowercased()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(kind.rawValue + " effect")
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.option), !flags.contains(.command) { return self }
        return eye.frame.contains(local) ? eye : self
    }
    func select(editing: Bool) {
        session?.selectEffect(kind, on: layerID, editing: editing)
        var ancestor = superview
        while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
        if let ancestor { window?.makeFirstResponder(ancestor) }
        updateSelection()
    }
    override func mouseDown(with event: NSEvent) {
        copyDown = nil
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command), session?.canEditLayers == true {
            copyDown = event
        } else { select(editing: event.clickCount > 1) }
    }
    override func mouseUp(with event: NSEvent) {
        if copyDown != nil { copyDown = nil; select(editing: false) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down = copyDown else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy >= 9 else { return }
        copyDown = nil
        guard event.modifierFlags.contains(.option), session?.canEditLayers == true else { return }
        let item = NSPasteboardItem()
        item.setString(layerID.uuidString + ":" + kind.rawValue, forType: NativeLayerList.Coordinator.effectType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let snapshot = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            snapshot.addRepresentation(rep)
        }
        dragging.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [dragging], event: down, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { select(editing: false); return true }
    @objc private func toggle() { session?.toggleEffect(kind, on: layerID) }
    func updateSelection() {
        let selected = session?.selectedEffect == LayerEffectSelection(layerID: layerID, kind: kind)
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : NSColor.clear.cgColor
    }
}

/// Select on mouse-down, then let the table retain native drag and multiselect tracking.
final class LayerThumbnailButton: NSButton, NSDraggingSource {
    /// The row's layer, for a mask thumbnail's Option-drag.
    var layerID: UUID?
    var isMaskTarget = false { didSet { updateTrackingAreas() } }
    /// Image thumbnails also load a selection on Cmd-click (masks always do).
    var loadsSelection = false { didSet { updateTrackingAreas() } }
    var cmdClickLoads: Bool { isMaskTarget || loadsSelection }
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    private var modifierMonitor: Any?

    // Mask thumbnails show the load-selection cursor while hovered with Cmd held.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard cmdClickLoads else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                         .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard cmdClickLoads else { return }
        hovering = true
        if modifierMonitor == nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                self.updateCursor(event.modifierFlags)
                DispatchQueue.main.async { [weak self] in self?.updateCursor(NSEvent.modifierFlags) }
                return event
            }
        }
        updateCursor(event.modifierFlags)
    }
    override func mouseMoved(with event: NSEvent) { if hovering { updateCursor(event.modifierFlags) } }
    override func cursorUpdate(with event: NSEvent) {
        if hovering { updateCursor(event.modifierFlags) } else { super.cursorUpdate(with: event) }
    }
    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        // The list decides what the cursor is anywhere else in the row; leaving a thumbnail is not a reason to
        // drop the clipping or duplicate cursor it is showing.
        var ancestor = superview
        while ancestor != nil && !(ancestor is LayerTableView) { ancestor = ancestor?.superview }
        if let table = ancestor as? LayerTableView { table.refreshClippingCursor(NSEvent.modifierFlags) }
        else { NSCursor.arrow.set() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
    }
    private func updateCursor(_ flags: NSEvent.ModifierFlags) {
        guard hovering, isEnabled else { return }
        if flags.contains(.option), !flags.contains(.command) {
            var ancestor = superview
            while ancestor != nil && !(ancestor is LayerTableView) { ancestor = ancestor?.superview }
            (ancestor as? LayerTableView)?.refreshClippingCursor(flags)
            return
        }
        (flags.contains(.command) ? CanvasView.loadSelectionCursor : NSCursor.arrow).set()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableView) { ancestor = ancestor?.superview }
        guard let table = ancestor as? NSTableView else { super.mouseDown(with: event); return }
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
            if isMaskTarget, !isHidden { dragMaskCopy(event); return }
            table.mouseDown(with: event)
            return
        }
        if cmdClickLoads && event.modifierFlags.contains(.command) {
            // Cmd-click on a thumbnail loads a selection; elsewhere in the row it multi-selects.
            _ = target?.perform(isMaskTarget ? #selector(LayerCell.loadMaskSelection) : #selector(LayerCell.loadLayerSelection))
            return
        }
        if isMaskTarget && event.modifierFlags.contains(.shift) {
            sendAction(action, to: target)
            return
        }
        if event.modifierFlags.intersection([.command, .shift]).isEmpty { sendAction(action, to: target) }
        table.mouseDown(with: event)
    }
}

extension LayerThumbnailButton {
    /// Option-drag from a mask thumbnail carries a copy of the mask to another row; a click without a drag just
    /// selects the mask.
    fileprivate func dragMaskCopy(_ down: NSEvent) {
        guard let window, let layerID else { return }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { sendAction(action, to: target); return }
            let dx = event.locationInWindow.x - down.locationInWindow.x, dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy >= 9 else { continue }
            let item = NSPasteboardItem()
            item.setString(layerID.uuidString, forType: NativeLayerList.Coordinator.maskType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let snapshot = NSImage(size: bounds.size)
            if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: rep)
                snapshot.addRepresentation(rep)
            }
            dragging.setDraggingFrame(bounds, contents: snapshot)
            beginDraggingSession(with: [dragging], event: down, source: self)
            return
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
