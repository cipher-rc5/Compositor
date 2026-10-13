import Accelerate
import CoreGraphics
import Foundation
import Synchronization

/// Sharp reductions of layer images. Core Graphics resamples in one step with a filter that only looks at a
/// few neighbouring pixels, so shrinking an image 4× or 8× comes out soft or grainy at any interpolation
/// quality. This keeps a chain of halved copies made with Lanczos resampling (vImage), so a draw only ever
/// leaves Core Graphics the last reduction of at most 2×. Copies are keyed by image identity — painting makes
/// a new image — and the least recently used are dropped beyond a pixel budget.
///
/// Every halving is exactly 2×, so level `k` pixel `i` always covers source pixels `i·2^k ..< (i+1)·2^k`: a
/// piece of an image reduced on its own lines up with the whole image reduced (see `TiledLayerRenderer`).
///
/// Unchecked because `entries`, `clock` and `building` are mutable: they are only read or written with `lock` held,
/// which is never held while an image is halved.
nonisolated final class DownsampleCache: @unchecked Sendable {
    static let shared = DownsampleCache()
    /// Pixels kept at once, counting the full-size image each entry holds on to as well as its halved copies (about
    /// 600 MB of RGBA): room for the largest layer a document can have, 100 MP, with its halvings.
    static let defaultPixelBudget = 150_000_000
    let pixelBudget: Int
    init(pixelBudget: Int = DownsampleCache.defaultPixelBudget) { self.pixelBudget = pixelBudget }
    /// Most halvings ever used; past this Core Graphics does the rest.
    static let maxLevel = 6

    private struct Entry {
        let source: CGImage
        var levels: [CGImage]
        var lastUse: UInt64
        /// The source counts too: the entry keeps it alive, even after the document has let it go.
        var pixels: Int { levels.reduce(source.width * source.height) { $0 + $1.width * $1.height } }
    }
    private struct BuildKey: Hashable {
        let image: ObjectIdentifier
        let level: Int
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var clock: UInt64 = 0
    /// What the kept entries hold, as `Entry.pixels` counts it.
    var retainedPixels: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.pixels }
    }
    /// Whether halvings of `image` are kept.
    func holds(_ image: CGImage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[ObjectIdentifier(image)]?.source === image
    }
    /// Images whose halvings are being made on the builder, so a miss drawn again doesn't queue them twice.
    private var building: Set<ObjectIdentifier> = []
    private let lock = NSLock()

    /// Halvings to draw from when an image lands `factor` output pixels per image pixel: the most that still
    /// leave the copy at least that large (0 from half size up).
    static func level(for factor: CGFloat) -> Int {
        guard factor.isFinite, factor > 0, factor < 0.5 else { return 0 }
        return min(maxLevel, Int(floor(log2(1 / Double(factor)))))
    }

    /// What to draw when `image` lands `factor` output pixels per image pixel.
    func image(_ image: CGImage, drawnAt factor: CGFloat) -> CGImage {
        self.image(image, level: Self.level(for: factor)).image
    }

    /// `image` reduced by `level` halvings, and how many were applied (fewer only if one failed, or while
    /// `CacheMissDeferral` is building the rest). Each halving rounds up, so the copy reaches up to 2^level − 1
    /// source pixels past the right and bottom.
    func image(_ image: CGImage, level wanted: Int) -> (image: CGImage, level: Int) {
        guard wanted >= 1, image.width > 1 || image.height > 1 else { return (image, 0) }
        var levels = cached(image)
        if levels.count < wanted, let deferral = CacheMissDeferral.current {
            buildLater(image, level: wanted, then: deferral)
        } else {
            levels = extend(image, levels, to: wanted)
        }
        guard !levels.isEmpty else { return (image, 0) }
        let applied = min(wanted, levels.count)
        return (levels[applied - 1], applied)
    }

    /// The halvings already made for `image`, marked as just used.
    private func cached(_ image: CGImage) -> [CGImage] {
        let key = ObjectIdentifier(image)
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        guard let entry = entries[key], entry.source === image else { return [] }
        entries[key]?.lastUse = clock
        return entry.levels
    }

    /// `levels` halved on down to `wanted`, and kept.
    private func extend(_ image: CGImage, _ levels: [CGImage], to wanted: Int) -> [CGImage] {
        var levels = levels
        let before = levels.count
        while levels.count < wanted {
            let previous = levels.last ?? image
            guard previous.width > 1 || previous.height > 1, let next = Self.halve(previous) else { break }
            levels.append(next)
        }
        guard levels.count > before else { return levels }
        let key = ObjectIdentifier(image)
        lock.lock()
        if let stored = entries[key], stored.source === image, stored.levels.count >= levels.count {
            entries[key]?.lastUse = clock
        } else {
            entries[key] = Entry(source: image, levels: levels, lastUse: clock)
        }
        evict(keeping: key)
        lock.unlock()
        return levels
    }

    private func buildLater(_ image: CGImage, level wanted: Int, then deferral: CacheMissDeferral) {
        let key = ObjectIdentifier(image)
        lock.lock()
        let fresh = building.insert(key).inserted
        lock.unlock()
        guard fresh else { return }
        // The image is held until the build ends, so its identifier can't be reused for another meanwhile.
        CacheMissDeferral.builder.async { [self] in
            _ = extend(image, cached(image), to: wanted)
            lock.lock()
            building.remove(key)
            lock.unlock()
            // By level as well, so zooming further out isn't taken for the same build again.
            deferral.finished(BuildKey(image: key, level: wanted))
        }
    }

    /// Drops least recently used copies until the rest fit the budget, the one just made last of all — and that one
    /// too when it alone is over the budget: its caller still draws with what it was handed, but keeping it would
    /// hold memory past the budget for good. Call with the lock held.
    private func evict(keeping key: ObjectIdentifier) {
        var total = entries.values.reduce(0) { $0 + $1.pixels }
        while total > pixelBudget,
              let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse })
                ?? entries.first(where: { $0.key == key }) {
            total -= oldest.value.pixels
            entries.removeValue(forKey: oldest.key)
        }
    }

    /// Exactly half the size, rounded up, with Lanczos resampling. Color images are padded with transparent
    /// pixels first, so edges fade out the same way wherever the image is cut; ringing past a pixel's alpha is
    /// clamped so edges don't glow. Gray masks repeat an odd last row or column instead.
    static func halve(_ image: CGImage) -> CGImage? {
        let mask = image.colorSpace?.model == .monochrome && image.alphaInfo == .none
        let width = (image.width + 1) / 2, height = (image.height + 1) / 2
        let pad = mask ? 0 : 8
        let paddedWidth = width * 2 + pad * 2, paddedHeight = height * 2 + pad * 2
        guard let source = try? BrushRaster.context(width: paddedWidth, height: paddedHeight, mask: mask),
              let destination = try? BrushRaster.context(width: paddedWidth / 2, height: paddedHeight / 2, mask: mask) else { return nil }
        source.clear(CGRect(x: 0, y: 0, width: paddedWidth, height: paddedHeight))
        let placed = CGRect(x: pad, y: pad, width: image.width, height: image.height)
        BrushRaster.draw(image, in: placed, mask: mask, context: source)
        if mask {
            if paddedWidth > image.width, let column = image.cropping(to: CGRect(x: image.width - 1, y: 0, width: 1, height: image.height)) {
                BrushRaster.draw(column, in: CGRect(x: image.width, y: 0, width: 1, height: image.height), mask: true, context: source)
            }
            if paddedHeight > image.height, let row = source.makeImage()?.cropping(to: CGRect(x: 0, y: image.height - 1, width: paddedWidth, height: 1)) {
                BrushRaster.draw(row, in: CGRect(x: 0, y: image.height, width: paddedWidth, height: 1), mask: true, context: source)
            }
        }
        guard let from = source.data, let into = destination.data else { return nil }
        var input = vImage_Buffer(data: from, height: vImagePixelCount(paddedHeight), width: vImagePixelCount(paddedWidth),
                                  rowBytes: source.bytesPerRow)
        var output = vImage_Buffer(data: into, height: vImagePixelCount(paddedHeight / 2), width: vImagePixelCount(paddedWidth / 2),
                                   rowBytes: destination.bytesPerRow)
        let flags = vImage_Flags(kvImageHighQualityResampling)
        let error = mask ? vImageScale_Planar8(&input, &output, nil, flags) : vImageScale_ARGB8888(&input, &output, nil, flags)
        guard error == kvImageNoError else { return nil }
        if !mask { rgba_clamp_premultiplied(into.assumingMemoryBound(to: UInt8.self), (paddedWidth / 2) * (paddedHeight / 2)) }
        guard let halved = destination.makeImage() else { return nil }
        return mask ? halved : halved.cropping(to: CGRect(x: pad / 2, y: pad / 2, width: width, height: height))
    }
}

/// Set around a live canvas draw. A sharp reduction (`DownsampleCache`) or a painted layer's pieces
/// (`TiledPieceCache`) that isn't made yet is built on a worker instead of in the draw, which makes do with what
/// there is — a lighter reduction, or the image left to Core Graphics — and `ready` asks for another draw once it
/// lands. Export and other one-off renders leave it unset, and get every pixel exact.
nonisolated struct CacheMissDeferral: Sendable {
    let ready: @Sendable () -> Void
    @TaskLocal static var current: CacheMissDeferral?
    /// One build at a time, so a page of misses doesn't take every core from the app.
    static let builder = DispatchQueue(label: "com.compositor.draw-cache", qos: .userInitiated)

    /// Called as a build ends: asks for the redraw that shows it — unless the same thing was built only moments
    /// ago. Then the caches are over budget and evicting each other's work, and a redraw would only start the next
    /// eviction; what is drawn meanwhile stays until something else redraws.
    func finished(_ key: some Hashable & Sendable) {
        if !Self.recent.isRepeat(key) { ready() }
    }
    private static let recent = RecentBuilds()
    nonisolated private final class RecentBuilds: Sendable {
        private let times = Mutex<[AnyHashable: ContinuousClock.Instant]>([:])
        func isRepeat(_ key: some Hashable & Sendable) -> Bool {
            let now = ContinuousClock.now
            return times.withLock { times in
                let key = AnyHashable(key)
                let previous = times[key]
                times[key] = now
                if times.count > 256 { times = times.filter { now - $0.value < .seconds(2) } }
                return previous.map { now - $0 < .seconds(2) } ?? false
            }
        }
    }
}
