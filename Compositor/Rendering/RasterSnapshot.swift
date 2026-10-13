import AppKit
import os

/// Immutable sparse raster. Paint commits share untouched tiles with their source.
/// A contiguous CGImage backing is materialized only when a consumer (export or an
/// image-processing operation) actually requests its bytes, never on mouse-up.
/// Unchecked because of that lazy backing: every stored property is a `let` of an immutable value except
/// `materialized` and `materializeFailed`, which are only read or written with `lock` held; the context's pixels are
/// drawn once, under the lock, and only read after that.
nonisolated final class RasterSnapshot: @unchecked Sendable {
    let width: Int
    let height: Int
    let base: CGImage?
    let baseRect: CGRect
    let patches: [BrushPatch]
    let isMask: Bool
    /// Where this raster's halving grids start (see `TiledLayerRenderer`): its base's origin, or for a raster
    /// painted from nothing, the grid of the stroke that made it — carried across commits so they never shift.
    let alignment: CGPoint
    private var bytesPerPixel: Int { isMask ? 1 : 4 }
    private let lock = NSLock()
    private var materialized: CGContext?
    /// Set once making the contiguous pixels has failed and been logged, so a draw retried every frame logs once.
    private var materializeFailed = false
    private static let log = Logger.compositor("Rendering")

    init(width: Int, height: Int, base: CGImage?, baseRect: CGRect, patches: [BrushPatch], isMask: Bool = false, alignment: CGPoint? = nil) {
        self.width = width
        self.height = height
        self.base = base
        self.baseRect = baseRect
        self.patches = patches
        self.isMask = isMask
        self.alignment = alignment ?? baseRect.origin
    }

    /// New patches are complete replacement tiles, including transparent pixels.
    /// Split older patches at their edges to keep the display list disjoint and flat.
    static func replacing(source: ImportedImage?, sourceRect: CGRect, patches new: [BrushPatch], crop: CGRect, isMask: Bool = false) -> RasterSnapshot {
        let old = source?.raster
        let dx = sourceRect.minX - crop.minX, dy = sourceRect.minY - crop.minY
        var patches = (old?.patches ?? []).map {
            BrushPatch(rect: $0.rect.offsetBy(dx: dx, dy: dy), image: $0.image)
        }
        let additions = new.map { BrushPatch(rect: $0.rect.offsetBy(dx: -crop.minX, dy: -crop.minY), image: $0.image) }
        // Spatial indexing keeps the handoff proportional to touched tiles, rather
        // than comparing every old tile with every new tile on a large document.
        func cells(_ rect: CGRect) -> [SIMD2<Int>] {
            guard !rect.isEmpty else { return [] }
            var result: [SIMD2<Int>] = []
            for y in Int(floor(rect.minY / 256))...Int(ceil(rect.maxY / 256) - 1) {
                for x in Int(floor(rect.minX / 256))...Int(ceil(rect.maxX / 256) - 1) { result.append(SIMD2(x, y)) }
            }
            return result
        }
        var buckets: [SIMD2<Int>: [Int]] = [:]
        for (index, addition) in additions.enumerated() {
            for cell in cells(addition.rect) { buckets[cell, default: []].append(index) }
        }
        patches = patches.flatMap { patch -> [BrushPatch] in
            let candidates = Set(cells(patch.rect).flatMap { buckets[$0] ?? [] })
            var pieces = [patch]
            for index in candidates {
                let addition = additions[index]
                pieces = pieces.flatMap { piece -> [BrushPatch] in
                    let overlap = piece.rect.intersection(addition.rect)
                    guard !overlap.isNull, !overlap.isEmpty else { return [piece] }
                    let r = piece.rect
                    let rects = [CGRect(x: r.minX, y: r.minY, width: r.width, height: overlap.minY - r.minY),
                        CGRect(x: r.minX, y: overlap.maxY, width: r.width, height: r.maxY - overlap.maxY),
                        CGRect(x: r.minX, y: overlap.minY, width: overlap.minX - r.minX, height: overlap.height),
                        CGRect(x: overlap.maxX, y: overlap.minY, width: r.maxX - overlap.maxX, height: overlap.height)]
                    return rects.compactMap { rect in
                        guard rect.width > 0, rect.height > 0,
                              let image = piece.image.cropping(to: rect.offsetBy(dx: -r.minX, dy: -r.minY)) else { return nil }
                        return BrushPatch(rect: rect, image: image)
                    }
                }
            }
            return pieces
        }
        patches += additions
        let bounds = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
        patches = patches.compactMap { patch in
            let rect = patch.rect.intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            if rect == patch.rect { return patch }
            guard let image = patch.image.cropping(to: rect.offsetBy(dx: -patch.rect.minX, dy: -patch.rect.minY)) else { return nil }
            return BrushPatch(rect: rect, image: image)
        }
        return RasterSnapshot(width: Int(crop.width), height: Int(crop.height), base: old?.base ?? (old == nil ? source?.image : nil),
            baseRect: old?.baseRect.offsetBy(dx: dx, dy: dy) ?? sourceRect.offsetBy(dx: -crop.minX, dy: -crop.minY), patches: patches, isMask: isMask,
            alignment: CGPoint(x: sourceRect.minX + (old?.alignment.x ?? 0) - crop.minX, y: sourceRect.minY + (old?.alignment.y ?? 0) - crop.minY))
    }

    /// Draw only the requested source pixels, used when allocating a brush tile.
    func draw(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setShouldAntialias(false)
        if isMask {
            // A mask expansion reveals new pixels outside its original extent.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(rect)
        }
        let sx = rect.width / CGFloat(width), sy = rect.height / CGFloat(height)
        func mapped(_ r: CGRect) -> CGRect {
            CGRect(x: rect.minX + r.minX * sx, y: rect.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
        }
        let visible = context.boundingBoxOfClipPath
        if let base {
            let target = mapped(baseRect)
            let overlap = target.intersection(visible)
            if !overlap.isNull, !overlap.isEmpty {
                let crop = CGRect(x: (overlap.minX - target.minX) / target.width * CGFloat(base.width),
                    y: (overlap.minY - target.minY) / target.height * CGFloat(base.height),
                    width: overlap.width / target.width * CGFloat(base.width), height: overlap.height / target.height * CGFloat(base.height)).integral
                if let image = base.cropping(to: crop) {
                    let destination = CGRect(x: target.minX + crop.minX / CGFloat(base.width) * target.width,
                        y: target.minY + crop.minY / CGFloat(base.height) * target.height,
                        width: crop.width / CGFloat(base.width) * target.width, height: crop.height / CGFloat(base.height) * target.height)
                    BrushRaster.draw(image, in: destination, mask: isMask, context: context)
                }
            }
        }
        for patch in patches where mapped(patch.rect).intersects(visible) {
            BrushRaster.draw(patch.image, in: mapped(patch.rect), mask: isMask, context: context)
        }
        context.restoreGState()
    }

    func makeImage() throws -> CGImage {
        let info = Unmanaged.passRetained(self).toOpaque()
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: { info in
            guard let info else { return nil }
            return Unmanaged<RasterSnapshot>.fromOpaque(info).takeUnretainedValue().bytes().map(UnsafeRawPointer.init)
        }, releaseBytePointer: { _, _ in }, getBytesAtPosition: { info, buffer, position, count in
            guard let info else { return 0 }
            let raster = Unmanaged<RasterSnapshot>.fromOpaque(info).takeUnretainedValue()
            let offset = Int(position), total = raster.width * raster.height * raster.bytesPerPixel
            guard offset >= 0, offset < total, let bytes = raster.bytes() else { return 0 }
            let length = min(count, total - offset)
            memcpy(buffer, bytes.advanced(by: offset), length)
            return length
        }, releaseInfo: { info in
            if let info { Unmanaged<RasterSnapshot>.fromOpaque(info).release() }
        })
        guard let provider = CGDataProvider(directInfo: info, size: off_t(width * height * bytesPerPixel), callbacks: &callbacks) else {
            Unmanaged<RasterSnapshot>.fromOpaque(info).release()
            throw ExportError.render
        }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * bytesPerPixel, bytesPerRow: width * bytesPerPixel,
            space: isMask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: isMask ? CGImageAlphaInfo.none.rawValue : (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ExportError.render }
        return image
    }

    var hasMaterializedPixels: Bool {
        lock.lock()
        defer { lock.unlock() }
        return materialized != nil
    }

    /// Makes the contiguous pixels now, throwing if they can't be made. Core Graphics asks for them through the
    /// image's data provider, which has no way to report a failure: the image just draws as nothing. Export and save
    /// call this first so that shows up as an error instead of a blank layer.
    func materialize() throws {
        guard bytes() != nil else { throw ExportError.render }
    }

    private func bytes() -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        if let materialized { return materialized.data }
        let context: CGContext
        do { context = try BrushRaster.context(width: width, height: height, mask: isMask) } catch {
            if !materializeFailed {
                materializeFailed = true
                Self.log.error("A painted \(self.width)×\(self.height) layer's pixels could not be made, so it draws as nothing: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
        draw(in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        materialized = context
        return context.data
    }

    /// The raster reduced to `width` × `height` without making its contiguous pixels: a block at a time is composed
    /// at full resolution from the base and tiles, with a margin for the resampling to reach into, and drawn reduced
    /// into its part of the result. Asking the whole image for its bytes would keep a full-size copy for as long as
    /// the snapshot lives, which is what the tiles are there to avoid.
    func reduced(width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else { throw ExportError.render }
        let output = try BrushRaster.context(width: width, height: height, mask: isMask)
        output.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = CGFloat(width) / CGFloat(self.width), scaleY = CGFloat(height) / CGFloat(self.height)
        // Room for the filter's reach past each block edge, in source pixels: eight output pixels.
        let marginX = Int(ceil(8 / min(1, scaleX))) + 2, marginY = Int(ceil(8 / min(1, scaleY))) + 2
        // Blocks of about 2048 source pixels a side, so one never holds much more than 16 MB.
        let stepX = max(16, Int(2048 * scaleX)), stepY = max(16, Int(2048 * scaleY))
        // Blocks start on a multiple of 64 source pixels, so the reductions Core Graphics makes of each on the way
        // down line up with those it would make of the whole image.
        func start(_ output: Int, scale: CGFloat, margin: Int) -> Int {
            max(0, (Int(floor(CGFloat(output) / scale)) - margin) / 64 * 64)
        }
        for y in stride(from: 0, to: height, by: stepY) {
            let rows = min(stepY, height - y)
            let top = start(y, scale: scaleY, margin: marginY)
            let bottom = min(self.height, Int(ceil(CGFloat(y + rows) / scaleY)) + marginY)
            for x in stride(from: 0, to: width, by: stepX) {
                let columns = min(stepX, width - x)
                let left = start(x, scale: scaleX, margin: marginX)
                let right = min(self.width, Int(ceil(CGFloat(x + columns) / scaleX)) + marginX)
                guard right > left, bottom > top else { continue }
                let block = try BrushRaster.context(width: right - left, height: bottom - top, mask: isMask)
                block.clear(CGRect(x: 0, y: 0, width: right - left, height: bottom - top))
                block.translateBy(x: -CGFloat(left), y: -CGFloat(top))
                draw(in: CGRect(x: 0, y: 0, width: self.width, height: self.height), context: block)
                guard let image = block.makeImage() else { throw ExportError.render }
                output.saveGState()
                output.setShouldAntialias(false)
                output.clip(to: CGRect(x: x, y: y, width: columns, height: rows))
                output.interpolationQuality = .high
                let target = CGRect(x: CGFloat(left) * scaleX, y: CGFloat(top) * scaleY,
                                    width: CGFloat(right - left) * scaleX, height: CGFloat(bottom - top) * scaleY)
                output.translateBy(x: target.minX, y: target.maxY)
                output.scaleBy(x: 1, y: -1)
                output.setBlendMode(.copy)
                output.draw(image, in: CGRect(origin: .zero, size: target.size))
                output.restoreGState()
            }
        }
        guard let result = output.makeImage() else { throw ExportError.render }
        return result
    }

    func thumbnail() throws -> CGImage {
        let factor = min(1, 96 / CGFloat(max(width, height)))
        let w = max(1, Int(CGFloat(width) * factor)), h = max(1, Int(CGFloat(height) * factor))
        let context = try BrushRaster.context(width: w, height: h, mask: isMask)
        draw(in: CGRect(x: 0, y: 0, width: w, height: h), context: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}
