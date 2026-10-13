import AppKit

/// A finished Spot Healing stroke's heal (`HealPixels.c`), taken from the stroke by `BrushStroke.healJob` so the
/// full-resolution work can run off the main thread. Holds only immutable images.
nonisolated struct SpotHealJob: Sendable {
    /// The area worked on, in the stroke's layer pixels: the painted spot and room around it to find texture in.
    let region: CGRect
    /// The layer's original pixels, as a tiled raster or one image placed at `sourceRect`.
    let raster: RasterSnapshot?
    let source: CGImage?
    let sourceRect: CGRect
    /// The stroke's coverage, tile by tile, in layer pixels.
    let coverage: [(rect: CGRect, image: CGImage)]
    let opacity: Float
    let mode: Int32
    let seed: UInt32

    /// The region healed, `region`-sized.
    func run() throws -> CGImage {
        let width = Int(region.width), height = Int(region.height)
        let pixels = try BrushRaster.context(width: width, height: height, mask: false)
        let placed = sourceRect.offsetBy(dx: -region.minX, dy: -region.minY)
        if let raster { raster.draw(in: placed, context: pixels) }
        else if let source { BrushRaster.draw(source, in: placed, mask: false, context: pixels) }
        let painting = try BrushRaster.context(width: width, height: height, mask: true)
        for tile in coverage {
            BrushRaster.draw(tile.image, in: tile.rect.offsetBy(dx: -region.minX, dy: -region.minY), mask: true, context: painting)
        }
        guard let rgba = pixels.data, let gray = painting.data else { throw ExportError.render }
        guard spot_heal(rgba.assumingMemoryBound(to: UInt8.self), pixels.bytesPerRow,
                        gray.assumingMemoryBound(to: UInt8.self), painting.bytesPerRow,
                        width, height, opacity, mode, seed) == 0 else { throw ProjectError.tooLarge }
        guard let healed = pixels.makeImage() else { throw ExportError.render }
        return healed
    }
}

extension EditorSession {
    /// Spot Healing's mouse-up: the heal runs off the main thread while the stroke stays on the canvas and other
    /// edits wait (`isProjectBusy`), then commits as one undo step. The commit checks the layer is still the one
    /// the stroke was painted on (`commitPaintSnapshot`).
    func finishHealing(_ stroke: BrushStroke) async {
        isProjectBusy = true
        defer {
            if brushStroke === stroke { cancelBrush() }
            isProjectBusy = false
        }
        do {
            try stroke.flush()
            if let job = try stroke.healJob() {
                let healed = try await Task.detached(priority: .userInitiated) { try job.run() }.value
                stroke.applyHeal(healed, region: job.region)
            }
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
    }
}
