import AppKit
import os

private let mergeLog = Logger.compositor("Layers")

extension EditorSession {
    /// What ⌘E merges, in stacking order, and where the result goes; nil when there is nothing to merge.
    /// One layer merges with the layer beneath it in the same folder; several selected layers merge together
    /// (with anything their folders hold); a folder merges its contents, and the folder goes.
    private func mergePlan() -> (ids: [UUID], removed: Set<UUID>, name: String, parent: UUID?, anchor: UUID, action: String)? {
        guard canEditLayers, let document, let active = activeLayer else { return nil }
        let layers = document.layers
        if selectedLayerIDs.count > 1 {
            var picked = selectedLayerIDs
            for id in selectedLayerIDs { picked.formUnion(descendantIDs(of: id)) }
            let ordered = layers.filter { picked.contains($0.id) }
            guard ordered.contains(where: { !$0.isGroup }),
                  let top = ordered.last(where: { selectedLayerIDs.contains($0.id) }) else { return nil }
            return (ordered.map(\.id), picked, top.name, top.parentID, top.id, "Merge Layers")
        }
        if active.isGroup {
            let inside = descendantIDs(of: active.id)
            guard layers.contains(where: { inside.contains($0.id) && !$0.isGroup }) else { return nil }
            let ids = layers.filter { inside.contains($0.id) || $0.id == active.id }.map(\.id)
            return (ids, Set(ids), active.name, active.parentID, active.id, "Merge Group")
        }
        guard let index = layers.firstIndex(where: { $0.id == active.id }),
              let below = layers[..<index].last(where: { $0.parentID == active.parentID }), !below.isGroup else { return nil }
        return ([below.id, active.id], [below.id, active.id], below.name, active.parentID, active.id, "Merge Down")
    }

    var canMergeLayers: Bool { mergePlan() != nil }
    var mergeTitle: String { mergePlan()?.action ?? "Merge Down" }

    /// ⌘E: the layers composited as the canvas shows them — blend modes, opacity, masks, clipping and adjustments
    /// baked in — into one pixel layer, trimmed to what is there, in their place, as one undo step. The composite
    /// is drawn off the main thread while other edits wait.
    func mergeLayers() async {
        await settleTransform()
        guard let plan = mergePlan(), let document else { return }
        let layers = document.layers
        let kept = Set(plan.ids)
        // Only the merged layers, cut loose from anything outside the merge.
        let subset = layers.filter { kept.contains($0.id) }.map { layer -> ImageLayer in
            var copy = layer
            if let parent = copy.parentID, !kept.contains(parent) { copy.parentID = nil }
            if let source = copy.maskSourceID, !kept.contains(source) { copy.maskSourceID = nil }
            return copy
        }
        let flat = CanvasDocument(id: document.id, width: document.width, height: document.height,
                                  layers: subset, resolution: document.resolution)
        let composite = liveComposite(flat)
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: document.width, height: document.height))
        isProjectBusy = true
        defer { isProjectBusy = false }
        let name = plan.name
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(asset: ImportedImage, transform: LayerTransform), any Error> in
            Result {
                let trimmed = try PixelFilter.trimmed(try composite.render(), placed: canvas)
                let thumbnail = try PixelAdjust.thumbnail(of: trimmed.image)
                return (ImportedImage(image: trimmed.image, thumbnail: thumbnail, name: name), trimmed.transform)
            }
        }.value
        // The merge was planned from these layers; never put it over layers that changed while it was drawn.
        guard self.document?.layers == layers else {
            ToolLog.staleResult("Merge")
            return
        }
        let made: (asset: ImportedImage, transform: LayerTransform)
        do { made = try result.get() } catch { reportMergeFailure(plan.action, error); return }
        var merged = ImageLayer(asset: made.asset, origin: made.transform.origin)
        merged.transform = made.transform
        merged.name = plan.name
        merged.parentID = plan.parent
        var next = layers.filter { !plan.removed.contains($0.id) }
        // Layers clipped to anything that was merged now clip to the result.
        for i in next.indices where next[i].maskSourceID.map(plan.removed.contains) == true { next[i].maskSourceID = merged.id }
        let slot = layers.firstIndex { $0.id == plan.anchor } ?? layers.count
        let insertion = slot - layers[..<slot].filter { plan.removed.contains($0.id) }.count
        next.insert(merged, at: min(max(0, insertion), next.count))
        do { try LayerHierarchy.validate(next.map(\.hierarchyRecord)) } catch { reportMergeFailure(plan.action, error); return }
        finishOpacityEdit()
        beginEdit(plan.action)
        self.document?.layers = next
        activeLayerID = merged.id
        endEdit()
    }

    /// A merge that couldn't be made (usually memory, on a large canvas) leaves the layers as they were, and says so.
    private func reportMergeFailure(_ action: String, _ error: any Error) {
        mergeLog.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        brushError = "\(action) didn’t work: \(error.localizedDescription)"
    }
}
