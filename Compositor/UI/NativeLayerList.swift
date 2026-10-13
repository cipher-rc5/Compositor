import AppKit
import SwiftUI

/// Native mouse-down selection and drag tracking, without a double-click delay.
struct NativeLayerList: NSViewRepresentable {
    let session: EditorSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LayerTableView()
        table.session = session
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 252
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.renameClickedLayer(_:))
        table.action = #selector(Coordinator.clickedLayer(_:))
        table.registerForDraggedTypes([Coordinator.layerType, Coordinator.maskType, Coordinator.effectType])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityIdentifier("layersList")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        context.coordinator.update(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let table = scroll.documentView as? NSTableView { context.coordinator.update(table) }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let layerType = NSPasteboard.PasteboardType("com.compositor.layer-row")
        /// An Option-drag from a mask thumbnail: the id of the layer whose mask is being copied.
        static let effectType = NSPasteboard.PasteboardType("com.compositor.layer-effect")
        static let maskType = NSPasteboard.PasteboardType("com.compositor.layer-mask")
        let session: EditorSession
        private var rows: [ImageLayer] = []
        private var rowDetails: [UUID: LayerHierarchy.Entry] = [:]
        private var oldCollapsed: Set<UUID> = []
        private var editingEnabled = false
        private var synchronizing = false
        init(session: EditorSession) { self.session = session }

        func update(_ table: NSTableView) {
            let entries = session.layerRows
            let byID = Dictionary(uniqueKeysWithValues: (session.document?.layers ?? []).map { ($0.id, $0) })
            let next = entries.compactMap { byID[$0.layer.id] }
            let previousDetails = rowDetails
            rowDetails = Dictionary(uniqueKeysWithValues: entries.map { ($0.layer.id, $0) })
            let expansionChanged = oldCollapsed != session.collapsedGroupIDs
            oldCollapsed = session.collapsedGroupIDs
            let enabled = session.canEditLayers
            synchronizing = true
            defer { synchronizing = false }
            let old = rows
            rows = next
            let editableChanged = editingEnabled != enabled
            editingEnabled = enabled
            if old.map(\.id) != next.map(\.id) {
                table.reloadData()
            } else {
                // Selection never reloads cells or recreates thumbnails.
                let changed = IndexSet(next.indices.filter { index in
                    let id = next[index].id
                    return editableChanged || expansionChanged || Self.rowLooksDifferent(old[index], next[index])
                        || previousDetails[id]?.depth != rowDetails[id]?.depth
                        || previousDetails[id]?.visible != rowDetails[id]?.visible
                })
                let resized = IndexSet(next.indices.filter { (old[$0].effects?.kinds.count ?? 0) != (next[$0].effects?.kinds.count ?? 0) })
                // Adding or removing an effect only changes how tall a row is. Left to AppKit that is animated, and
                // the row appears to be taken away and put back; here it simply becomes its new height.
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
                if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
                NSAnimationContext.endGrouping()
            }
            let indices = IndexSet(next.indices.filter { session.selectedEffect == nil && session.selectedLayerIDs.contains(next[$0].id) })
            if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
            // Border-only updates: selecting a target never rebuilds thumbnails or canvas pixels.
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(next.count, NSMaxRange(visible)) {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell)?.updateTarget()
                }
            }
            // A rename — double-click, the row's menu, or the Layer menu — is typed in the row itself.
            if let id = session.renamingLayerID, let row = next.firstIndex(where: { $0.id == id }) {
                table.scrollRowToVisible(row)
                DispatchQueue.main.async {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerCell)?.beginRenaming()
                }
            }
        }

        /// Whether anything a row shows differs between two versions of its layer. Opacity, blend mode and the like
        /// aren't drawn in the row, so changing them never reloads it.
        private static func rowLooksDifferent(_ old: ImageLayer, _ new: ImageLayer) -> Bool {
            if old.name != new.name || old.isVisible != new.isVisible || old.size != new.size { return true }
            if old.parentID != new.parentID || old.isGroup != new.isGroup { return true }
            if old.asset?.image !== new.asset?.image || (old.liveText != nil) != (new.liveText != nil) { return true }
            return old.effects != new.effects || old.mask != new.mask || old.maskSourceID != new.maskSourceID
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            52 + CGFloat(rows[row].effects?.kinds.count ?? 0) * 24
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("layerCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LayerCell ?? LayerCell()
            cell.identifier = identifier
            cell.configure(rows[row], enabled: editingEnabled, session: session, depth: rowDetails[rows[row].id]?.depth ?? 0, visible: rowDetails[rows[row].id]?.visible ?? true)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let table = notification.object as? NSTableView else { return }
            let selected = table.selectedRowIndexes.filter { rows.indices.contains($0) }
            let ids = Set(selected.map { rows[$0].id })
            let primary = selected.contains(table.clickedRow) ? rows[table.clickedRow].id : selected.first.map { rows[$0].id }
            session.selectLayers(ids, primary: primary)
        }
        /// A click on a row's name (its thumbnails are buttons of their own) targets the layer itself, even when its
        /// mask was selected — so transforming then moves layer and mask together.
        @objc func clickedLayer(_ table: NSTableView) {
            guard rows.indices.contains(table.clickedRow), session.isMaskSelected,
                  session.selectedLayerIDs == [rows[table.clickedRow].id],
                  // Clicks on the row's buttons (the mask thumbnail among them) reach the table too.
                  let event = NSApp.currentEvent,
                  (table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: false) as? LayerCell)?.isOnControl(event.locationInWindow) != true
            else { return }
            session.commitTransform()
            session.selectLayerTarget(rows[table.clickedRow].id, mask: false)
        }
        @objc func renameClickedLayer(_ table: NSTableView) {
            guard session.canEditLayers, rows.indices.contains(table.clickedRow) else { return }
            let id = rows[table.clickedRow].id
            session.activeLayerID = id
            // On the thumbnail (or another of the row's controls) a double-click opens what the layer holds: its
            // text, or an adjustment's settings. On the name it renames the layer, as it does for every other layer.
            let point = NSApp.currentEvent?.locationInWindow ?? .zero
            let cell = table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: false) as? LayerCell
            if cell?.isOnControl(point) == true {
                if rows[table.clickedRow].liveText != nil { session.editActiveText(); return }
                if rows[table.clickedRow].adjustment?.kind.isEditable == true { session.adjustmentEditingID = id; return }
            }
            session.renamingLayerID = id
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard session.canEditLayers, rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(rows[row].id.uuidString, forType: Self.layerType)
            return item
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            if let source = info.draggingSource as? LayerEffectRow {
                let target = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
                guard source.session === session, rows.indices.contains(target),
                      session.canCopyEffect(source.kind, from: source.layerID, to: rows[target].id) else { return [] }
                tableView.setDropRow(target, dropOperation: .on)
                return .copy
            }
            if let source = draggedMask(info) {
                // A mask lands on whichever row is under the pointer.
                let target = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
                guard rows.indices.contains(target), session.canCopyMask(from: source, to: rows[target].id) else { return [] }
                tableView.setDropRow(target, dropOperation: .on)
                return .copy
            }
            guard session.canEditLayers, info.draggingSource as? NSTableView === tableView,
                  (0...rows.count).contains(row) else { return [] }
            let ids = draggedLayers(info)
            guard !ids.isEmpty else { return [] }
            // With Option held the drag offers only Copy, including complete folder trees.
            let copying = info.draggingSourceOperationMask == .copy
            let intoFolder = operation == .on && rows.indices.contains(row) && rows[row].isGroup
            let parent = intoFolder ? rows[row].id : (rows.indices.contains(row) ? rows[row].parentID : nil)
            guard ids.allSatisfy({ session.canPlaceLayer($0, in: parent) }) else { return [] }
            tableView.setDropRow(row, dropOperation: intoFolder ? .on : .above)
            return copying ? .copy : .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            if let source = info.draggingSource as? LayerEffectRow {
                guard source.session === session, rows.indices.contains(row),
                      session.canCopyEffect(source.kind, from: source.layerID, to: rows[row].id) else { return false }
                session.copyEffect(source.kind, from: source.layerID, to: rows[row].id)
                return true
            }
            if let source = draggedMask(info) {
                guard rows.indices.contains(row), session.canCopyMask(from: source, to: rows[row].id) else { return false }
                session.copyMask(from: source, to: rows[row].id)
                return true
            }
            guard info.draggingSource as? NSTableView === tableView else { return false }
            let ids = draggedLayers(info)
            guard !ids.isEmpty else { return false }
            let copying = info.draggingSourceOperationMask == .copy
            let intoFolder = dropOperation == .on && rows.indices.contains(row) && rows[row].isGroup
            return place(ids, at: row, intoFolder: intoFolder, copying: copying)
        }
        /// Reorders one layer to the row a drop above it would use: the list's own move, without the dragging
        /// plumbing, so anything that picks a row by itself — a test, a keyboard command — can reach it.
        @discardableResult func moveLayer(_ id: UUID, to row: Int) -> Bool {
            // `session.placeLayer` already refuses an unknown layer and a session that cannot edit layers, so the
            // only thing left to reject is a row that is not a drop target. `place` treats a row past the end as
            // the bottom, so what this actually catches is a negative one; the bound is written the way
            // `validateDrop` writes it, so the two accept the same rows.
            guard (0...rows.count).contains(row) else { return false }
            return place([id], at: row, intoFolder: false, copying: false)
        }
        private func place(_ ids: [UUID], at row: Int, intoFolder: Bool, copying: Bool) -> Bool {
            // Where the drop lands is worked out once: each layer placed shifts the rows beneath it.
            let current = session.layerRows
            let parent: UUID?, above: UUID?, atBottom: Bool
            if intoFolder {
                parent = rows[row].id; above = nil; atBottom = false
            } else if row >= current.count {
                parent = nil; above = nil; atBottom = true
            } else {
                let target = current[row].layer
                parent = target.parentID; above = target.id; atBottom = false
            }
            // Dropped above a layer (or at the very bottom) the last one placed ends up nearest it, so they go in
            // from the top down; dropped into a folder each lands on top, so they go in from the bottom up.
            let order = intoFolder ? Array(ids.reversed()) : ids
            session.beginEdit(copying ? (ids.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
                                      : (ids.count > 1 ? "Move Layers" : "Move Layer"))
            var placed = false
            for id in order {
                let done = copying ? session.duplicateLayer(id, in: parent, above: above, atBottom: atBottom)
                                   : session.placeLayer(id, in: parent, above: above, atBottom: atBottom)
                placed = done || placed
            }
            // The layers that moved stay selected, so they can be dragged on as a group.
            if placed, !copying { session.selectLayers(Set(ids), primary: ids.first) }
            session.endEdit()
            return placed
        }
        private func draggedMask(_ info: NSDraggingInfo) -> UUID? {
            info.draggingPasteboard.string(forType: Self.maskType).flatMap(UUID.init(uuidString:))
        }
        /// Every layer being dragged, in the order the list shows them: a row's pasteboard item each, leaving out
        /// anything inside a dragged folder, which the folder brings along itself.
        private func draggedLayers(_ info: NSDraggingInfo) -> [UUID] {
            let dropped = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
                $0.string(forType: Self.layerType).flatMap(UUID.init(uuidString:))
            }
            let dragged = Set(dropped)
            let carried = dragged.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1)) }
            return session.layerRows.map(\.layer.id).filter { dragged.contains($0) && !carried.contains($0) }
        }
    }
}
