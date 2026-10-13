import AppKit

/// Turns raster coverage into a selection outline along exact pixel edges. Thresholding and tracing run in C
/// (`WandPixels.c`, shared with the Magic Wand), in time linear in the pixels.
nonisolated enum MaskTracing {
    /// Outline of a mask's pixels darker than 50% gray.
    static func darkPixels(in image: CGImage) throws -> CGPath? { try trace(image, alpha: false, below: true) }

    /// Outline of a mask's pixels lighter than 50% gray — what a mask shows.
    static func whitePixels(in image: CGImage) throws -> CGPath? { try trace(image, alpha: false, below: false) }

    /// Outline of an image's pixels that are at least 50% opaque.
    static func opaquePixels(in image: CGImage) throws -> CGPath? { try trace(image, alpha: true, below: false) }

    /// Outline, in the image's top-left pixel coordinates, of pixels whose gray value (or alpha) is below 128 or,
    /// not `below`, at least 128. Outer boundaries run clockwise and holes counterclockwise, so the winding fill
    /// rule reproduces exactly the traced pixels. Nil when none pass.
    private static func trace(_ image: CGImage, alpha: Bool, below: Bool) throws -> CGPath? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        // Alpha is read from RGBA pixels (the 4th byte); gray from a one-byte gray bitmap.
        let channels = alpha ? 4 : 1
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * channels,
                                      space: alpha ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                                                        : CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw MagicWand.Failure.memory }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var mask = [UInt8](repeating: 0, count: width * height)
        let count = mask.withUnsafeMutableBufferPointer {
            wand_threshold(data.assumingMemoryBound(to: UInt8.self) + (channels - 1), width, height, context.bytesPerRow,
                           channels, 128, below ? 1 : 0, $0.baseAddress)
        }
        guard count > 0 else { return nil }
        return try MagicWand.outline(of: mask, width: width, height: height)
    }
}

extension EditorSession {
    /// Cmd-click on a mask thumbnail: the mask's black (hidden) areas become the
    /// selection. Shift adds to the current selection; Option subtracts from it.
    func loadMaskSelection(layerID: UUID, mode: SelectionMode = .replace) async {
        guard canEditSelection, !isProjectBusy, let layer = document?.layers.first(where: { $0.id == layerID }),
              let mask = layer.mask?.asset.image else { return }
        await loadTracedSelection(layerID: layerID, image: mask, placement: layer.maskTransform, mode: mode,
                                  name: "Load Mask Selection", stillCurrent: { $0.mask?.asset.image === mask && $0.maskTransform == layer.maskTransform },
                                  trace: MaskTracing.darkPixels)
    }

    /// Cmd-click on a layer thumbnail: the layer's visible (≥ 50% opaque) pixels become
    /// the selection, ignoring its mask, as in Photoshop. Shift adds; Option subtracts.
    func loadLayerSelection(layerID: UUID, mode: SelectionMode = .replace) async {
        guard canEditSelection, !isProjectBusy, let layer = document?.layers.first(where: { $0.id == layerID }), !layer.isGroup,
              let image = layer.asset?.image else { NSSound.beep(); return }
        await loadTracedSelection(layerID: layerID, image: image, placement: layer.transform, mode: mode,
                                  name: "Load Layer Selection", stillCurrent: { $0.asset?.image === image && $0.transform == layer.transform },
                                  trace: MaskTracing.opaquePixels)
    }

    /// Traces `image` off the main thread — a whole layer or mask, which can take a while — and applies the outline,
    /// placed at `placement`, unless the layer changed meanwhile.
    private func loadTracedSelection(layerID: UUID, image: CGImage, placement: LayerTransform, mode: SelectionMode, name: String,
                                     stillCurrent: (ImageLayer) -> Bool,
                                     trace: @escaping @Sendable (CGImage) throws -> CGPath?) async {
        let held = TraceInput(image: image)
        isProjectBusy = true
        let result = await Task.detached(priority: .userInitiated) { () -> TraceOutput in
            do { return TraceOutput(path: try trace(held.image), error: nil) }
            catch { return TraceOutput(path: nil, error: error) }
        }.value
        isProjectBusy = false
        guard let layer = document?.layers.first(where: { $0.id == layerID }), stillCurrent(layer) else {
            ToolLog.staleResult(name)
            return
        }
        if let error = result.error { brushError = error.localizedDescription; return }
        guard let traced = result.path else { NSSound.beep(); return }
        var toDocument = BrushRaster.pixelToDocument(placement, width: image.width, height: image.height)
        guard let outline = traced.copy(using: &toDocument) else { return }
        applySelection(outline, mode: mode, name: name)
    }
}

private nonisolated struct TraceInput: Sendable {
    let image: CGImage
}

/// Unchecked only because CGPath isn't marked Sendable: the path is made by the trace and never mutated afterwards.
private nonisolated struct TraceOutput: @unchecked Sendable {
    let path: CGPath?
    let error: Error?
}
