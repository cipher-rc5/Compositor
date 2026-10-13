import AppKit
import UniformTypeIdentifiers

/// Pixels copied from the canvas, with where they came from so Paste can put them back in place.
struct PixelClipboard {
    let image: CGImage
    let origin: CGPoint
    /// The system pasteboard's change count right after writing; a mismatch means another app copied since.
    let changeCount: Int
}

extension EditorSession {
    /// Whole-pixel bounds of what Copy takes: the selection, or the whole canvas without one.
    /// Path boolean operations leave tiny float noise (59.9999999), so round with a tolerance
    /// rather than letting it add a whole pixel.
    func selectionCopyRegion() -> CGRect? {
        guard let document else { return nil }
        let canvas = CGRect(origin: .zero, size: document.size)
        let bounds = selection?.coverageBounds ?? canvas
        let tolerance: CGFloat = 0.001
        let minX = floor(bounds.minX + tolerance), minY = floor(bounds.minY + tolerance)
        let region = CGRect(x: minX, y: minY, width: ceil(bounds.maxX - tolerance) - minX,
                            height: ceil(bounds.maxY - tolerance) - minY).intersection(canvas)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        return region
    }

    var canCopyPixels: Bool {
        guard canEditLayers, let layer = activeLayer, !layer.isGroup || isMaskSelected, selection?.isEmpty != true else { return false }
        return isMaskSelected ? layer.mask != nil : layer.asset != nil
    }

    /// The active layer's pixels (or mask as opaque gray) exactly as they sit on the canvas,
    /// clipped to the selection (soft edges kept), or the whole canvas without one.
    func renderSelectedPixels(from layer: ImageLayer, mask: Bool) throws -> (image: CGImage, region: CGRect)? {
        guard let document else { return nil }
        let clip = try selection?.clip(canvas: document.size)
        if clip != nil, clip?.coverage == nil { return nil }
        guard let region = selectionCopyRegion() else { return nil }
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        context.translateBy(x: -region.minX, y: -region.minY)
        clip?.apply(to: context)
        let transform = displayedTransform(for: layer)
        if mask, let owned = layer.mask {
            let placement = displayedMaskPlacement(for: layer)
            context.setFillColor(gray: placement == nil ? 0 : LayerMask.background(of: owned.asset.thumbnail), alpha: 1)
            context.fill(region)
            LayerRenderer.drawCoverage(owned.asset.image, transform: placement ?? transform, in: context)
        } else if !mask, let image = layer.asset?.image {
            LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        } else { return nil }
        guard let image = context.makeImage() else { throw ExportError.render }
        return (image, region)
    }

    var canCopyMerged: Bool {
        canEditLayers && selection?.isEmpty != true && document?.renderLayers.contains { $0.asset != nil } == true
    }

    /// Shift-Cmd-C (Copy Merged): the selection across every visible layer, composited as
    /// the canvas shows it, including opacity, blend modes, and masks.
    func renderMergedPixels() throws -> (image: CGImage, region: CGRect)? {
        guard let document else { return nil }
        let clip = try selection?.clip(canvas: document.size)
        if clip != nil, clip?.coverage == nil { return nil }
        guard let region = selectionCopyRegion() else { return nil }
        return try Self.mergedPixels(liveComposite(document), clip: clip, region: region)
    }

    /// `composite` within `region`, drawn through the selection's `clip` (soft edges kept).
    nonisolated private static func mergedPixels(_ composite: LiveComposite, clip: SelectionClip?,
                                                 region: CGRect) throws -> (image: CGImage, region: CGRect) {
        // Composited on its own first, then drawn through the selection: a transparency layer would do the same,
        // but Color Burn and Color Dodge need to read what they are blending with, which a group hides.
        let merged = try composite.render(region: region)
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        context.translateBy(x: -region.minX, y: -region.minY)
        clip?.apply(to: context)
        BrushRaster.draw(merged, in: region, mask: false, context: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return (image, region)
    }

    /// Copy Merged, composited off the main thread while other edits wait.
    func copyMergedSelection() async {
        guard canCopyMerged, let document else { return }
        let clip: SelectionClip?
        do { clip = try selection?.clip(canvas: document.size) } catch { brushError = error.localizedDescription; return }
        guard clip == nil || clip?.coverage != nil, let region = selectionCopyRegion() else { NSSound.beep(); return }
        let composite = liveComposite(document)
        isProjectBusy = true
        let rendered = await Task.detached(priority: .userInitiated) { () -> Result<CopiedPixels, Error> in
            Result { CopiedPixels(try Self.mergedPixels(composite, clip: clip, region: region)) }
        }.value
        isProjectBusy = false
        do {
            let copied = try rendered.get()
            store((copied.image, copied.region))
        } catch { brushError = error.localizedDescription }
    }

    /// Cmd-C: copies the selected pixels (or the whole layer) for Paste, and to the system
    /// pasteboard as PNG for other apps. False when nothing was copied: nothing to copy (a beep) or an error (shown).
    @discardableResult
    func copySelection() -> Bool {
        guard canCopyPixels, let layer = activeLayer else { return false }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return false }
            store(copied)
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }

    /// Keeps pixels for Paste at once, and puts them on the system pasteboard as PNG once encoded, off the main thread.
    private func store(_ copied: (image: CGImage, region: CGRect)) {
        let pasteboard = self.pasteboard
        let changeCount = pasteboard.clearContents()
        pixelClipboard = PixelClipboard(image: copied.image, origin: copied.region.origin, changeCount: changeCount)
        let image = copied.image
        pasteboardWrite = Task {
            let png = await Task.detached(priority: .userInitiated) { Self.pngData(image) }.value
            // Copied again since, here or in another app: that copy owns the pasteboard now.
            guard let png, pasteboard.changeCount == changeCount else { return }
            pasteboard.setData(png, forType: .png)
            if let clip = pixelClipboard, clip.image === image, clip.changeCount != pasteboard.changeCount {
                pixelClipboard = PixelClipboard(image: image, origin: clip.origin, changeCount: pasteboard.changeCount)
            }
        }
    }

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Cmd-X: copy, then clear the selected pixels — only once the copy has worked, so a failed copy loses nothing.
    func cutSelection() async {
        guard selection != nil, canCopyPixels, copySelection() else { return }
        await clearSelectedPixels()
    }

    var canPaste: Bool {
        guard document != nil, canEditLayers else { return false }
        if let pixelClipboard, pasteboard.changeCount == pixelClipboard.changeCount { return true }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Cmd-V: pastes as a new layer above the active one. Pixels copied here go back exactly
    /// where they came from; images copied in other apps are centered.
    func paste() {
        guard canPaste, let document else { return }
        if let clip = pixelClipboard, pasteboard.changeCount == clip.changeCount {
            guard fitsPixelBudget(adding: clip.image.width * clip.image.height, action: "Paste") else { return }
            addPixelLayer(clip.image, at: clip.origin, name: nextLayerName(), editName: "Paste")
        } else if let external = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            guard external.width <= 30_000, external.height <= 30_000 else {
                brushError = "The copied image is larger than the 30,000 pixels a side a layer can be, so it wasn’t pasted."
                return
            }
            guard fitsPixelBudget(adding: external.width * external.height, action: "Paste") else { return }
            let image: CGImage
            do { image = try Self.sRGBCopy(of: external) } catch {
                brushError = "The copied image couldn’t be pasted. \(error.localizedDescription)"
                return
            }
            let origin = CGPoint(x: floor((document.size.width - CGFloat(image.width)) / 2),
                                 y: floor((document.size.height - CGFloat(image.height)) / 2))
            addPixelLayer(image, at: origin, name: nextLayerName(), editName: "Paste")
        } else { NSSound.beep() }
    }

    /// Whether `pixels` more image pixels and `maskPixels` more mask pixels still fit the 100 million of
    /// each that a project can save (docs/project-format.md). When they don't, says so and returns false:
    /// going past it would leave a document that every Save and autosave refuses.
    func fitsPixelBudget(adding pixels: Int, maskPixels: Int = 0, action: String) -> Bool {
        let usedMasks = document?.layers.reduce(0) { total, layer in
            total + (layer.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0)
        } ?? 0
        guard usedImagePixels() + pixels <= 100_000_000, usedMasks + maskPixels <= 100_000_000 else {
            brushError = Self.budgetMessage(action)
            return false
        }
        return true
    }

    private static func budgetMessage(_ action: String) -> String {
        "\(action) would take this document past the 100 megapixels of images (or of masks) a project can hold, so nothing was added. Delete or crop layers to make room."
    }

    /// Cmd-J (Layer via Copy): the selection's pixels become a new layer in place; with no
    /// selection the whole layer is duplicated.
    func layerViaCopy() {
        guard canEditLayers, let layer = activeLayer, !layer.isGroup, selection?.isEmpty != true else { return }
        guard selection != nil else { duplicateActiveLayer(); return }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return }
            guard fitsPixelBudget(adding: copied.image.width * copied.image.height, action: "Layer via Copy") else { return }
            addPixelLayer(copied.image, at: copied.region.origin, name: nextLayerName(), editName: "Layer via Copy")
        } catch { brushError = error.localizedDescription }
    }

    func duplicateActiveLayer() {
        guard canEditLayers, let layer = activeLayer,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let included = descendantIDs(of: layer.id).union([layer.id])
        let originals = (document?.layers ?? []).filter { included.contains($0.id) }
        guard (document?.layers.count ?? 0) + originals.count <= 10_000 else {
            brushError = "Duplicate Layer would take this document past the 10,000 layers a project can hold."
            return
        }
        // Copies share their pixels in memory, but a saved project stores each layer's own.
        let pixels = originals.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) }
        let maskPixels = originals.reduce(0) { $0 + ($1.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0) }
        guard fitsPixelBudget(adding: pixels, maskPixels: maskPixels, action: "Duplicate Layer") else { return }
        let mapping = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
        let copies = originals.map { original in
            ImageLayer(id: mapping[original.id]!, asset: original.asset,
                name: original.name + (original.id == layer.id ? " copy" : ""), isVisible: original.isVisible,
                transform: original.transform, parentID: original.parentID.map { mapping[$0] ?? $0 },
                isGroup: original.isGroup, opacity: original.opacity, blendMode: original.blendMode,
                mask: original.mask, maskSourceID: original.maskSourceID.map { mapping[$0] ?? $0 },
                adjustment: original.adjustment, shape: original.shape, effects: original.effects, text: original.text)
        }
        beginEdit("Duplicate Layer")
        document?.layers.insert(contentsOf: copies, at: index + 1)
        for original in originals where collapsedGroupIDs.contains(original.id) {
            collapsedGroupIDs.insert(mapping[original.id]!)
        }
        activeLayerID = mapping[layer.id]
        endEdit()
    }

    /// Option-drag in the Layers panel: a copy of the layer placed where it was dropped (inside `parent`,
    /// above `target`, or at the very bottom), as one undo step. Folders carry all descendants.
    @discardableResult
    func duplicateLayer(_ id: UUID, in parent: UUID?, above target: UUID? = nil, atBottom: Bool = false) -> Bool {
        guard canEditLayers,
              canPlaceLayer(id, in: parent) else { return false }
        beginEdit("Duplicate Layer")
        defer { endEdit() }
        selectLayer(id)
        duplicateActiveLayer()
        guard let copy = activeLayerID, copy != id else { return false }
        return placeLayer(copy, in: parent, above: target, atBottom: atBottom)
    }

    /// Inserts pixels as a new layer above the active one (inside its folder), all in one undo
    /// step. Pasting drops the selection, as in Photoshop; a drawn shape keeps it.
    /// False when no layer was added; a failure is reported.
    @discardableResult
    func addPixelLayer(_ image: CGImage, at origin: CGPoint, name: String, editName: String, dropsSelection: Bool = true, shape: LayerShape? = nil, text: LayerText? = nil) -> Bool {
        guard let document else { return false }
        let thumbnail: CGImage
        do { thumbnail = try PixelInvert.thumbnail(of: image) } catch {
            brushError = "\(editName) couldn’t add a layer. \(error.localizedDescription)"
            return false
        }
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: thumbnail, name: name), origin: origin)
        layer.name = name
        layer.shape = shape
        layer.text = text
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        finishOpacityEdit()
        beginEdit(editName)
        self.document?.layers.insert(layer, at: index)
        if dropsSelection { self.document?.selection = nil }
        activeLayerID = layer.id
        endEdit()
        return true
    }

    func nextLayerName() -> String { document?.unusedName("Layer") ?? "Layer 1" }

    /// Normalizes an image from another app to the working sRGB RGBA format.
    private static func sRGBCopy(of image: CGImage) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let copy = context.makeImage() else { throw ExportError.render }
        return copy
    }
}

/// Pixels copied off the main thread, and where on the canvas they came from.
private nonisolated struct CopiedPixels: Sendable {
    let image: CGImage
    let region: CGRect
    init(_ copied: (image: CGImage, region: CGRect)) { image = copied.image; region = copied.region }
}
