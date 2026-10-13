import AppKit

nonisolated enum ContentFill {
    enum Failure: LocalizedError {
        case noSource
        var errorDescription: String? { "Not enough unselected, opaque image pixels to synthesize a fill. Use a smaller selection with some surrounding image." }
    }
    /// The least image (layer pixels) around the selection the fill samples from. Wider selections get a ring as wide as
    /// their longer side, so a hole always has at least its own size of surroundings to copy from.
    static let samplingMargin = 64

    static func run(_ job: FilterJob) throws -> CGImage {
        guard let selection = job.selection else { throw Failure.noSource }
        let w=job.image.width, h=job.image.height
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let selected = selection.rect.applying(job.mapping.inverted()).integral.intersection(full)
        guard !selected.isNull, !selected.isEmpty else { return job.image }
        let margin = CGFloat(max(samplingMargin, Int(max(selected.width, selected.height))))
        let region = selected.insetBy(dx: -margin, dy: -margin).intersection(full)
        let pixels = try BrushRaster.context(width: w, height: h, mask: false)
        BrushRaster.draw(job.image, in: full, mask: false, context: pixels)
        // Only the selection and the image around it take part: the kernel's working memory (16 bytes a pixel) and
        // its scans covered the whole layer, however small the selection. Should that ring hold nothing to copy, the
        // whole layer is searched as before; the kernel leaves the pixels alone when it finds no source.
        var result = try fill(pixels, region: region, job: job, selection: selection)
        if result == 0 && region != full { result = try fill(pixels, region: full, job: job, selection: selection) }
        guard result != 0 else { throw Failure.noSource }
        guard result == 1, let image = pixels.makeImage() else { throw ExportError.render }
        return image
    }

    /// Runs the kernel on `region` (layer pixels) of `pixels` as if it were an image of its own.
    private static func fill(_ pixels: CGContext, region: CGRect, job: FilterJob, selection: SelectionClip) throws -> Int32 {
        let mask = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: true)
        mask.saveGState()
        mask.translateBy(x: -region.minX, y: -region.minY)
        mask.concatenate(job.mapping.inverted())
        selection.apply(to: mask)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: job.image.width, height: job.image.height).applying(job.mapping))
        mask.restoreGState()
        guard let data = pixels.data, let coverage = mask.data else { throw ExportError.render }
        // The region's own rows: its top-left pixel, then the full image's stride.
        let corner = data.assumingMemoryBound(to: UInt8.self) + Int(region.minY) * pixels.bytesPerRow + Int(region.minX) * 4
        return content_fill(corner, pixels.bytesPerRow, coverage.assumingMemoryBound(to: UInt8.self), mask.bytesPerRow,
                            Int32(region.width), Int32(region.height))
    }
}
