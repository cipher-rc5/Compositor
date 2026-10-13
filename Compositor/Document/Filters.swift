import AppKit
import CoreImage
import Observation
import os

/// Filters from the Filter menu. Each runs on the active image layer, inside the selection if
/// there is one, with a live preview and one undo step on OK.
nonisolated enum FilterKind: String, CaseIterable, Sendable {
    case gaussianBlur = "Gaussian Blur"
    case motionBlur = "Motion Blur"
    case addNoise = "Add Noise"
    case lensCorrection = "Lens Correction"
    case cameraRaw = "Camera Raw Filter"
    case removeBackground = "Remove Background"
    case contentAwareFill = "Content-Aware Fill"
    case curves = "Curves"
    case exposure = "Exposure"
    case gradientMap = "Gradient Map"
    case grain = "Grain"
    case blackWhite = "Black & White"
    case colorBalance = "Color Balance"
    var isAutomatic: Bool { self == .contentAwareFill || self == .removeBackground }
    /// Color adjustments: in the Image menu (and editable as adjustment layers), not under Filter.
    var isImageAdjustment: Bool {
        self == .curves || self == .exposure || self == .gradientMap || self == .grain
            || self == .blackWhite || self == .colorBalance
    }
}

/// Remove Background's two ways of working: Apple's own subject mask on its own, or that mask refined against the
/// layer's detail, which recovers hair and fur but takes longer.
nonisolated enum BackgroundQuality: String, CaseIterable, Sendable {
    case basic = "Basic"
    case advanced = "Advanced"
}

/// Every filter's settings; each filter reads only its own.
nonisolated struct FilterSettings: Equatable, Sendable {
    /// Gaussian Blur radius in layer pixels (the blur's standard deviation), 0.1–250.
    var radius: Double = 1
    /// Motion Blur direction in degrees, counterclockwise from horizontal as in Photoshop, −90–90.
    var angle: Double = 0
    /// Motion Blur streak length in layer pixels, 1–2000.
    var distance: Double = 10
    /// Add Noise strength as Photoshop's percentage, 0.1–400.
    var amount: Double = 10
    /// Add Noise distribution: Gaussian (more speckled) instead of Uniform.
    var gaussian = false
    /// Add Noise changes brightness only, the same amount on every channel.
    var monochromatic = false
    /// Lens Correction's Remove Distortion, −100–100: positive straightens barrel distortion
    /// (lines bowing outward), negative straightens pincushion (lines bowing inward).
    var distortion: Double = 0
    var curves = CurvesSettings()
    var exposure = ExposureSettings()
    var gradientMap = GradientMapSettings()
    var grain = GrainSettings()
    var blackWhite = BlackWhiteSettings()
    var colorBalance = ColorBalanceSettings()
    var cameraRaw = CameraRawSettings()
    /// Remove Background: Basic is the quick subject mask; Advanced refines it (see the three settings below).
    var backgroundQuality: BackgroundQuality = .basic
    /// Remove Background: how far the mask is pulled onto the image's own edges (0 off, in layer pixels).
    var refineEdges: Double = 12
    /// Remove Background: pushes the mask's grays toward black and white, 0–100, clearing haze in thin areas.
    var matteContrast: Double = 25
    /// Remove Background: contracts (negative) or expands (positive) the mask edge, in layer pixels.
    var shiftEdge: Double = 0
    var normalized: Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        var result = self
        result.radius = clamp(radius, 0.1...250, 1)
        result.angle = clamp(angle, -90...90, 0)
        result.distance = clamp(distance, 1...2000, 10)
        result.amount = clamp(amount, 0.1...400, 10)
        result.distortion = clamp(distortion, -100...100, 0)
        result.refineEdges = clamp(refineEdges, 0...40, 12)
        result.matteContrast = clamp(matteContrast, 0...100, 25)
        result.shiftEdge = clamp(shiftEdge, -10...10, 0)
        result.exposure = exposure.normalized
        result.gradientMap = gradientMap.normalized
        result.grain = grain.normalized
        result.cameraRaw = cameraRaw.normalized
        return result
    }
}

nonisolated struct FilterJob: Sendable {
    let kind: FilterKind
    var image: CGImage
    let settings: FilterSettings
    /// Pixels in `image` per original layer pixel, so a downscaled preview blurs proportionally less.
    var scale: CGFloat
    let selection: SelectionClip?
    var mapping: CGAffineTransform
    /// Add Noise's random pattern: the same seed gives the same grain.
    var seed: UInt32 = 0
    /// Canvas-space origin used by live adjustment layers so partial redraws keep one noise field.
    var noiseOrigin: CGPoint = .zero
    /// Camera Raw's Option-drag clipping view. Preview only; committing leaves this nil.
    var cameraRawClipping: CameraRawClipping? = nil
    /// Persistent histogram clipping indicators. Preview only; committing leaves these off.
    var showsShadowClipping = false
    var showsHighlightClipping = false
    /// Point-color range preview. −1 leaves the grade alone.
    var visualizesPointColor = -1
    /// Option-drag on Sharpening Masking. Preview only.
    var showsSharpenMask = false
}

nonisolated enum PixelFilter {
    /// `image` cropped to the pixels that are actually there, with the transform that keeps them in place: a blur
    /// is given generous room to spread, and whatever it leaves empty is cut away again.
    static func trimmed(_ image: CGImage, placed: LayerTransform) throws -> (image: CGImage, transform: LayerTransform) {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: full, mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow, &edges)
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        guard crop.width >= 1, crop.height >= 1, crop != full, let cropped = image.cropping(to: crop) else {
            return (image, placed)
        }
        var result = placed
        result.size = CGSize(width: crop.width * placed.size.width / full.width,
                             height: crop.height * placed.size.height / full.height)
        let toDocument = BrushRaster.pixelToDocument(placed, width: image.width, height: image.height)
        let middle = CGPoint(x: crop.midX, y: crop.midY).applying(toDocument)
        result.origin = CGPoint(x: middle.x - result.size.width / 2, y: middle.y - result.size.height / 2)
        return (cropped, result)
    }

    /// `CIMotionBlur`'s radius per pixel of streak length. Photoshop smears evenly along the whole
    /// distance; Core Image tapers like a Gaussian whose spread is about its radius (measured on a
    /// single dot). An even streak of length d spreads d / √12, so this radius matches its spread.
    static let motionRadiusPerPixel = 1 / 12.0.squareRoot()
    /// Remove Distortion at ±100 moves the image's corners by this share of their distance from the center.
    static let lensStrength = 0.35

    static func run(_ job: FilterJob) throws -> CGImage {
        let settings = job.settings.normalized
        let width = job.image.width, height = job.image.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Not clamped: a blur softens the layer's edges and spreads into the room made for it, rather than
        // smearing the border outwards and stopping at it.
        let edges = CIImage(cgImage: job.image)
        let image: CGImage
        switch job.kind {
        case .curves: image = try settings.curves.apply(job.image)
        case .exposure: image = try settings.exposure.apply(job.image)
        case .gradientMap: image = try settings.gradientMap.apply(job.image)
        case .blackWhite: image = try settings.blackWhite.apply(job.image)
        case .colorBalance: image = try settings.colorBalance.apply(job.image)
        case .cameraRaw: image = try settings.cameraRaw.apply(job.image, clipping: job.cameraRawClipping, scale: job.scale, seed: job.seed,
                                                                visualizePointColor: job.visualizesPointColor, sharpenMask: job.showsSharpenMask)
        // Grain sits in layer pixels; the job's seed gives each application its own pattern.
        case .grain: image = try settings.grain.apply(job.image, unitsPerPixel: 1 / job.scale, seed: job.seed)
        case .removeBackground:
            image = try SubjectRemoval.run(job.image, settings: settings)
        case .contentAwareFill:
            image = try ContentFill.run(job)
        case .gaussianBlur:
            let blurred = edges.applyingGaussianBlur(sigma: settings.radius * job.scale)
            image = try PixelAdjust.render(blurred.cropped(to: extent), width: width, height: height, isMask: false)
        case .motionBlur:
            // Core Image's y axis points up, so its counterclockwise angle matches Photoshop's.
            let streaked = edges.applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: settings.distance * job.scale * motionRadiusPerPixel,
                kCIInputAngleKey: settings.angle * .pi / 180,
            ])
            image = try PixelAdjust.render(streaked.cropped(to: extent), width: width, height: height, isMask: false)
        case .addNoise:
            // C, not Core Image: its random generator is uniform only, and Gaussian noise is needed too.
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: context)
            guard let data = context.data else { throw ExportError.render }
            noise_add_at(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow,
                         Float(settings.amount), settings.gaussian ? 1 : 0, settings.monochromatic ? 1 : 0, job.seed,
                         Int64(job.noiseOrigin.x.rounded(.down)), Int64(job.noiseOrigin.y.rounded(.down)))
            guard let noisy = context.makeImage() else { throw ExportError.render }
            image = noisy
        case .lensCorrection:
            // The warp is relative to the image's own size, so a downscaled preview bends the same way.
            let source = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: source)
            let destination = try BrushRaster.context(width: width, height: height, mask: false)
            guard let from = source.data, let into = destination.data else { throw ExportError.render }
            lens_distort(from.assumingMemoryBound(to: UInt8.self), into.assumingMemoryBound(to: UInt8.self),
                         width, height, source.bytesPerRow, settings.distortion / 100 * lensStrength)
            guard let corrected = destination.makeImage() else { throw ExportError.render }
            image = corrected
        }
        guard let selection = job.selection else { return image }
        return try PixelAdjust.blend(image, over: job.image, through: selection, pixelToDocument: job.mapping, isMask: false)
    }
}

/// A layer's pixels padded out into a larger grid, the transform placing it, and what a filter and its preview read.
nonisolated struct GrownGrid: Sendable {
    let image: CGImage
    let transform: LayerTransform
    /// How far the grid reaches beyond the layer on every side, in layer pixels.
    let margin: CGFloat
    let mapping: CGAffineTransform
    let previewSource: CGImage
    let previewScale: CGFloat
    let previewMapping: CGAffineTransform
}

@Observable
final class FilterEdit {
    let kind: FilterKind
    let layerID: UUID
    let original: ImportedImage
    let transform: LayerTransform
    let selection: SelectionClip?
    var mapping: CGAffineTransform
    var previewSource: CGImage
    var previewScale: CGFloat
    var previewMapping: CGAffineTransform
    /// A filter reaching past the layer's edge — Content-Aware Fill over a selection, a blur spreading outwards —
    /// works on the layer's pixels padded out, and on the transform placing that larger grid.
    var grownImage: CGImage? = nil
    var grownTransform: LayerTransform? = nil
    /// How far the padding reaches beyond the layer on every side, in layer pixels.
    var grownMargin: CGFloat = 0
    var settings: FilterSettings
    var preview = true
    var committing = false
    var previewError: String?
    var preparing = false
    /// Add Noise's grain, fixed while the panel is open so changing Amount doesn't reshuffle it.
    let seed = UInt32.random(in: .min ... .max)
    /// Camera Raw panel eyes. Off drops that group's amounts from the preview and from OK, without clearing the sliders.
    var showsCameraRawLight = true
    var showsCameraRawColor = true
    var showsCameraRawEffects = true
    var showsCameraRawCurve = true
    var showsCameraRawMixer = true
    var showsCameraRawGrading = true
    var showsCameraRawDetail = true
    var showsCameraRawOptics = true
    var showsCameraRawGeometry = true
    var showsCameraRawCalibration = true
    var cameraRawCurvePage: CameraRawCurvePage = .parametric
    var cameraRawPointChannel: CameraRawPointChannel = .rgb
    var cameraRawMixerPage: CameraRawMixerPage = .hsl
    var cameraRawMixerTab: CameraRawMixerTab = .hue
    var cameraRawMixerSwatch = 0
    var cameraRawPointIndex = 0
    var cameraRawGradePage: CameraRawGradePage = .threeWay
    var targetsCameraRawCurve = false
    var targetsCameraRawMixer = false
    var samplesPointColor = false
    var cameraRawDrag: CameraRawDrag?
    var pointColorVisualizeIndex: Int {
        let points = settings.cameraRaw.mixer.points
        guard points.indices.contains(cameraRawPointIndex), points[cameraRawPointIndex].visualize else { return -1 }
        return cameraRawPointIndex
    }
    /// White-balance eyedropper, armed from the Color section.
    var samplesWhiteBalance = false
    /// Defringe eyedropper, armed from Optics. Sets purple or green hue range from the clicked fringe.
    var samplesDefringe = false
    /// Guided Upright: drag lines on the preview.
    var drawingCameraRawGeometryGuide = false
    var cameraRawGuideDraft: (start: CGPoint, end: CGPoint)?
    /// Set while Option is held on Exposure, Highlights, Shadows, Whites, or Blacks.
    var cameraRawClipping: CameraRawClipping?
    /// Set while Option is held on Sharpening Masking.
    var cameraRawSharpenMask = false
    /// Histogram clipping indicators. They paint the preview and are not baked in on OK.
    var showsShadowClipping = false
    var showsHighlightClipping = false
    /// Histogram, or the vectorscope chosen from its context menu.
    var cameraRawScopeMode: CameraRawScopeMode = .histogram
    var cameraRawScope: CameraRawScope?
    /// RGB of the pixel under the pointer, in the adjusted preview.
    var cameraRawReadout: (red: Int, green: Int, blue: Int)?
    @ObservationIgnored var preparedPreview: CGImage?
    /// The settings `preparedPreview` was made with, for the automatic filters that have settings of their own.
    @ObservationIgnored var preparedSettings: FilterSettings?
    @ObservationIgnored var pending: FilterJob?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    /// White Balance > Auto's scan of the layer, cancelled with the panel.
    @ObservationIgnored var whiteBalanceTask: Task<Void, Never>?
    /// Content-Aware Fill's selection past the layer's edge, in layer pixels, until the grid covering it is made.
    @ObservationIgnored private(set) var pendingArea: CGRect?
    /// Previews read the full-size layer until the first one has made the smaller copy `prepared` describes.
    @ObservationIgnored private(set) var awaitsPreviewCopy: Bool
    /// Previews render from a copy no larger than this on its longest side.
    nonisolated static let previewLimit: CGFloat = 2048

    /// `growingTo`: a document area the layer's grid should cover (Content-Aware Fill's selection on the canvas).
    /// A blur grows the grid by its own reach instead, and again if its amount is raised. Nothing here reads the
    /// layer's pixels: the padded grid and the smaller preview copy are made with the first preview, off the main
    /// actor, so opening the panel on a large layer doesn't stall. Until then previews read the layer as it is.
    init(kind: FilterKind, layer: ImageLayer, selection: SelectionClip?, settings: FilterSettings, growingTo area: CGRect? = nil) throws {
        guard let asset = layer.asset else { throw ProjectError.invalid }
        self.kind = kind
        self.settings = settings.normalized
        layerID = layer.id; original = asset; transform = layer.transform; self.selection = selection
        let mapping = BrushRaster.pixelToDocument(layer.transform, width: asset.image.width, height: asset.image.height)
        self.mapping = mapping
        previewSource = asset.image
        previewScale = 1
        previewMapping = mapping
        awaitsPreviewCopy = !Self.previewsAtFullSize(kind) && PixelAdjust.needsPreviewCopy(asset.image, limit: Self.previewLimit)
        if let area {
            let extent = area.applying(mapping.inverted()).integral
            let bounds = CGRect(x: 0, y: 0, width: asset.image.width, height: asset.image.height)
            if bounds.union(extent).integral != bounds { pendingArea = extent }
        }
    }

    /// The room a blur needs around the layer: about three standard deviations, or half a streak.
    static func blurMargin(_ kind: FilterKind, _ settings: FilterSettings) -> CGFloat {
        switch kind {
        case .gaussianBlur: return CGFloat(settings.radius * 3 + 2)
        case .motionBlur: return CGFloat(settings.distance / 2 + 2)
        default: return 0
        }
    }

    /// The grid (layer pixels) a blur at the current amount needs, when the one it has is too small. The grid only
    /// ever grows, so easing the amount back off doesn't rebuild anything.
    var blurExtent: CGRect? {
        let margin = Self.blurMargin(kind, settings)
        guard margin > grownMargin else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
        return bounds.insetBy(dx: -margin.rounded(.up), dy: -margin.rounded(.up))
    }

    /// The grid the filter still needs made: Content-Aware Fill's selection, or the room a blur's amount needs.
    var pendingExtent: CGRect? { pendingArea ?? blurExtent }

    /// Switches the filter and its preview over to a grid made by `grown`.
    func adopt(_ grid: GrownGrid) {
        grownImage = grid.image
        grownTransform = grid.transform
        grownMargin = grid.margin
        mapping = grid.mapping
        previewSource = grid.previewSource
        previewScale = grid.previewScale
        previewMapping = grid.previewMapping
        pendingArea = nil
        awaitsPreviewCopy = false
    }

    /// Previews switch to the smaller copy of the layer made by `prepared`.
    func adopt(_ copy: PixelAdjust.PreviewCopy) {
        guard awaitsPreviewCopy else { return }
        previewSource = copy.image
        previewScale = copy.scale
        previewMapping = copy.mapping
        awaitsPreviewCopy = false
    }

    /// The layer's pixels drawn into a grid covering `extent` (layer pixels), with the transform that places it; nil
    /// when the layer already covers it. Nonisolated: dragging a blur's amount up pads the full-size layer off the
    /// main actor (see `renderFilterPreview`).
    nonisolated static func grown(kind: FilterKind, original: ImportedImage, transform: LayerTransform,
                                  to extent: CGRect) throws -> GrownGrid? {
        let bounds = CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
        let target = bounds.union(extent).integral
        guard target != bounds else { return nil }
        guard target.width <= 30_000, target.height <= 30_000, target.width * target.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(target.width), height: Int(target.height), mask: false)
        let inside = bounds.offsetBy(dx: -target.minX, dy: -target.minY)
        if let raster = original.raster { raster.draw(in: inside, context: context) }
        else { BrushRaster.draw(original.image, in: inside, mask: false, context: context) }
        guard let image = context.makeImage() else { throw ExportError.render }
        let toDocument = BrushRaster.pixelToDocument(transform, width: original.image.width, height: original.image.height)
        var expanded = transform
        expanded.size = CGSize(width: target.width * transform.size.width / bounds.width,
                               height: target.height * transform.size.height / bounds.height)
        let middle = CGPoint(x: target.midX, y: target.midY).applying(toDocument)
        expanded.origin = CGPoint(x: middle.x - expanded.size.width / 2, y: middle.y - expanded.size.height / 2)
        let margin = min(bounds.minX - target.minX, bounds.minY - target.minY,
                         target.maxX - bounds.maxX, target.maxY - bounds.maxY)
        let ready = try prepared(kind: kind, from: image, placed: expanded)
        return GrownGrid(image: image, transform: expanded, margin: margin, mapping: ready.mapping,
                         previewSource: ready.previewSource, previewScale: ready.previewScale, previewMapping: ready.previewMapping)
    }

    /// Noise and grain preview at full size: grain made on a smaller copy would look coarser once enlarged.
    nonisolated static func previewsAtFullSize(_ kind: FilterKind) -> Bool {
        [.addNoise, .grain, .contentAwareFill, .removeBackground].contains(kind)
    }

    /// What the filter and its preview read: the full-size grid, and a copy no larger than `previewLimit` for
    /// everything but the filters that must be made at full size.
    nonisolated static func prepared(kind: FilterKind, from source: CGImage, placed: LayerTransform) throws
        -> (mapping: CGAffineTransform, previewSource: CGImage, previewScale: CGFloat, previewMapping: CGAffineTransform) {
        let mapping = BrushRaster.pixelToDocument(placed, width: source.width, height: source.height)
        guard !previewsAtFullSize(kind), let copy = try PixelAdjust.previewCopy(of: source, limit: previewLimit, placed: placed) else {
            return (mapping, source, 1, mapping)
        }
        return (mapping, copy.image, copy.scale, copy.mapping)
    }

    func previewImage(for id: UUID) -> CGImage? { preview && id == layerID ? preparedPreview : nil }
    /// Sliders as they will be rendered: a hidden Camera Raw group contributes nothing.
    func renderSettings() -> FilterSettings {
        var value = settings
        if kind == .cameraRaw {
            value.cameraRaw = value.cameraRaw.applying(showsLight: showsCameraRawLight, showsColor: showsCameraRawColor,
                                                        showsEffects: showsCameraRawEffects, showsCurve: showsCameraRawCurve,
                                                        showsMixer: showsCameraRawMixer, showsGrading: showsCameraRawGrading,
                                                        showsDetail: showsCameraRawDetail, showsOptics: showsCameraRawOptics,
                                                        showsGeometry: showsCameraRawGeometry, showsCalibration: showsCameraRawCalibration)
        }
        return value
    }
    var previewJob: FilterJob {
        var job = FilterJob(kind: kind, image: previewSource, settings: renderSettings(), scale: previewScale, selection: selection,
                            mapping: previewMapping, seed: seed)
        job.cameraRawClipping = cameraRawClipping
        job.showsShadowClipping = showsShadowClipping
        job.showsHighlightClipping = showsHighlightClipping
        job.visualizesPointColor = pointColorVisualizeIndex
        job.showsSharpenMask = cameraRawSharpenMask
        return job
    }
}

extension EditorSession {
    var canContentAwareFill: Bool {
        canAdjustColors && !isMaskSelected && selection?.isEmpty == false && filterEdit == nil && hueSaturation == nil
    }
    func beginFilter(_ kind: FilterKind) {
        if kind == .contentAwareFill && !canContentAwareFill { return }
        guard filterEdit == nil, hueSaturation == nil, canAdjustColors else { NSSound.beep(); return }
        if gradientEdit != nil {
            Task { await commitGradient(); beginFilter(kind) }
            return
        }
        commitTransform(); cancelCrop(); cancelLasso()
        guard let layer = activeLayer, let document else { return }
        do {
            var settings = filterSettings
            // Gradient Map starts from the foreground and background colors, as in Photoshop.
            if kind == .gradientMap {
                settings.gradientMap = GradientMapSettings(shadows: AdjustmentColor(foregroundColor), highlights: AdjustmentColor(backgroundColor))
            }
            // Content-Aware Fill extends the layer over any of the selection on the canvas past its edge.
            let area = kind == .contentAwareFill
                ? selection.map { $0.path.boundingBoxOfPath.intersection(CGRect(origin: .zero, size: document.size)) }.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
                : nil
            let edit = try FilterEdit(kind: kind, layer: layer, selection: selection?.clip(canvas: document.size), settings: settings, growingTo: area)
            filterEdit = edit
            updateFilter(edit.settings, preview: true)
        } catch { brushError = error.localizedDescription }
    }

    func updateFilter(_ settings: FilterSettings, preview: Bool) {
        guard let edit = filterEdit, !edit.committing else { return }
        edit.settings = settings.normalized
        edit.preview = preview
        // A bigger blur needs more room around the layer than it was given; the preview render (or OK) makes it.
        if previewAdjustmentEditing(preview: preview) { return }
        if edit.kind.isAutomatic, edit.preparedPreview != nil, edit.preparedSettings == edit.settings { brushRevision += 1; return }
        guard preview else {
            edit.pending = nil; edit.preparedPreview = nil; brushRevision += 1
            return
        }
        edit.pending = edit.previewJob
        renderFilterPreview(edit)
    }

    /// Renders the newest settings; changes that arrive mid-render wait for it rather than
    /// cancelling it, so dragging a slider keeps the canvas updating.
    private func renderFilterPreview(_ edit: FilterEdit) {
        guard filterEdit === edit, edit.previewTask == nil, var queued = edit.pending else { return }
        edit.pending = nil
        edit.preparing = true
        edit.previewError = nil
        // The job reads what previews read now, which a grid or copy made since it was queued may have replaced.
        queued.image = edit.previewSource; queued.scale = edit.previewScale; queued.mapping = edit.previewMapping
        let job = queued
        // A blur raised past its room pads the full-size layer first, in the same background work as the preview, so
        // a drag never stalls the main actor and the bigger grid and its preview reach the canvas together. The first
        // preview makes Content-Aware Fill's grid, or the smaller copy later previews read, the same way.
        let extent = edit.pendingExtent, forArea = edit.pendingArea != nil, copies = edit.awaitsPreviewCopy
        let kind = edit.kind, original = edit.original, transform = edit.transform
        edit.previewTask = Task { @MainActor [weak self, weak edit] in
            let result: (image: CGImage?, scope: CameraRawScope?, error: String?, grid: GrownGrid?, copy: PixelAdjust.PreviewCopy?)
            do {
                result = try await PixelAdjust.detached { () throws -> (CGImage?, CameraRawScope?, String?, GrownGrid?, PixelAdjust.PreviewCopy?) in
                    // Without the room (a grid past the size limit), the blur previews in the grid it has and says why.
                    var job = job, grid: GrownGrid?, copy: PixelAdjust.PreviewCopy?, problem: String?
                    if let extent {
                        do { grid = try FilterEdit.grown(kind: kind, original: original, transform: transform, to: extent) }
                        catch { problem = error.localizedDescription }
                        try Task.checkCancellation()
                        // Content-Aware Fill can't run in a grid that doesn't reach its selection.
                        if forArea, let problem { return (nil, nil, problem, nil, nil) }
                    } else if copies {
                        // Without the copy, this preview and the next read the full-size layer: slower, but right.
                        do { copy = try PixelAdjust.previewCopy(of: original.image, limit: FilterEdit.previewLimit, placed: transform) }
                        catch { problem = error.localizedDescription }
                        try Task.checkCancellation()
                    }
                    if let grid { job.image = grid.previewSource; job.scale = grid.previewScale; job.mapping = grid.previewMapping }
                    else if let copy { job.image = copy.image; job.scale = copy.scale; job.mapping = copy.mapping }
                    do {
                        if job.kind == .cameraRaw {
                            let made = try CameraRawScope.preview(job)
                            return (made.image, made.scope, problem, grid, copy)
                        }
                        return (try PixelFilter.run(job), nil, problem, grid, copy)
                    } catch let cancelled as CancellationError {
                        throw cancelled
                    } catch {
                        return (nil, nil, error.localizedDescription, grid, copy)
                    }
                }
            } catch {
                return // Cancelled: the panel closed or OK took over, and nothing is waiting for this preview.
            }
            guard let self, let edit, self.filterEdit === edit, !Task.isCancelled else {
                adjustmentLog.debug("A filter preview finished after its panel closed; it was discarded")
                return
            }
            edit.previewTask = nil
            edit.preparing = false
            edit.previewError = result.error
            if let grid = result.grid, forArea || grid.margin > edit.grownMargin { edit.adopt(grid) }
            if let copy = result.copy { edit.adopt(copy) }
            if let scope = result.scope { edit.cameraRawScope = scope }
            if edit.preview || edit.kind.isAutomatic { edit.preparedPreview = result.image; edit.preparedSettings = job.settings; self.brushRevision += 1 }
            self.renderFilterPreview(edit)
        }
    }

    func cancelFilter() {
        // A Gradient Map color still being picked goes with the panel.
        if case .gradientMap = colorPicker?.target { closeColorPicker(commit: false) }
        if finishAdjustmentEditing(commit: false) { return }
        guard let edit = filterEdit, !edit.committing else { return }
        edit.previewTask?.cancel()
        edit.whiteBalanceTask?.cancel()
        filterEdit = nil
        brushRevision += 1
    }

    func commitFilter() async {
        if case .gradientMap = colorPicker?.target { closeColorPicker(commit: true) }
        if finishAdjustmentEditing(commit: true) { return }
        guard let edit = filterEdit, !edit.committing else { return }
        if edit.kind.isAutomatic {
            await edit.previewTask?.value
            guard filterEdit === edit, !edit.committing, edit.preparedPreview != nil, edit.previewError == nil else { return }
            // Remove Background masks from the full-size image, so a preview made at preview size is fine to discard.
        }
        // A hidden Camera Raw group is absent from the layer. Remember that rendered grade, including
        // when every remaining amount is zero, so the next open does not put the hidden sliders back.
        let rendered = edit.renderSettings()
        if edit.kind == .cameraRaw { filterSettings = rendered }
        // No distortion to remove: close as Cancel does, without an undo step.
        if (edit.kind == .lensCorrection && edit.settings.distortion == 0)
            || (edit.kind == .exposure && edit.settings.exposure == ExposureSettings())
            || (edit.kind == .grain && edit.settings.grain.amount == 0)
            || (edit.kind == .cameraRaw && rendered.cameraRaw.isIdentity) { cancelFilter(); return }
        edit.committing = true
        edit.previewTask?.cancel()
        edit.whiteBalanceTask?.cancel()
        if edit.kind != .cameraRaw { filterSettings = edit.settings }
        isProjectBusy = true
        // The preview stays up until the result is on the layer, so the canvas never flashes the original.
        defer { filterEdit = nil; isProjectBusy = false; brushRevision += 1 }
        // Remove Background masks the background out rather than erasing it, so it can be brought back at any time
        // by painting the mask, disabling it, or deleting it.
        if edit.kind == .removeBackground { await commitBackgroundMask(edit); return }
        var job = FilterJob(kind: edit.kind, image: edit.grownImage ?? edit.original.image, settings: edit.renderSettings(), scale: 1,
                            selection: edit.selection, mapping: edit.mapping, seed: edit.seed)
        let cached = edit.kind.isAutomatic && edit.preparedSettings == edit.settings ? edit.preparedPreview : nil
        do {
            // A blur raised just before OK may not have its room yet (the preview making it was cancelled above), and
            // Content-Aware Fill may not have its grid.
            if let extent = edit.pendingExtent {
                let kind = edit.kind, original = edit.original, transform = edit.transform, forArea = edit.pendingArea != nil
                let made: GrownGrid?
                do { made = try await PixelAdjust.detached({ try FilterEdit.grown(kind: kind, original: original, transform: transform, to: extent) }) }
                catch where !forArea {
                    // Past the size limit a blur stays in the grid it has, as its preview did and said.
                    adjustmentLog.notice("\(kind.rawValue, privacy: .public) applied without more room: \(error.localizedDescription, privacy: .public)")
                    made = nil
                }
                if let grid = made {
                    edit.adopt(grid)
                    job.image = grid.image; job.mapping = grid.mapping
                }
            }
            let grown = edit.grownTransform
            let spreads = edit.kind == .gaussianBlur || edit.kind == .motionBlur
            let made = try await Task.detached(priority: .userInitiated) { [job] () -> (asset: ImportedImage, transform: LayerTransform?) in
                var image = try cached ?? PixelFilter.run(job)
                var placed = grown
                if spreads, let grown {
                    let trimmed = try PixelFilter.trimmed(image, placed: grown)
                    image = trimmed.image
                    placed = trimmed.transform
                }
                return (ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: job.kind.rawValue), placed)
            }.value
            let asset = made.asset
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let current = document?.layers[index], current.asset?.image === edit.original.image,
                  current.transform == edit.transform else { reportDroppedApply(edit.kind.rawValue); return }
            // A grown layer's mask (covering the old grid) is carried onto the new one, its edge tone past the old edge.
            // It goes where the pixels went: a blur's grid is trimmed again, and the mask has the trimmed grid's size.
            var mask = current.mask
            if let placed = made.transform, let owned = current.mask, owned.placement == nil,
               owned.asset.image.width > 1 || owned.asset.image.height > 1 {
                var enabled = owned
                enabled.isEnabled = true
                guard let carried = enabled.clipImage(placement: current.transform, over: placed,
                                                      width: asset.image.width, height: asset.image.height) else { throw ExportError.render }
                mask = owned.replacing(try LayerMask.asset(from: carried))
            }
            beginEdit(edit.kind.rawValue)
            document?.layers[index] = current.replacingPixels(asset, transform: made.transform, mask: mask)
            endEdit()
        } catch { brushError = error.localizedDescription }
    }

    /// Remove Background as a layer mask: the subject stays white, the background black. A mask already on the layer
    /// (in the layer's own grid) is kept, hiding whatever either one hides; with a selection, only the selected part
    /// of the mask changes.
    private func commitBackgroundMask(_ edit: FilterEdit) async {
        let source = edit.original.image
        let current = document?.layers.first(where: { $0.id == edit.layerID })
        let existing = current?.mask.flatMap { owned in
            owned.placement == nil && owned.asset.image.width == source.width && owned.asset.image.height == source.height
                ? owned.asset.image : nil
        }
        let selection = edit.selection, mapping = edit.mapping, settings = edit.settings.normalized
        do {
            let made = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                var mask = try SubjectRemoval.subjectMask(source, under: existing, settings: settings)
                if let selection, let base = existing {
                    mask = try PixelAdjust.blend(mask, over: base, through: selection, pixelToDocument: mapping, isMask: true)
                } else if let selection {
                    let white = try BrushRaster.context(width: source.width, height: source.height, mask: true)
                    white.setFillColor(gray: 1, alpha: 1)
                    white.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
                    guard let opaque = white.makeImage() else { throw ExportError.render }
                    mask = try PixelAdjust.blend(mask, over: opaque, through: selection, pixelToDocument: mapping, isMask: true)
                }
                return mask
            }.value
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let layer = document?.layers[index], layer.asset?.image === edit.original.image,
                  layer.transform == edit.transform else { reportDroppedApply(edit.kind.rawValue); return }
            let asset = try LayerMask.asset(from: made)
            beginEdit(edit.kind.rawValue)
            document?.layers[index].mask = layer.mask.map { $0.replacing(asset) } ?? LayerMask(asset: asset)
            document?.layers[index].mask?.isEnabled = true
            isMaskSelected = true
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
}

let adjustmentLog = Logger.compositor("Adjustments")

extension EditorSession {
    /// OK finished after its layer changed underneath it (deleted, or its pixels or placement replaced), so the result
    /// would land on the wrong pixels. Dropping it is right; dropping it without a word left the user thinking it applied.
    func reportDroppedApply(_ name: String) {
        adjustmentLog.notice("\(name, privacy: .public) finished after its layer changed; the result was discarded")
        brushError = "\(name) wasn’t applied: the layer changed while it was being made."
    }
}
