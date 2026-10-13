import AppKit

final class LayerCell: NSTableCellView, NSTextFieldDelegate {
    /// The layer's own name, without the mark a clipped layer's row shows in front of it.
    private var layerName = ""
    private var renaming = false
    private let eye = EyeSwipeButton()
    private let effectRows = NSStackView()
    private var effectButtons: [LayerEffectRow] = []
    private let disclosure = NSButton()
    private var indentation: NSLayoutConstraint!
    private let thumbnail = LayerThumbnailButton()
    private let maskThumbnail = LayerThumbnailButton()
    private let disabledMaskMark = MaskDisabledMark(labelWithString: "╱")
    /// Between the thumbnails: the chain while layer and mask are linked, empty (still clickable) once unlinked.
    private let linkButton = NSButton()
    private var maskGap: NSLayoutConstraint!
    /// The chain symbol runs corner to corner; turned 45° counterclockwise it stands upright in a narrow gap.
    private static let linkImage: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: "Linked")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)) else { return nil }
        let side = max(symbol.size.width, symbol.size.height)
        let image = NSImage(size: NSSize(width: ceil(side * 0.7), height: ceil(side * 1.45)), flipped: false) { rect in
            let turn = NSAffineTransform()
            turn.translateX(by: rect.midX, yBy: rect.midY)
            turn.rotate(byDegrees: 45)
            turn.concat()
            symbol.draw(in: NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }()
    private var maskWidth: NSLayoutConstraint!
    /// Fixed slots keep names aligned while the thumbnails inside take the canvas's shape.
    private let thumbnailSlot = NSLayoutGuide()
    private let maskSlot = NSLayoutGuide()
    private var thumbnailWidth: NSLayoutConstraint!
    private var thumbnailHeight: NSLayoutConstraint!
    private var maskThumbnailWidth: NSLayoutConstraint!
    private var maskThumbnailHeight: NSLayoutConstraint!
    private let nameLabel = NSTextField(labelWithString: "")
    private let dimensions = NSTextField(labelWithString: "")
    private var layerID: UUID?
    private weak var session: EditorSession?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effectRows.orientation = .vertical
        effectRows.alignment = .leading
        effectRows.spacing = 0
        effectRows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectRows)
        NSLayoutConstraint.activate([
            effectRows.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectRows.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectRows.topAnchor.constraint(equalTo: topAnchor, constant: 52)
        ])
        disclosure.isBordered = false
        disclosure.target = self
        disclosure.action = #selector(toggleExpansion)
        eye.isBordered = false
        eye.target = self
        eye.action = #selector(toggleVisibility)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        for button in [thumbnail, maskThumbnail] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.wantsLayer = true
            button.layer?.cornerRadius = 3
            button.target = self
        }
        thumbnail.action = #selector(selectImage)
        maskThumbnail.action = #selector(selectMask)
        maskThumbnail.isMaskTarget = true
        thumbnail.loadsSelection = true
        thumbnail.toolTip = "Select layer; Cmd-click to select its pixels (Cmd-Shift adds, Cmd-Option subtracts)"
        maskThumbnail.imageScaling = .scaleProportionallyUpOrDown
        linkButton.isBordered = false
        linkButton.title = ""
        linkButton.imagePosition = .imageOnly
        linkButton.contentTintColor = .secondaryLabelColor
        linkButton.target = self
        linkButton.action = #selector(toggleMaskLink)
        disabledMaskMark.font = .systemFont(ofSize: 32, weight: .medium)
        disabledMaskMark.textColor = .systemRed
        disabledMaskMark.isHidden = true
        nameLabel.lineBreakMode = .byTruncatingTail
        // One line, whatever the name holds: a text layer named after a paragraph would otherwise grow the row.
        nameLabel.usesSingleLineMode = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.font = .systemFont(ofSize: 13)
        dimensions.font = .systemFont(ofSize: 10)
        dimensions.textColor = .secondaryLabelColor
        for view in [eye, disclosure, thumbnail, linkButton, maskThumbnail, disabledMaskMark, nameLabel, dimensions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // A faint hairline along the bottom of each row marks where one layer ends and the next begins.
        let edge = RowEdgeLine()
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.heightAnchor.constraint(equalToConstant: 1),
        ])
        indentation = disclosure.leadingAnchor.constraint(equalTo: eye.trailingAnchor, constant: 0)
        addLayoutGuide(thumbnailSlot)
        addLayoutGuide(maskSlot)
        maskWidth = maskSlot.widthAnchor.constraint(equalToConstant: 0)
        maskGap = maskSlot.leadingAnchor.constraint(equalTo: thumbnailSlot.trailingAnchor, constant: 5)
        thumbnailWidth = thumbnail.widthAnchor.constraint(equalToConstant: 36)
        thumbnailHeight = thumbnail.heightAnchor.constraint(equalToConstant: 36)
        maskThumbnailWidth = maskThumbnail.widthAnchor.constraint(equalToConstant: 30)
        maskThumbnailHeight = maskThumbnail.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            eye.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            eye.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            eye.widthAnchor.constraint(equalToConstant: 20), eye.heightAnchor.constraint(equalToConstant: 32),
            indentation,
            disclosure.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            disclosure.widthAnchor.constraint(equalToConstant: 16), disclosure.heightAnchor.constraint(equalToConstant: 24),
            thumbnailSlot.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: -2),
            thumbnailSlot.widthAnchor.constraint(equalToConstant: 36),
            thumbnailSlot.topAnchor.constraint(equalTo: topAnchor), thumbnailSlot.bottomAnchor.constraint(equalTo: topAnchor, constant: 52),
            thumbnail.centerXAnchor.constraint(equalTo: thumbnailSlot.centerXAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            thumbnailWidth, thumbnailHeight,
            maskGap,
            linkButton.centerXAnchor.constraint(equalTo: maskSlot.leadingAnchor, constant: -6.5),
            linkButton.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            linkButton.widthAnchor.constraint(equalToConstant: 9), linkButton.heightAnchor.constraint(equalToConstant: 20),
            maskWidth,
            maskSlot.topAnchor.constraint(equalTo: topAnchor), maskSlot.bottomAnchor.constraint(equalTo: topAnchor, constant: 52),
            maskThumbnail.centerXAnchor.constraint(equalTo: maskSlot.centerXAnchor),
            maskThumbnail.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            maskThumbnailWidth, maskThumbnailHeight,
            disabledMaskMark.centerXAnchor.constraint(equalTo: maskThumbnail.centerXAnchor),
            disabledMaskMark.centerYAnchor.constraint(equalTo: maskThumbnail.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: maskSlot.trailingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            dimensions.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            dimensions.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            dimensions.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3)
        ])
        let menu = NSMenu()
        for (title, action) in [("Rename…", #selector(rename)), ("Hide/Show Layer", #selector(toggleVisibility)),
                                ("Add White Mask", #selector(addWhiteMask)), ("Add Black Mask", #selector(addBlackMask)),
                                ("Enable/Disable Mask", #selector(toggleMask)), ("Delete Mask", #selector(deleteMask)), ("Release Clipping Mask", #selector(removeLiveMask)),
                                ("Move Out of Folder", #selector(moveOut)), ("Delete Layer / Folder", #selector(deleteLayer))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ layer: ImageLayer, enabled: Bool, session: EditorSession, depth: Int, visible: Bool) {
        self.session = session
        for row in effectButtons { effectRows.removeArrangedSubview(row); row.removeFromSuperview() }
        effectButtons = (layer.effects?.kinds ?? []).map { kind in
            let row = LayerEffectRow(session: session, layerID: layer.id, kind: kind,
                                     enabled: layer.effects?.isEnabled(kind) == true,
                                     // The same step in as the row above them, so a clipped layer's effects sit
                                     // under its name rather than out to the left of it.
                                     indent: CGFloat(min(depth, 8)) * 24 + (layer.maskSourceID == nil ? 0 : 24))
            effectRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: effectRows.widthAnchor).isActive = true
            return row
        }
        // A folder steps its contents in by the same distance a clipping mask does; the two add up.
        indentation.constant = CGFloat(min(depth, 8)) * 24 + (layer.maskSourceID == nil ? 0 : 24)
        disclosure.isHidden = !layer.isGroup
        disclosure.isEnabled = enabled
        disclosure.image = NSImage(systemSymbolName: session.collapsedGroupIDs.contains(layer.id) ? "chevron.right" : "chevron.down", accessibilityDescription: "Expand or collapse folder")
        // Pixel layers and masks show the whole canvas with their pixels where they sit, as Photoshop does;
        // editable text, adjustments and folders keep a square icon. Pictures redraw only when what they show changes.
        let canvas = session.document?.size ?? CGSize(width: 1, height: 1)
        let editableText = layer.liveText != nil
        let framed = layer.adjustment == nil && !layer.isGroup && !editableText
        let layerSize = framed ? CanvasThumbnail.fittedSize(canvas: canvas, box: 36) : CGSize(width: 36, height: 36)
        thumbnailWidth.constant = layerSize.width
        thumbnailHeight.constant = layerSize.height
        let key = ThumbnailKey(image: layer.asset.map { ObjectIdentifier($0.thumbnail) }, transform: layer.transform, canvas: canvas, editableText: editableText)
        if layerID != layer.id || thumbnailKey != key {
            thumbnail.image = layer.adjustment.map { Self.adjustmentIcon($0.kind.symbol, description: $0.kind.rawValue, quarterTurnClockwise: $0.kind == .curves) }
                ?? (layer.isGroup ? Self.folderIcon
                    : editableText ? Self.adjustmentIcon("textformat", description: "Editable text")
                    : CanvasThumbnail.layer(layer.asset?.thumbnail, transform: layer.transform, canvas: canvas, box: 36))
            thumbnailKey = key
        }
        let maskSize = CanvasThumbnail.fittedSize(canvas: canvas, box: 30)
        maskThumbnailWidth.constant = maskSize.width
        maskThumbnailHeight.constant = maskSize.height
        let maskKey = ThumbnailKey(image: layer.mask.map { ObjectIdentifier($0.asset.thumbnail) }, transform: layer.maskTransform, canvas: canvas)
        if layerID != layer.id || maskThumbnailKey != maskKey {
            maskThumbnail.image = layer.mask.map { CanvasThumbnail.mask($0.asset.thumbnail, transform: layer.maskTransform, canvas: canvas, box: 30) }
            maskThumbnailKey = maskKey
        }
        layerID = layer.id
        maskThumbnail.isHidden = layer.mask == nil
        maskThumbnail.layerID = layer.id
        maskWidth.constant = layer.mask == nil ? 0 : 30
        disabledMaskMark.isHidden = layer.mask?.isEnabled != false
        thumbnail.isEnabled = !session.showsBusy && !session.isImporting
        maskThumbnail.isEnabled = thumbnail.isEnabled
        let linkable = layer.mask != nil && layer.adjustment == nil && !layer.isGroup
        maskGap.constant = linkable ? 13 : 5
        linkButton.isHidden = !linkable
        linkButton.image = layer.mask?.isLinked == false ? nil : Self.linkImage
        linkButton.isEnabled = thumbnail.isEnabled
        linkButton.toolTip = layer.mask?.isLinked == false ? "Link layer and mask so they move together"
            : "Unlink layer and mask to move or transform them separately"
        linkButton.setAccessibilityLabel(layer.mask?.isLinked == false ? "Link mask: \(layer.name)" : "Unlink mask: \(layer.name)")
        thumbnail.toolTip = editableText ? "Editable text layer" : "Select image pixels"
        maskThumbnail.toolTip = "Select layer mask; Shift-click to enable/disable; Cmd-click to select its black areas (Cmd-Shift adds, Cmd-Option subtracts)"
        thumbnail.setAccessibilityLabel("Select \(editableText ? "text" : "image"): \(layer.name)")
        maskThumbnail.setAccessibilityLabel("Select mask: \(layer.name)")
        updateTarget()
        layerName = layer.name
        // A reused cell must not carry another row's half-finished rename.
        if renaming, layerID != layer.id { restoreLabel() }
        if !renaming { nameLabel.stringValue = (layer.maskSourceID == nil ? "" : "↳ ") + layer.name }
        dimensions.stringValue = layer.liveText != nil ? "Text" : layer.adjustment != nil ? "Adjustment · Double-click to edit" : layer.isGroup ? "Folder" : "\(Int(layer.size.width.rounded())) × \(Int(layer.size.height.rounded())) px"
        if let source = layer.maskSourceID {
            let sourceName = session.document?.layers.first(where: { $0.id == source })?.name ?? "Missing source"
            dimensions.stringValue = "Clipped to \(sourceName)"
            dimensions.toolTip = "Clipping mask based on \(sourceName). Option-click the bottom of its row to release."
        } else { dimensions.toolTip = nil }
        eye.image = NSImage(systemSymbolName: layer.isVisible ? "eye" : "eye.slash", accessibilityDescription: nil)
        eye.setAccessibilityLabel("\(layer.isVisible ? "Hide" : "Show") \(layer.name)")
        eye.isEnabled = enabled
        eye.layerID = layer.id
        eye.session = session
        alphaValue = visible ? 1 : 0.35
    }
    private var maskThumbnailKey: ThumbnailKey?
    func selectEffect(at point: NSPoint, editing: Bool) -> Bool {
        guard let row = effectButtons.first(where: { $0.bounds.contains($0.convert(point, from: nil)) }) else { return false }
        row.select(editing: editing)
        return true
    }
    func updateTarget() {
        effectButtons.forEach { $0.updateSelection() }
        if let layer = session?.document?.layers.first(where: { $0.id == layerID }),
           let sourceID = layer.maskSourceID,
           let source = session?.document?.layers.first(where: { $0.id == sourceID }) {
            dimensions.stringValue = "Clipped to \(source.name)"
            dimensions.toolTip = "Clipping mask based on \(source.name). Option-click the bottom of its row to release."
        }
        let active = session?.activeLayerID == layerID && session?.selectedLayerIDs.count == 1
        let mask = session?.isMaskSelected == true
        thumbnail.layer?.borderColor = NSColor.controlAccentColor.cgColor
        maskThumbnail.layer?.borderColor = NSColor.controlAccentColor.cgColor
        thumbnail.layer?.borderWidth = active && !mask ? 2 : 0
        maskThumbnail.layer?.borderWidth = active && mask ? 2 : 0
    }
    /// Types the layer's name in the row: Return keeps it, Escape leaves it as it was, as does clicking away.
    func beginRenaming() {
        // Not `canEditLayers`: that is false while a rename is pending, which is exactly when this runs.
        guard !renaming, let session, layerID != nil,
              session.document != nil, !session.isProjectBusy, !session.isImporting else { return }
        renaming = true
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.isBezeled = true
        nameLabel.bezelStyle = .roundedBezel
        nameLabel.drawsBackground = true
        nameLabel.delegate = self
        nameLabel.stringValue = layerName
        window?.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }
    private func restoreLabel() {
        renaming = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.delegate = nil
    }
    private func endRenaming(keeping: Bool) {
        guard renaming, let session, let layerID else { return }
        let typed = nameLabel.stringValue
        restoreLabel()
        if keeping { session.renameLayer(layerID, to: typed) }
        if session.renamingLayerID == layerID { session.renamingLayerID = nil }
        // Show whatever name the layer ended up with, marked as the row shows it.
        if let layer = session.document?.layers.first(where: { $0.id == layerID }) {
            layerName = layer.name
            nameLabel.stringValue = (layer.maskSourceID == nil ? "" : "↳ ") + layer.name
        }
        // Hand focus back to the list, so tool shortcuts and the arrow keys work straight away.
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableView) { ancestor = ancestor?.superview }
        if let table = ancestor { window?.makeFirstResponder(table) }
    }
    func controlTextDidEndEditing(_ notification: Notification) { endRenaming(keeping: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRenaming(keeping: false)
        return true
    }
    @objc private func selectImage() { if let layerID { session?.selectLayerTarget(layerID, mask: false) } }
    @objc private func toggleMaskLink() { if let layerID { session?.toggleMaskLink(layerID) } }
    /// Whether a window point lands on one of the row's buttons rather than its name.
    func isOnControl(_ windowPoint: NSPoint) -> Bool {
        [eye, disclosure, thumbnail, linkButton, maskThumbnail].contains { !$0.isHidden && $0.bounds.contains($0.convert(windowPoint, from: nil)) }
    }
    @objc func loadMaskSelection() {
        guard let layerID, let session else { return }
        let mode = Self.loadMode
        Task { await session.loadMaskSelection(layerID: layerID, mode: mode) }
    }
    @objc func loadLayerSelection() {
        guard let layerID, let session else { return }
        let mode = Self.loadMode
        Task { await session.loadLayerSelection(layerID: layerID, mode: mode) }
    }
    /// Cmd-Shift adds and Cmd-Option subtracts, as in Photoshop.
    private static var loadMode: SelectionMode {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        return flags.contains(.option) ? .subtract : flags.contains(.shift) ? .add : .replace
    }
    @objc private func selectMask() {
        guard let layerID else { return }
        session?.selectLayerTarget(layerID, mask: true)
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { session?.toggleLayerMask() }
    }
    @objc private func addWhiteMask() { selectImage(); session?.addMask() }
    @objc private func addBlackMask() { selectImage(); session?.addMask(revealing: false) }
    @objc private func toggleMask() { selectImage(); session?.toggleLayerMask() }
    @objc private func removeLiveMask() { if let layerID { session?.removeLiveMask(from: layerID) } }
    @objc private func deleteMask() { selectImage(); session?.deleteLayerMask() }
    @objc private func toggleExpansion() { if let layerID { session?.toggleGroupExpansion(layerID) } }
    @objc private func moveOut() {
        guard let session, let layerID else { return }
        session.selectLayer(layerID)
        session.moveActiveLayerOutOfGroup()
    }
    private var thumbnailKey: ThumbnailKey?
    @objc private func toggleVisibility() { if let layerID { session?.toggleLayerVisibility(layerID) } }
    /// Delete on a row that's part of a multi-selection removes the whole selection, like the trash button.
    @objc private func deleteLayer() {
        guard let layerID, let session else { return }
        if session.selectedLayerIDs.count > 1, session.selectedLayerIDs.contains(layerID) { session.deleteSelectedLayers() }
        else { session.deleteLayer(layerID) }
    }
    @objc private func rename() {
        guard let session, session.canEditLayers, let layerID else { return }
        session.activeLayerID = layerID
        session.renamingLayerID = layerID
    }
    /// Adjustment layers' icons, a little smaller than a bare symbol shows in the thumbnail (roughly
    /// 15.5 pt instead of 18). Drawn into a 36 pt template image (the thumbnail's size), which the button
    /// shows 1:1 and still tints; 1.21× the symbol's natural size lands the glyph there.
    private static var adjustmentIcons: [String: NSImage] = [:]
    /// The folder symbol at 80% of the size it would fill the thumbnail slot with.
    private static let folderIcon: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder") else { return nil }
        let fit = 36 * 0.8 / max(symbol.size.width, symbol.size.height)
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        let icon = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { bounds in
            symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Folder"
        return icon
    }()
    private static func adjustmentIcon(_ symbolName: String, description: String, quarterTurnClockwise: Bool = false) -> NSImage? {
        if let icon = adjustmentIcons[symbolName] { return icon }
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) else { return nil }
        let size = NSSize(width: symbol.size.width * 1.21, height: symbol.size.height * 1.21)
        let icon = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { bounds in
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            // y points up in this image, so a negative angle turns clockwise.
            if quarterTurnClockwise { transform.rotate(byDegrees: -90) }
            transform.concat()
            symbol.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = description
        adjustmentIcons[symbolName] = icon
        return icon
    }
}

/// One device pixel of faint white, ignored by clicks.
private final class RowEdgeLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// A layer's eye. Pressing it shows or hides the layer; keeping the button down and dragging up or down the list
/// gives every eye passed over the same state, as in Photoshop.
private final class EyeSwipeButton: NSButton {
    var layerID: UUID?
    weak var session: EditorSession?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let layerID, let session, let window,
              let visible = session.beginVisibilitySwipe(layerID) else { return }
        // Showing or hiding a layer reloads its row, which can take this very button out of the list; tracking the
        // drag here, rather than waiting for mouseDragged and mouseUp to arrive, keeps the undo step from being left
        // open if it does.
        defer { session.endVisibilitySwipe() }
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableView) { ancestor = ancestor?.superview }
        guard let table = ancestor as? NSTableView else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let row = table.row(at: table.convert(next.locationInWindow, from: nil))
            guard session.layerRows.indices.contains(row) else { continue }
            session.setVisibilityInSwipe(session.layerRows[row].layer.id, visible: visible)
            table.autoscroll(with: next)
        }
    }
}
private final class MaskDisabledMark: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a row's canvas-framed thumbnail shows, so it redraws only when one of these changes.
private struct ThumbnailKey: Equatable {
    let image: ObjectIdentifier?
    let transform: LayerTransform
    let canvas: CGSize
    var editableText = false
}
