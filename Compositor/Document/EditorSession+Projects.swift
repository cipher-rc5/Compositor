import Foundation

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects, text: layer.liveText?.style)
        }
        return ProjectSnapshot(manifest: ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers,
            guides: document.guides.isEmpty ? nil : document.guides), images: images, masks: masks)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL?) {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        let manifest = snapshot.manifest
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map { ImageLayer(record: $0, in: snapshot) }, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        activeLayerID = manifest.activeLayerID
        projectURL = url
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: document!.size)
    }

    /// A crash-recovery snapshot: unsaved, with no file of its own. Saving it asks where, since the sandbox's
    /// access to wherever it was saved before didn't outlive the launch that crashed.
    func installRecoveredProject(_ snapshot: ProjectSnapshot) {
        installProject(snapshot, from: nil)
        history.markUnsaved()
    }

    func clearProject() {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        guideDrag = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        history.reset()
    }

    func createNewProject(width: Int, height: Int) {
        guard !isProjectBusy, !isImporting, (1...30_000).contains(width), (1...30_000).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true)
    }
}

extension ImageLayer {
    /// A saved layer record, with its pixels and mask from the snapshot. Opening a project and every
    /// whole-document edit (Canvas Size, Image Size, Crop, Trim) rebuild layers through here, so what a
    /// record carries survives both the same way.
    init(record: ProjectLayerRecord, in snapshot: ProjectSnapshot) {
        let image = snapshot.images[record.id]
        self.init(id: record.id, asset: image, name: record.name, isVisible: record.isVisible, transform: record.transform,
                  parentID: record.parentID, isGroup: record.isGroup == true, opacity: record.opacity ?? 1,
                  blendMode: record.blendMode ?? .normal, mask: snapshot.mask(for: record), maskSourceID: record.maskSourceID,
                  adjustment: record.adjustment, shape: LayerShape.loaded(record.shape, image: image?.image),
                  effects: record.effects, text: LayerText.loaded(record.text, image: image?.image))
    }
}
