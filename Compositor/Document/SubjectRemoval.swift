import AppKit
import Vision
import CoreImage
import Synchronization

nonisolated enum SubjectRemoval {
    enum Failure: LocalizedError {
        case noSubject
        var errorDescription: String? { "No foreground subject was detected in this layer. Try an image with a more distinct subject." }
    }
    /// Vision's own mask for an image, kept while the Remove Background panel is open so moving a slider only redoes
    /// the refining. It holds a full image and its mask, so it is let go when the panel closes (`forgetMask`).
    static let cache = MaskCache()
    final class MaskCache: Sendable {
        private struct State {
            /// The image the mask was made for, held so its address can't be reused by another image while cached.
            var key: CGImage?
            var value: CGImage?
            /// Moves on with every `forget`, so a mask still being made when the panel closed isn't kept after it.
            var generation = 0
        }
        private let state = Mutex(State())
        func mask(for image: CGImage, make: () throws -> CGImage) throws -> CGImage {
            let (hit, started) = state.withLock { ($0.key === image ? $0.value : nil, $0.generation) }
            if let hit { return hit }
            let made = try make()
            state.withLock { if $0.generation == started { $0.key = image; $0.value = made } }
            return made
        }
        func forget() {
            state.withLock {
                $0.key = nil
                $0.value = nil
                $0.generation += 1
            }
        }
        var isEmpty: Bool { state.withLock { $0.key == nil && $0.value == nil } }
    }

    /// Lets go of the cached mask and the image it was made for (see `cache`).
    static func forgetMask() { cache.forget() }

    /// Vision's raw subject mask, white over the subject: the model has no settings of its own, so everything the
    /// panel offers is done to this afterwards by `refined`. Cached only for the panel (`caching`).
    private static func vision(_ image: CGImage, caching: Bool = true) throws -> CGImage {
        func make() throws -> CGImage {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { throw Failure.noSubject }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return try PixelAdjust.render(CIImage(cvPixelBuffer: buffer), width: image.width, height: image.height, isMask: true)
        }
        return caching ? try cache.mask(for: image, make: make) : try make()
    }

    /// The panel's three controls, in the order they help:
    /// - Refine pulls the mask onto the image's own edges (a guided filter with the layer as its guide), which is
    ///   what recovers hair and fur the model cuts straight through.
    /// - Contrast pushes the mask's grays apart, clearing the haze that leaves background showing through.
    /// - Shift Edge grows or shrinks the mask, usually inwards, to drop the rim of background color around a cutout.
    private static func refined(_ mask: CGImage, guide: CGImage, settings: FilterSettings, limit: CGFloat) throws -> CGImage {
        // Basic is Apple's mask as it comes, which is quick; everything below is Advanced.
        guard settings.backgroundQuality == .advanced else { return mask }
        var image = CIImage(cgImage: mask)
        let extent = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        if settings.refineEdges > 0 {
            image = CIImage(cgImage: try GuidedMatte.refine(mask: mask, guide: guide,
                                                            radius: settings.refineEdges, limit: limit))
        }
        if settings.shiftEdge != 0 {
            // A blur then a hard threshold at the matching level moves the edge by the blur's reach.
            let reach = abs(settings.shiftEdge)
            image = image.clampedToExtent().applyingGaussianBlur(sigma: reach / 2).cropped(to: extent)
            let level = settings.shiftEdge < 0 ? 0.75 : 0.25
            image = image.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: level, y: level, z: level, w: 0),
                "inputMaxComponents": CIVector(x: level + 0.001, y: level + 0.001, z: level + 0.001, w: 1),
            ])
            let scale = 1 / 0.001
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: -level * scale, y: -level * scale, z: -level * scale, w: 0),
            ])
        }
        if settings.matteContrast > 0 {
            // 0 leaves the mask as it is; 100 is a hard cut at the middle.
            let strength = settings.matteContrast / 100
            let slope = 1 / max(0.02, 1 - strength * 0.98)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: slope, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: slope, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: slope, w: 0),
                "inputBiasVector": CIVector(x: (1 - slope) / 2, y: (1 - slope) / 2, z: (1 - slope) / 2, w: 0),
            ])
        }
        return try PixelAdjust.render(image.cropped(to: extent), width: mask.width, height: mask.height, isMask: true)
    }

    /// Where the subject is: white over it, black over the background, the size of the layer's own pixels — a layer
    /// mask that hides the background instead of erasing it. `under` is the layer's existing mask, kept as well.
    static func subjectMask(_ image: CGImage, under existing: CGImage?, settings: FilterSettings, caching: Bool = true) throws -> CGImage {
        let subject = try refined(vision(image, caching: caching), guide: image, settings: settings, limit: .greatestFiniteMagnitude)
        guard let existing else { return subject }
        // Both masks hide: what either one hides stays hidden.
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        BrushRaster.draw(existing, in: bounds, mask: true, context: context)
        context.setBlendMode(.multiply)
        context.draw(subject, in: bounds)
        guard let combined = context.makeImage() else { throw ExportError.render }
        return combined
    }

    /// The preview: the layer with its background made transparent by the same mask the commit lays down.
    static func run(_ image: CGImage, settings: FilterSettings) throws -> CGImage {
        let source = CIImage(cgImage: image)
        // The preview refines on a copy at most this big, so dragging a slider stays responsive.
        let mask = CIImage(cgImage: try refined(vision(image), guide: image, settings: settings, limit: 1400))
        let output = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent),
            kCIInputMaskImageKey: mask
        ])
        return try PixelAdjust.render(output, width: image.width, height: image.height, isMask: false)
    }
}


extension EditorSession {
    /// Select → Subject: the foreground Vision finds in the canvas as it is shown, outlined as a selection. The
    /// same shape Remove Background masks out, as a selection instead.
    var canSelectSubject: Bool { canEditSelection && document != nil && !isProjectBusy }

    func selectSubject(mode: SelectionMode = .replace) async {
        guard canSelectSubject, let document else { return }
        // Composited, masked and traced off the main thread.
        let composite = liveComposite(document)
        isProjectBusy = true
        let found = await Task.detached(priority: .userInitiated) { () -> Result<TracedOutline, Error> in
            do {
                // A one-off: a composite is never drawn twice the same, so caching it would only pin it.
                let mask = try SubjectRemoval.subjectMask(try composite.render(), under: nil, settings: FilterSettings(), caching: false)
                // White where the subject is, so its outline is the selection.
                return .success(TracedOutline(path: try MaskTracing.whitePixels(in: mask), width: mask.width, height: mask.height))
            } catch { return .failure(error) }
        }.value
        isProjectBusy = false
        guard self.document?.id == document.id else { ToolLog.staleResult("Select Subject"); return }
        switch found {
        case .failure(let error):
            brushError = error.localizedDescription
        case .success(let traced):
            guard let path = traced.path else { NSSound.beep(); return }
            var toDocument = BrushRaster.pixelToDocument(LayerTransform(origin: .zero, size: document.size),
                                                         width: traced.width, height: traced.height)
            guard let outline = path.copy(using: &toDocument) else { return }
            applySelection(outline, mode: mode, name: "Select Subject")
        }
    }
}

/// An outline traced off the main thread, in the pixels of the `width` × `height` image it was traced from.
/// Unchecked only because CGPath isn't marked Sendable: the path is made by the trace and never mutated afterwards.
private nonisolated struct TracedOutline: @unchecked Sendable {
    let path: CGPath?
    let width: Int
    let height: Int
}
