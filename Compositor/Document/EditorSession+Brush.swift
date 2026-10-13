import AppKit

/// A Clone Stamp or Blur stroke whose source is still being made off the main thread. The stroke is under way —
/// the canvas and the gates treat it as painting — but its points wait here until the source lands, then are
/// replayed in order. Rendering the whole document on mouse-down used to hold up the first dab.
final class BrushSampleWait {
    let stroke: BrushStroke
    let offset: CGSize
    let name: String
    var points: [CGPoint]
    /// Mouse-up came first: commit once the source lands. The session is busy meanwhile, so the next input waits.
    var finishes = false
    var task: Task<Void, Never>?
    init(stroke: BrushStroke, offset: CGSize, name: String, first: CGPoint) {
        self.stroke = stroke
        self.offset = offset
        self.name = name
        points = [first]
    }
}

/// What a Clone Stamp or Blur stroke copies from, to render off the main thread.
private nonisolated struct BrushSampleJob: Sendable {
    var clone: SelectionSource?
    var blur: BlurSampleSource?
    func render() throws -> CGImage {
        if let clone { return try clone.render() }
        guard let blur else { throw ExportError.render }
        return try blur.render()
    }
}

private nonisolated struct BrushSampleResult: Sendable {
    let image: CGImage?
    let error: Error?
}

extension EditorSession {
    /// An explicitly empty selection leaves nothing paintable, so painting never starts.
    var canPaint: Bool {
        // A folder has no pixels of its own, so only its mask can be painted.
        canEditLayers && selectedLayerIDs.count == 1 && (activeLayer?.isGroup == false || isMaskSelected) && selection?.isEmpty != true
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
            && (!isMaskSelected || activeLayer?.mask?.isEnabled == true)
            && (isMaskSelected || activeLayer?.adjustment == nil)
    }
    /// Tiled raster edit of the active layer's pixels or mask, within the shared pixel budgets.
    func makeRasterEdit(for layer: ImageLayer, settings: BrushSettings = BrushSettings()) throws -> BrushStroke {
        guard let document else { throw ProjectError.tooLarge }
        let stroke = try BrushStroke(layer: layer, mask: isMaskSelected, settings: settings, canvas: document.size)
        let used = document.layers.filter { $0.id != layer.id }.reduce(0) { total, layer in
            let image = isMaskSelected ? layer.mask?.asset.image : layer.asset?.image
            return total + (image.map { $0.width * $0.height } ?? 0)
        }
        stroke.pixelLimit = 100_000_000 - used
        stroke.selectionClip = try selection?.clip(canvas: document.size)
        if !isMaskSelected, layer.mask != nil {
            let maskPixels = document.layers.filter { $0.id != layer.id }.reduce(0) { $0 + ($1.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0) }
            stroke.pixelLimit = min(stroke.pixelLimit, 100_000_000 - maskPixels)
        }
        return stroke
    }
    func beginBrush(at point: CGPoint) {
        // Spot Healing and Clone Stamp rework image pixels; they have nothing to do on a mask.
        if tool == .blur, blurMode != .blur { beginWarp(at: point); return }
        guard tool == .brush || tool == .blur || (tool.isBrushTool && !isMaskSelected), canPaint, let layer = activeLayer, let document else { return }
        // Clone Stamp and Blur paint from a copy of the document, made off the main thread while the stroke starts.
        var sample: (job: BrushSampleJob, offset: CGSize)?
        if tool == .cloneStamp {
            guard let offset = cloneStrokeOffset(at: point) else {
                brushError = "Option-click where Clone Stamp should copy from first."
                return
            }
            guard let source = cloneSampleSource(document) else { return }
            sample = (BrushSampleJob(clone: source), offset)
            cloneOffset = offset
        }
        // Blur paints a softened copy of the layer, in place, through the brush tip.
        if tool == .blur {
            do { sample = (BrushSampleJob(blur: try blurSource(document, mask: isMaskSelected)), .zero) }
            catch { brushError = error.localizedDescription; return }
        }
        finishOpacityEdit()
        do {
            var settings = brushSettings
            settings.healing = tool == .spotHealing
            settings.erasing = tool == .brush && brushMode == .erase && !isMaskSelected
            settings.healingMode = spotHealingMode
            if isMaskSelected { settings.red = maskPaintWhite ? 1 : 0; settings.green = settings.red; settings.blue = settings.red }
            let stroke = try makeRasterEdit(for: layer, settings: settings)
            stroke.isBlur = tool == .blur
            brushStroke = stroke
            if let sample { awaitSample(sample.job, offset: sample.offset, for: stroke, from: point) }
            else { try stroke.append(point) }
            brushAnchor = point
            brushPointer = point
            lastBrushPoint = (point, layer.id, isMaskSelected)
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    func continueBrush(at point: CGPoint) {
        if let warpStroke {
            do { try warpStroke.append(point); lastBrushPoint?.point = point; brushRevision += 1 }
            catch { cancelBrush(); brushError = error.localizedDescription }
            return
        }
        guard let brushStroke else { return }
        brushPointer = point
        if let wait = brushSampleWait, wait.stroke === brushStroke {
            wait.points.append(point)
            lastBrushPoint?.point = point
            return
        }
        guard let painted = smoothed(point) else { return }
        do { try brushStroke.append(painted); lastBrushPoint?.point = painted; brushRevision += 1 }
        catch { cancelBrush(); brushError = error.localizedDescription }
    }
    /// Where the brush actually is, with Smoothing on: it trails the pointer on a string, and only
    /// moves once the pointer pulls that string taut — the model Photoshop uses. The string's length
    /// is in screen points, so it feels the same however far the canvas is zoomed in. Nil while the
    /// string is still slack, which is the whole point: those jitters never reach the stroke.
    private func smoothed(_ point: CGPoint) -> CGPoint? {
        guard tool == .brush, brushSettings.smoothing > 0, let anchor = brushAnchor else { return point }
        let radius = brushSettings.smoothing / max(0.01, viewport.zoom)
        let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        let distance = hypot(delta.x, delta.y)
        guard distance > radius else { return nil }
        let step = (distance - radius) / distance
        let moved = CGPoint(x: anchor.x + delta.x * step, y: anchor.y + delta.y * step)
        brushAnchor = moved
        return moved
    }
    /// Where a Shift-click paints a line from: the end of the last stroke, while the same layer (or mask) is the target.
    func shiftLineStart() -> CGPoint? {
        guard let last = lastBrushPoint, last.layerID == activeLayerID, last.mask == isMaskSelected else { return nil }
        return last.point
    }
    func cancelBrush() {
        brushSampleWait = nil
        warpStroke = nil
        brushStroke = nil
        brushAnchor = nil
        brushPointer = nil
        brushRevision += 1
    }
    /// Called directly by mouse-up, before the next input event can be handled.
    @discardableResult
    func finishBrushImmediately() -> Bool {
        if warpStroke != nil {
            guard !isProjectBusy else { return false }
            finishWarp()
            return true
        }
        guard let stroke = brushStroke else { return true }
        guard !isProjectBusy else { return false }
        if let wait = brushSampleWait, wait.stroke === stroke {
            // Busy before returning, so the next input event already waits for the source and the commit.
            isProjectBusy = true
            wait.finishes = true
            return true
        }
        if stroke.settings.healing {
            // Busy before returning, so the next input event already waits for the heal.
            isProjectBusy = true
            Task { await finishHealing(stroke) }
            return true
        }
        defer { cancelBrush() }
        do {
            // Smoothing leaves the brush short of the pointer; the stroke ends where the hand did.
            if let pointer = brushPointer, let anchor = brushAnchor, pointer != anchor,
               tool == .brush, brushSettings.smoothing > 0 {
                try stroke.append(pointer)
            }
            try stroke.flush()
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
        return true
    }

    /// Ends the stroke and returns once it is committed, Spot Healing's heal included.
    func finishBrush() async {
        if let stroke = brushStroke, stroke.settings.healing, !isProjectBusy { await finishHealing(stroke); return }
        if let wait = brushSampleWait, wait.stroke === brushStroke {
            if !wait.finishes, !finishBrushImmediately() { return }
            await wait.task?.value
            return
        }
        finishBrushImmediately()
    }

    /// Renders a Clone Stamp or Blur source off the main thread for `stroke`, which starts at `point`; its points
    /// wait in `brushSampleWait` until the source lands (see `landSample`).
    private func awaitSample(_ job: BrushSampleJob, offset: CGSize, for stroke: BrushStroke, from point: CGPoint) {
        let wait = BrushSampleWait(stroke: stroke, offset: offset, name: stroke.isBlur ? "Blur" : "Clone Stamp", first: point)
        brushSampleWait = wait
        wait.task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> BrushSampleResult in
                do { return BrushSampleResult(image: try job.render(), error: nil) }
                catch { return BrushSampleResult(image: nil, error: error) }
            }.value
            self?.landSample(result, for: wait)
        }
    }

    /// The source is in: the stroke's waiting points are painted from it, and a stroke already let go is committed.
    private func landSample(_ result: BrushSampleResult, for wait: BrushSampleWait) {
        if wait.finishes { isProjectBusy = false }
        // Cancelled, or another stroke since: nothing is left to paint from it.
        guard brushSampleWait === wait, brushStroke === wait.stroke else {
            ToolLog.staleResult(wait.name)
            return
        }
        brushSampleWait = nil
        guard let image = result.image else {
            cancelBrush()
            brushError = (result.error ?? ExportError.render).localizedDescription
            return
        }
        let stroke = wait.stroke
        stroke.clone = (image, wait.offset)
        do {
            for point in wait.points { try stroke.append(point) }
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription; return }
        if wait.finishes { finishBrushImmediately() }
    }

    /// Install immutable tiles immediately, including the undo entry. The next
    /// stroke and other tools can start without awaiting full-image assembly.
    func commitPaintSnapshot(_ stroke: BrushStroke) throws {
        let result = try stroke.paintSnapshot()
        // As `commitRasterEdit`: a result that can't be placed is reported, not dropped.
        guard result.transform.isValid else { throw ProjectError.tooLarge }
        // Painted from these pixels and this placement; never written over others.
        guard let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform else {
            ToolLog.staleResult(stroke.editName ?? "Brush Stroke")
            return
        }
        var mask = current.mask
        if !stroke.isMask, let original = mask, original.placement == nil, result.bounds != stroke.sourceRect {
            let raster = RasterSnapshot.replacing(source: original.asset, sourceRect: stroke.sourceRect,
                patches: [], crop: result.bounds, isMask: true)
            mask = original.replacing(ImportedImage(image: try raster.makeImage(), thumbnail: try raster.thumbnail(),
                name: original.asset.name, raster: raster))
        }
        beginEdit(stroke.editName ?? (stroke.isMask ? "Paint Mask" : stroke.settings.erasing ? "Erase" : stroke.isBlur ? "Blur" : stroke.clone != nil ? "Clone Stamp" : stroke.settings.healing ? "Spot Healing" : "Brush Stroke"))
        if stroke.isMask {
            document?.layers[index].mask = current.mask.map { $0.replacing(result.asset) } ?? LayerMask(asset: result.asset)
        } else {
            document?.layers[index] = current.replacingPixels(result.asset, transform: result.transform, mask: mask)
        }
        endEdit()
    }

    /// Assembles a raster edit off the main thread and replaces the layer's pixels or
    /// mask as one undo step. Other layer properties are read at commit time. False when the layer changed while it
    /// was assembled, and the result was dropped.
    @discardableResult
    func commitRasterEdit(_ stroke: BrushStroke, name: String, alsoApply: (() -> Void)? = nil) async throws -> Bool {
        isProjectBusy = true
        defer { isProjectBusy = false }
        guard stroke.committedTransform.isValid else { throw ProjectError.tooLarge }
        let input = stroke.commitInput()
        let result = try await BrushCommit.shared.render(input)
        let asset = result.asset
        let transform = stroke.transform(for: result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY))
        guard transform.isValid else { throw ProjectError.tooLarge }
        var mask = stroke.layer.mask
        if !stroke.isMask, let originalMask = mask, originalMask.placement == nil {
            mask = originalMask.replacing(try await BrushCommit.shared.expandMask(originalMask.asset, for: input, croppedTo: result.pixelBounds))
        }
        // The raster was built from this layer's pixels, transform, and mask; never
        // write it over content that changed underneath it.
        guard let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform,
              current.mask?.asset.image === stroke.layer.mask?.asset.image else {
            ToolLog.staleResult(name)
            return false
        }
        beginEdit(name)
        if stroke.isMask {
            document?.layers[index].mask = current.mask.map { $0.replacing(asset) } ?? LayerMask(asset: asset)
        } else {
            document?.layers[index] = current.replacingPixels(asset, transform: transform,
                mask: mask.map { mask -> LayerMask in
                    var kept = mask
                    kept.isEnabled = current.mask?.isEnabled ?? mask.isEnabled
                    return kept
                })
        }
        alsoApply?()
        endEdit()
        return true
    }
    /// Tools where number keys set opacity: the brush or gradient opacity, or with
    /// Move/Transform the opacity of the selected layers.
    var usesOpacityKeys: Bool { tool.isBrushTool || tool == .gradient || tool == .move }

    /// Photoshop-style opacity keys: 1 = 10% … 9 = 90%, 0 = 100%.
    /// Two digits typed quickly set an exact value (4 then 5 = 45%, 0 then 5 = 5%).
    func typeOpacityDigit(_ digit: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard usesOpacityKeys, brushStroke == nil, !isProjectBusy, (0...9).contains(digit) else { return }
        var percent = digit == 0 ? 100 : digit * 10
        if let pending = pendingOpacityDigit, time - pending.time < 0.6 {
            percent = max(1, pending.digit * 10 + digit)
            pendingOpacityDigit = nil
        } else {
            pendingOpacityDigit = (digit, time)
        }
        let value = CGFloat(percent) / 100
        switch tool {
        case .brush, .spotHealing, .cloneStamp, .blur: brushSettings.opacity = value
        case .gradient: gradientSettings.opacity = value
        default: setSelectedLayersOpacity(Double(value))
        }
    }
    /// Shift-[ / Shift-]: hardness in Photoshop's 25% steps (0, 25, 50, 75, 100%).
    func changeBrushHardness(increase: Bool) {
        guard brushStroke == nil else { return }
        // Snap to the next step up or down, so 80% goes to 100% or 75%.
        let quarter = brushSettings.hardness * 4
        let step = increase ? floor(quarter + 0.001) + 1 : ceil(quarter - 0.001) - 1
        brushSettings.hardness = min(4, max(0, step)) / 4
    }
    func changeBrushSize(increase: Bool) {
        guard brushStroke == nil else { return }
        // A step of a fifth, but always at least one pixel: 2 shrunk by a fifth would otherwise round back to 2,
        // leaving the smallest brushes out of reach.
        let current = brushSettings.diameter
        let stepped = increase ? max(current + 1, (current * 1.2).rounded()) : min(current - 1, (current / 1.2).rounded())
        brushSettings.diameter = min(2000, max(1, stepped))
    }
}
