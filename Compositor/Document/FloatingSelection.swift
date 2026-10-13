import AppKit

/// Cmd-T with a selection: the selected pixels float on a temporary layer, edited with the
/// normal transform handles, then merge back into their layer. The whole thing is one
/// "Transform Selection" undo step; Escape restores the document exactly.
struct FloatingTransform {
    let sourceID: UUID
    let before: CanvasDocument
    let beforeActive: UUID?
    let original: LayerTransform
    let pixelSize: CGSize
}

extension EditorSession {
    var canTransformSelection: Bool {
        guard transformEdit == nil, canEditPixels, !isMaskSelected, let selection, !selection.isEmpty,
              activeLayer?.asset != nil else { return false }
        return true
    }

    /// Cmd-T: transforms the selected pixels when there is a selection, else the layer.
    func transformCommand() {
        if canTransformSelection { Task { await beginSelectionTransform() } }
        else { beginTransform() }
    }

    func beginSelectionTransform() async {
        guard canTransformSelection, let document, let source = activeLayer else { NSSound.beep(); return }
        let lifted: (image: CGImage, region: CGRect)
        do {
            guard let pixels = try renderSelectedPixels(from: source, mask: false) else { NSSound.beep(); return }
            lifted = pixels
        } catch { brushError = error.localizedDescription; return }
        let before = document, beforeActive = activeLayerID
        // Outer edit: closed by commitTransform (merge) or cancelTransform (restore).
        beginEdit("Transform Selection")
        // The pixels move only if they leave their place: when the clear fails, floating them anyway would make the
        // transform a copy. It reports its own error; the float is abandoned.
        guard await clearSelectedPixels() else {
            self.document = before
            endEdit()
            if brushError == nil { brushError = "The selected pixels couldn’t be lifted to transform them." }
            return
        }
        let thumbnail: CGImage
        do { thumbnail = try PixelInvert.thumbnail(of: lifted.image) } catch {
            self.document = before
            endEdit()
            brushError = error.localizedDescription
            return
        }
        guard let index = self.document?.layers.firstIndex(where: { $0.id == source.id }) else {
            self.document = before
            endEdit()
            return
        }
        var floating = ImageLayer(asset: ImportedImage(image: lifted.image, thumbnail: thumbnail, name: "Floating Selection"),
                                  origin: lifted.region.origin)
        floating.name = "Floating Selection"
        floating.parentID = source.parentID
        floating.opacity = source.opacity
        floating.blendMode = source.blendMode
        self.document?.layers.insert(floating, at: index + 1)
        activeLayerID = floating.id
        tool = .move
        transformEdit = TransformEdit(layerID: floating.id, draft: floating.transform, persistent: true,
            floating: FloatingTransform(sourceID: source.id, before: before, beforeActive: beforeActive,
                                        original: floating.transform, pixelSize: lifted.region.size))
    }

    /// Maps the original selection to where the floating pixels are now.
    func floatingSelectionTransform(_ edit: TransformEdit) -> CGAffineTransform? {
        guard let floating = edit.floating else { return nil }
        let width = Int(floating.pixelSize.width), height = Int(floating.pixelSize.height)
        return BrushRaster.pixelToDocument(floating.original, width: width, height: height).inverted()
            .concatenating(BrushRaster.pixelToDocument(edit.draft, width: width, height: height))
    }

    /// Composites the transformed pixels back into their layer, moves the selection with
    /// them, and closes the undo step. Synchronous so the many edits that commit a pending transform before acting
    /// can call it and go on at once; Apply, Save, Merge and tool switches render it off the main thread first
    /// (`applyTransform`), and this then uses what they made.
    func mergeFloatingTransform(_ edit: TransformEdit, _ floating: FloatingTransform) {
        defer { endEdit() }
        do {
            guard edit.draft.isValid, let layers = document?.layers,
                  let pixels = layers.first(where: { $0.id == edit.layerID })?.asset?.image,
                  let source = layers.first(where: { $0.id == floating.sourceID }) else { throw ProjectError.invalid }
            let job = FloatingMerge.Job(pixels: pixels, draft: edit.draft, corners: edit.corners, source: source)
            let ready = FloatingMerge.rendered.flatMap { $0.matches(job) ? $0.merged : nil }
            let merged = try ready ?? FloatingMerge.render(job)
            let moved: DocumentSelection?
            if let corners = edit.corners {
                let placement = BrushRaster.pixelToDocument(floating.original, width: Int(floating.pixelSize.width),
                                                             height: Int(floating.pixelSize.height))
                moved = selection.flatMap { selection in
                    DistortWarp.mapPath(selection.path, pixelToDocument: placement, pixelSize: floating.pixelSize,
                                        transform: edit.draft, corners: corners)
                        .map { DocumentSelection(path: $0, antialiased: selection.antialiased, feather: selection.feather) }
                }
            } else {
                moved = floatingSelectionTransform(edit).flatMap { transform -> DocumentSelection? in
                    var matrix = transform
                    guard let selection, let path = selection.path.copy(using: &matrix) else { return nil }
                    return DocumentSelection(path: path, antialiased: selection.antialiased, feather: selection.feather)
                }
            }
            document?.layers.removeAll { $0.id == edit.layerID }
            guard let index = document?.layers.firstIndex(where: { $0.id == source.id }) else { throw ProjectError.invalid }
            document?.layers[index] = source.replacingPixels(merged.asset, transform: merged.transform, mask: merged.mask)
            document?.selection = moved
            activeLayerID = source.id
        } catch {
            document = floating.before
            activeLayerID = floating.beforeActive
            brushError = error.localizedDescription
        }
    }

    /// Whether committing the pending transform resamples pixels — a floating selection that moved, or a distortion —
    /// which is worth doing off the main thread first (`applyTransform`).
    var pendingTransformResamples: Bool {
        guard let edit = transformEdit else { return false }
        if let floating = edit.floating { return edit.draft != floating.original || edit.corners != nil }
        return edit.corners != nil && !edit.mask
    }

    /// Apply for a floating selection: the warp and merge are made off the main thread while the preview stays up and
    /// other edits wait, then committed like any transform.
    func applyFloatingTransform(_ edit: TransformEdit, _ floating: FloatingTransform) async {
        guard edit.draft != floating.original || edit.corners != nil, edit.draft.isValid, let layers = document?.layers,
              let pixels = layers.first(where: { $0.id == edit.layerID })?.asset?.image,
              let source = layers.first(where: { $0.id == floating.sourceID }) else {
            // Nothing to render, or nothing it could be rendered from: the commit restores or reports.
            commitTransform()
            return
        }
        let job = FloatingMerge.Job(pixels: pixels, draft: edit.draft, corners: edit.corners, source: source)
        isProjectBusy = true
        let rendered = await Task.detached(priority: .userInitiated) { () -> FloatingMerge.Rendered? in
            // A failure is left for the commit to meet again and report.
            guard let merged = try? FloatingMerge.render(job) else { return nil }
            return FloatingMerge.Rendered(job: job, merged: merged)
        }.value
        isProjectBusy = false
        // Cancelled meanwhile, or another edit: there is nothing of this one left to apply.
        guard let pending = transformEdit, pending.layerID == edit.layerID, pending.floating != nil else {
            ToolLog.staleResult("Transform Selection")
            return
        }
        // Whatever no longer matches (the handles nudged meanwhile) is redone by the commit itself.
        FloatingMerge.$rendered.withValue(rendered) { commitTransform() }
    }

    func cancelFloatingTransform(_ floating: FloatingTransform) {
        document = floating.before
        activeLayerID = floating.beforeActive
        endEdit()
    }
}

nonisolated enum FloatingMerge {
    /// What a floating selection's merge is made from: its pixels and where they now go, and the layer they go into.
    struct Job: Sendable {
        let pixels: CGImage
        let draft: LayerTransform
        let corners: [CGPoint]?
        let source: ImageLayer
    }
    typealias Merged = (asset: ImportedImage, transform: LayerTransform, mask: LayerMask?)

    /// A merge made off the main thread for the Apply in progress (see `applyTransform`), with what it was made from.
    struct Rendered: Sendable {
        let job: Job
        let merged: Merged
        func matches(_ other: Job) -> Bool {
            job.pixels === other.pixels && job.draft == other.draft && job.corners == other.corners && job.source == other.source
        }
    }
    @TaskLocal static var rendered: Rendered?

    /// The merge, start to finish: a distorted selection is warped into its new shape first, then merged like any other.
    static func render(_ job: Job) throws -> Merged {
        let placed = try job.corners.map { corners -> (image: CGImage, transform: LayerTransform) in
            let warped = try DistortWarp.warpTrimmed(job.pixels, transform: job.draft, corners: corners)
            return (warped.image, warped.transform)
        } ?? (image: job.pixels, transform: job.draft)
        return try merge(placed.image, transform: placed.transform, into: job.source)
    }

    /// Draws the floating pixels (with their transform) onto the source layer's own pixel
    /// grid, growing the layer where they now extend past it. A mask grows with it, revealing
    /// the new area.
    static func merge(_ pixels: CGImage, transform: LayerTransform, into source: ImageLayer)
        throws -> (asset: ImportedImage, transform: LayerTransform, mask: LayerMask?) {
        guard let sourceImage = source.asset?.image else { throw ProjectError.invalid }
        let width = sourceImage.width, height = sourceImage.height
        let toDocument = BrushRaster.pixelToDocument(source.transform, width: width, height: height)
        let toPixels = toDocument.inverted()
        let floatingBounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
            .applying(BrushRaster.pixelToDocument(transform, width: pixels.width, height: pixels.height)).applying(toPixels)
        let original = CGRect(x: 0, y: 0, width: width, height: height)
        let extent = original.union(floatingBounds).integral
        guard extent.width <= 30_000, extent.height <= 30_000, extent.width * extent.height <= 100_000_000
        else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(extent.width), height: Int(extent.height), mask: false)
        let placed = original.offsetBy(dx: -extent.minX, dy: -extent.minY)
        BrushRaster.draw(sourceImage, in: placed, mask: false, context: context)
        context.saveGState()
        context.translateBy(x: -extent.minX, y: -extent.minY)
        context.concatenate(toPixels)
        LayerRenderer.draw(pixels, transform: transform, center: transform.center, in: context)
        context.restoreGState()
        guard let image = context.makeImage() else { throw ExportError.render }
        let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: source.name)
        var merged = source.transform
        merged.size = CGSize(width: extent.width * source.size.width / CGFloat(width),
                             height: extent.height * source.size.height / CGFloat(height))
        let center = CGPoint(x: extent.midX, y: extent.midY).applying(toDocument)
        merged.origin = CGPoint(x: center.x - merged.size.width / 2, y: center.y - merged.size.height / 2)
        var mask = source.mask
        if let current = source.mask, current.placement == nil, extent != original {
            let grown = try BrushRaster.context(width: Int(extent.width), height: Int(extent.height), mask: true)
            grown.setFillColor(gray: 1, alpha: 1)
            grown.fill(CGRect(origin: .zero, size: extent.size))
            BrushRaster.draw(current.asset.image, in: placed, mask: true, context: grown)
            guard let maskImage = grown.makeImage() else { throw ExportError.render }
            mask = current.replacing(try LayerMask.asset(from: maskImage))
        }
        return (asset, merged, mask)
    }
}
