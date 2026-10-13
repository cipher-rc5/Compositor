import AppKit
import Observation
import os

nonisolated enum LevelsChannel: String, CaseIterable, Sendable, Codable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var index: Int { Self.allCases.firstIndex(of: self)! }
}
nonisolated struct LevelRange: Equatable, Sendable, Codable {
    var black: Double = 0
    var gamma: Double = 1
    var white: Double = 255
    var outputBlack: Double = 0
    var outputWhite: Double = 255
    var normalized: Self {
        func clamp(_ n: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
        }
        var result = self
        result.black = clamp(black, 0...254, 0)
        result.white = clamp(white, (result.black + 1)...255, 255)
        result.gamma = clamp(gamma, 0.1...9.99, 1)
        result.outputBlack = clamp(outputBlack, 0...255, 0)
        result.outputWhite = clamp(outputWhite, 0...255, 255)
        return result
    }
    func apply(_ value: Double) -> Double {
        let s = normalized
        let input = min(1, max(0, (value * 255 - s.black) / (s.white - s.black)))
        return (s.outputBlack + pow(input, 1 / s.gamma) * (s.outputWhite - s.outputBlack)) / 255
    }
}
nonisolated struct LevelsSettings: Equatable, Sendable, Codable {
    var channel: LevelsChannel = .rgb
    var ranges = Array(repeating: LevelRange(), count: 4)
    var current: LevelRange {
        get { ranges[channel.index] }
        set { ranges[channel.index] = newValue.normalized }
    }
    var isIdentity: Bool { ranges.allSatisfy { $0.normalized == LevelRange() } }
    /// Individual channels, followed by the composite RGB adjustment.
    func apply(_ value: Double, channel: LevelsChannel) -> Double {
        ranges[0].apply(ranges[channel.index].apply(value))
    }
}
/// Display-only vertical scaling. Keep linear bin ratios, but cap isolated spikes
/// so large solid backgrounds cannot flatten the useful tonal distribution.
nonisolated enum LevelsHistogramDisplay {
    static func scale(for bins: [Double]) -> Double {
        let peak = bins.filter { $0.isFinite && $0 > 0 }.max() ?? 0
        guard peak > 0 else { return 0 }
        let interior = bins.dropFirst().dropLast().filter { $0.isFinite && $0 > 0 }.sorted()
        guard !interior.isEmpty else { return peak }
        let typicalPeak = interior[Int(Double(interior.count - 1) * 0.95)]
        return min(peak, typicalPeak * 4)
    }
}

nonisolated struct LevelsJob: Sendable {
    let image: CGImage
    let settings: LevelsSettings
    let selection: SelectionClip?
    let mapping: CGAffineTransform
}
nonisolated enum LevelsFilter {
    static func run(_ job: LevelsJob) throws -> CGImage {
        if job.settings.isIdentity { return job.image }
        let context = try BrushRaster.context(width: job.image.width, height: job.image.height, mask: false)
        BrushRaster.draw(job.image, in: CGRect(x: 0, y: 0, width: job.image.width, height: job.image.height), mask: false, context: context)
        let tables = [LevelsChannel.red, .green, .blue].flatMap { channel in
            (0...255).map { Float(job.settings.apply(Double($0) / 255, channel: channel)) }
        }
        guard let data = context.data else { throw ExportError.render }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // The tables are for colors, not colors already multiplied by their alpha, and `levels_apply` already
        // divides each channel by its alpha before the lookup and multiplies it back after. Doing it here as
        // well ran a soft edge through the conversion twice: 50% grey at half alpha came out at a quarter.
        levels_apply(pixels, job.image.width, job.image.height, context.bytesPerRow, tables)
        guard let image = context.makeImage() else { throw ExportError.render }
        if let selection = job.selection {
            return try PixelAdjust.blend(image, over: job.image, through: selection, pixelToDocument: job.mapping, isMask: false)
        }
        return image
    }
    /// RGB is the mean of the three channel histograms, not a luminance histogram.
    static func histogram(_ job: LevelsJob) throws -> [[Double]] {
        let w = job.image.width, h = job.image.height
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        BrushRaster.draw(job.image, in: CGRect(x: 0, y: 0, width: w, height: h), mask: false, context: context)
        var coverageContext: CGContext?
        if let selection = job.selection {
            let image = try PixelAdjust.coverage(selection, width: w, height: h, pixelToDocument: job.mapping)
            let mask = try BrushRaster.context(width: w, height: h, mask: true)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h), mask: true, context: mask)
            coverageContext = mask
        }
        guard let data = context.data else { throw ExportError.render }
        var bins = Array(repeating: 0.0, count: 1024)
        levels_histogram(data.assumingMemoryBound(to: UInt8.self), w, h, context.bytesPerRow,
            coverageContext?.data?.assumingMemoryBound(to: UInt8.self), coverageContext?.bytesPerRow ?? 0, &bins)
        return (0..<4).map { Array(bins[($0 * 256)..<(($0 + 1) * 256)]) }
    }
}

@Observable
final class LevelsEdit {
    let layerID: UUID
    let original: ImportedImage
    let transform: LayerTransform
    let selection: SelectionClip?
    let mapping: CGAffineTransform
    /// What previews and the histogram read: the layer, or a copy of one larger than `previewLimit`, which
    /// `histogramTask` makes off the main actor before previews start.
    @ObservationIgnored private(set) var previewSource: CGImage
    @ObservationIgnored private(set) var previewMapping: CGAffineTransform
    var sampleMode: LevelsSample?
    var settings = LevelsSettings()
    var preview = true
    var committing = false
    var histogram: [[Double]] = Array(repeating: Array(repeating: 0, count: 256), count: 4)
    var histogramReady = false
    /// Why the histogram could not be counted; Auto stays off without it.
    var histogramError: String?
    /// Why the last preview could not be made, shown in the panel.
    var previewError: String?
    @ObservationIgnored var preparedPreview: CGImage?
    @ObservationIgnored var pending: LevelsJob?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    /// Makes the preview copy (when one is needed), then counts the histogram.
    @ObservationIgnored var histogramTask: Task<Void, Never>?
    /// Set while previews wait for the copy `histogramTask` makes.
    @ObservationIgnored private(set) var awaitsPreviewCopy: Bool

    /// Full size up to 8000 pixels on a side: a levels preview is a lookup table per pixel, quick enough to run
    /// on the whole layer, and a downscaled copy showed the canvas a coarse, pixelated version while dragging.
    nonisolated static let previewLimit: CGFloat = 8000

    /// Reads no pixels, so the panel opens at once on any layer (see `EditorSession.prepareLevels`).
    init(layer: ImageLayer, selection: SelectionClip?) throws {
        guard let asset = layer.asset else { throw ProjectError.invalid }
        layerID = layer.id; original = asset; transform = layer.transform; self.selection = selection
        mapping = BrushRaster.pixelToDocument(transform, width: original.image.width, height: original.image.height)
        previewSource = original.image
        previewMapping = mapping
        awaitsPreviewCopy = PixelAdjust.needsPreviewCopy(original.image, limit: Self.previewLimit)
    }
    func adopt(_ copy: PixelAdjust.PreviewCopy?) {
        if let copy { previewSource = copy.image; previewMapping = copy.mapping }
        awaitsPreviewCopy = false
    }
    func previewImage(for id: UUID) -> CGImage? { preview && id == layerID ? preparedPreview : nil }
    var previewJob: LevelsJob { LevelsJob(image: previewSource, settings: settings, selection: selection, mapping: previewMapping) }
}

extension EditorSession {
    func beginLevels() {
        guard levels == nil, hueSaturation == nil, canAdjustColors else { return }
        if gradientEdit != nil {
            Task { await commitGradient(); beginLevels() }
            return
        }
        commitTransform(); cancelCrop(); cancelLasso()
        guard let layer = activeLayer, let document else { return }
        do {
            let edit = try LevelsEdit(layer: layer, selection: selection?.clip(canvas: document.size))
            levels = edit
            prepareLevels(edit)
        } catch { brushError = error.localizedDescription }
    }

    /// Off the main actor: the smaller copy previews read when the layer is past `previewLimit`, then the histogram
    /// of what they read. Both come from `edit.original`, the pixels OK adjusts and checks are still on the layer.
    /// A failure is shown in the panel rather than leaving an empty histogram that makes Auto do nothing.
    func prepareLevels(_ edit: LevelsEdit) {
        let job = edit.previewJob, copies = edit.awaitsPreviewCopy, original = edit.original, transform = edit.transform
        edit.histogramTask = Task { @MainActor [weak self, weak edit] in
            let result: (copy: PixelAdjust.PreviewCopy?, bins: [[Double]]?, problem: String?)
            do {
                result = try await PixelAdjust.detached { () throws -> (PixelAdjust.PreviewCopy?, [[Double]]?, String?) in
                    var job = job, copy: PixelAdjust.PreviewCopy?, problem: String?
                    if copies {
                        // Without the copy, previews and the histogram read the full-size layer: slower, but right.
                        do { copy = try PixelAdjust.previewCopy(of: original.image, raster: original.raster,
                                                                limit: LevelsEdit.previewLimit, placed: transform) }
                        catch { problem = error.localizedDescription }
                        try Task.checkCancellation()
                    }
                    if let copy { job = LevelsJob(image: copy.image, settings: job.settings, selection: job.selection, mapping: copy.mapping) }
                    do { return (copy, try LevelsFilter.histogram(job), problem) }
                    catch { return (copy, nil, error.localizedDescription) }
                }
            } catch {
                return // Cancelled: the panel closed or OK took over.
            }
            guard let self, let edit, self.levels === edit, !Task.isCancelled else {
                adjustmentLog.debug("A Levels histogram finished after its panel closed; it was discarded")
                return
            }
            edit.adopt(result.copy)
            if let bins = result.bins {
                edit.histogram = bins
                edit.histogramReady = true
            } else {
                edit.histogramError = "The histogram couldn’t be counted: \(result.problem ?? "")"
                adjustmentLog.error("Levels histogram failed: \(result.problem ?? "", privacy: .public)")
            }
            self.renderLevelsPreview(edit)
        }
    }
    func updateLevels(_ settings: LevelsSettings, preview: Bool) {
        guard let edit = levels, !edit.committing else { return }
        edit.settings = settings; edit.preview = preview
        if previewAdjustmentEditing(preview: preview) { return }
        if !preview || settings.isIdentity {
            edit.previewTask?.cancel(); edit.previewTask = nil; edit.pending = nil
            edit.preparedPreview = nil; brushRevision += 1
            return
        }
        edit.pending = edit.previewJob
        renderLevelsPreview(edit)
    }
    private func renderLevelsPreview(_ edit: LevelsEdit) {
        guard levels === edit, edit.previewTask == nil, !edit.awaitsPreviewCopy, let pending = edit.pending else { return }
        edit.pending = nil
        // Read the preview copy as it is now: one made since this was queued replaces the full-size layer.
        let job = LevelsJob(image: edit.previewSource, settings: pending.settings, selection: pending.selection, mapping: edit.previewMapping)
        edit.previewTask = Task { @MainActor [weak self, weak edit] in
            let result: CGImage?, problem: String?
            do { result = try await PixelAdjust.detached { try LevelsFilter.run(job) }; problem = nil }
            catch is CancellationError { return }
            catch { result = nil; problem = error.localizedDescription }
            guard let self, let edit, self.levels === edit, !Task.isCancelled else {
                adjustmentLog.debug("A Levels preview finished after its panel closed; it was discarded")
                return
            }
            edit.previewTask = nil
            edit.previewError = problem
            if edit.preview, !edit.settings.isIdentity { edit.preparedPreview = result; self.brushRevision += 1 }
            self.renderLevelsPreview(edit)
        }
    }
    func cancelLevels() {
        if finishAdjustmentEditing(commit: false) { return }
        guard let edit = levels, !edit.committing else { return }
        edit.previewTask?.cancel(); edit.histogramTask?.cancel()
        levels = nil; brushRevision += 1
    }
    func commitLevels() async {
        if finishAdjustmentEditing(commit: true) { return }
        guard let edit = levels, !edit.committing else { return }
        if edit.settings.isIdentity { cancelLevels(); return }
        edit.committing = true
        edit.previewTask?.cancel(); edit.histogramTask?.cancel()
        isProjectBusy = true
        defer { levels = nil; isProjectBusy = false; brushRevision += 1 }
        let job = LevelsJob(image: edit.original.image, settings: edit.settings, selection: edit.selection, mapping: edit.mapping)
        do {
            let asset = try await Task.detached(priority: .userInitiated) {
                let image = try LevelsFilter.run(job)
                return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Levels")
            }.value
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let current = document?.layers[index], current.asset?.image === edit.original.image,
                  current.transform == edit.transform else { reportDroppedApply("Levels"); return }
            beginEdit("Levels")
            document?.layers[index] = current.replacingPixels(asset, mask: current.mask)
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
