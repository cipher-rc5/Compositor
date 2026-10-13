import AppKit
import Testing
@testable import Compositor

@MainActor
struct FilterTests {
    @Test func gaussianBlurSoftensAHardEdgeAndSpreadsPastTheLayerEdgeAsOneUndoStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        // Left half opaque white, right half transparent.
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        session.beginFilter(.gaussianBlur)
        #expect(session.filterEdit != nil && !session.canEditLayers)
        session.updateFilter(FilterSettings(radius: 3), preview: true)
        let count = session.history.undoCount
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count + 1)
        #expect(session.filterSettings.radius == 3)
        let result = try #require(session.activeLayer?.asset?.image)
        let pixels = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
            bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        // The blur is not clamped at the layer's edge: the layer is given room, the blur spreads into it and
        // whatever stays empty is cut away again (Filters.swift, `FilterEdit.grown` / `PixelFilter.trimmed`). The
        // 40 x 20 layer, opaque across its full height for its left half, comes out 36 x 36 at (-8, -8). This
        // used to read three fixed columns of a 40-wide result and assert that the border did not fade, from
        // when the blur smeared outwards and stopped at the edge; the test's name said so too.
        let origin = try #require(session.activeLayer?.transform.origin)
        #expect(origin.x < 0 && origin.y < 0, "the layer grew on every side: origin \(origin)")
        // The strongest evidence that the blur left the layer: it was 20 tall and opaque top to bottom, so it
        // could not have grown vertically unless the blur went past the edge and the layer was given room.
        #expect(result.height > 20, "the blur spread past the layer's edge: height \(result.height)")
        #expect(result.width < 40, "and the half that stayed empty was trimmed away: width \(result.width)")
        let middle = (0..<result.width).map { Int(bytes[(result.height / 2 * result.width + $0) * 4 + 3]) }
        // 250 rather than 255: the block's centre is 10 px from its edges, which at this radius leaves it a
        // fraction of a level below full opacity. What would break here is the inside fading, not rounding.
        #expect(try #require(middle.max()) >= 250, "the block's inside is untouched: \(middle.max() ?? -1)")
        #expect(middle.contains { $0 > 20 && $0 < 235 }, "the hard edge is now soft")
        #expect(try #require(middle.last) < 20, "and it fades out on the far side")
    }

    @Test func motionBlurStreaksAlongItsAngleCounterclockwiseFromHorizontal() throws {
        // One opaque white dot in the middle of a transparent image.
        let context = try BrushRaster.context(width: 41, height: 41, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 1, height: 1))
        let dot = try #require(context.makeImage())
        func streak(angle: Double) throws -> (Int, Int) -> Int {
            let settings = FilterSettings(angle: angle, distance: 16)
            let image = try PixelFilter.run(FilterJob(kind: .motionBlur, image: dot, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 41, height: 41, bitsPerComponent: 8, bytesPerRow: 164,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 41, height: 41))
            let bytes = Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 41 * 41 * 4))
            return { x, y in Int(bytes[(y * 41 + x) * 4 + 3]) } // rows top-down
        }
        let horizontal = try streak(angle: 0)
        #expect(horizontal(24, 20) > 0 && horizontal(16, 20) > 0 && horizontal(20, 24) == 0)
        let vertical = try streak(angle: 90)
        #expect(vertical(20, 24) > 0 && vertical(20, 16) > 0 && vertical(24, 20) == 0)
        // 45° runs up-right and down-left on screen, never up-left.
        let diagonal = try streak(angle: 45)
        #expect(diagonal(23, 17) > 0 && diagonal(17, 23) > 0 && diagonal(17, 17) == 0)
    }

    @Test func addNoiseChangesColorButNeverAlphaAndMonochromaticKeepsGrays() throws {
        // Left half opaque mid gray, right half transparent.
        let context = try BrushRaster.context(width: 32, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let gray = try #require(context.makeImage())
        func pixels(_ settings: FilterSettings) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .addNoise, image: gray, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity, seed: 7))
            let read = try #require(CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 8))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 32 * 8 * 4))
        }
        let offsets = Array(stride(from: 0, to: 32 * 8 * 4, by: 4))
        let opaque = offsets.filter { $0 / 4 % 32 < 16 }, clear = offsets.filter { $0 / 4 % 32 >= 16 }
        let color = try pixels(FilterSettings(amount: 10))
        #expect(try pixels(FilterSettings(amount: 10)) == color) // the same seed gives the same grain
        #expect(opaque.allSatisfy { color[$0 + 3] == 255 && (112...144).contains(Int(color[$0])) })
        #expect(Set(opaque.map { color[$0] }).count > 5)
        #expect(opaque.contains { color[$0] != color[$0 + 1] }) // color noise differs per channel
        #expect(clear.allSatisfy { color[$0] == 0 && color[$0 + 3] == 0 })
        let mono = try pixels(FilterSettings(amount: 10, gaussian: true, monochromatic: true))
        #expect(opaque.allSatisfy { mono[$0] == mono[$0 + 1] && mono[$0 + 1] == mono[$0 + 2] && mono[$0 + 3] == 255 })
    }

    @Test func removeDistortionBendsAboutTheCenterAndOnlyPincushionCorrectionOpensTheCorners() throws {
        // An opaque image with a distinct color in each quadrant.
        let context = try BrushRaster.context(width: 40, height: 30, mask: false)
        for (index, rect) in [CGRect(x: 0, y: 0, width: 20, height: 15), CGRect(x: 20, y: 0, width: 20, height: 15),
                              CGRect(x: 0, y: 15, width: 20, height: 15), CGRect(x: 20, y: 15, width: 20, height: 15)].enumerated() {
            context.setFillColor(CGColor(srgbRed: CGFloat(index) / 3, green: 0.5, blue: 1 - CGFloat(index) / 3, alpha: 1))
            context.fill(rect)
        }
        let source = try #require(context.makeImage())
        func pixels(_ distortion: Double) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .lensCorrection, image: source, settings: FilterSettings(distortion: distortion),
                                                      scale: 1, selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 30))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 40 * 30 * 4))
        }
        func alpha(_ bytes: [UInt8], _ x: Int, _ y: Int) -> UInt8 { bytes[(y * 40 + x) * 4 + 3] }
        let original = try pixels(0)
        #expect(original.count == 40 * 30 * 4 && (0..<(40 * 30)).allSatisfy { original[$0 * 4 + 3] == 255 })
        // Straightening barrel distortion stretches the edges outward: nothing opens up.
        let barrel = try pixels(100)
        #expect(alpha(barrel, 0, 0) == 255 && alpha(barrel, 39, 29) == 255)
        // Straightening pincushion pulls the edges in: the corners turn transparent, the middle stays put.
        let pincushion = try pixels(-100)
        #expect(alpha(pincushion, 0, 0) == 0 && alpha(pincushion, 39, 29) == 0)
        #expect(Array(pincushion[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]) == Array(original[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]))
    }

    /// A 40 x 20 layer, its left half opaque white and its right half transparent, as the blur tests use.
    private func halfSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        return session
    }

    /// The blur's grid is trimmed back to the pixels it left, and the layer's mask has to come along to the same place.
    /// It was resampled over the untrimmed grid at the trimmed grid's size, squeezing it: the mask's edge, 10 px into
    /// the layer, landed near 3.
    @Test func blurCarriesTheLayerMaskToWhereThePixelsWent() async throws {
        let session = try halfSession()
        // Revealing the left quarter of the layer, hiding the rest.
        let maskContext = try BrushRaster.context(width: 40, height: 20, mask: true)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        session.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: #require(maskContext.makeImage())))
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 3), preview: true)
        await session.commitFilter()
        let layer = try #require(session.activeLayer)
        let pixels = try #require(layer.asset?.image), mask = try #require(layer.mask?.asset.image)
        #expect(pixels.width != 40 + 2 * 11, "the grid was trimmed, which is what moved the mask")
        #expect(mask.width == pixels.width && mask.height == pixels.height)
        let read = try BrushRaster.context(width: mask.width, height: mask.height, mask: true)
        BrushRaster.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height), mask: true, context: read)
        let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
        let row = mask.height / 2, perPixel = layer.transform.size.width / CGFloat(mask.width)
        func documentX(_ column: Int) -> CGFloat { layer.transform.origin.x + (CGFloat(column) + 0.5) * perPixel }
        // From the old layer's left edge rightwards, the first hidden column.
        let start = try #require((0..<mask.width).first { documentX($0) > 0 })
        let edge = try #require((start..<mask.width).first { bytes[row * read.bytesPerRow + $0] < 128 })
        #expect(abs(documentX(edge) - 10) <= 1.5, "the mask's edge stays at x = 10: \(documentX(edge))")
    }

    /// Raising the radius past the room around the layer pads the full-size layer again. That used to happen on the main
    /// actor in the slider's own change; now the preview render makes it, and the bigger grid arrives with its preview.
    @Test func raisingTheBlurPadsTheLayerInTheBackground() async throws {
        let session = try halfSession()
        session.beginFilter(.gaussianBlur)
        let edit = try #require(session.filterEdit)
        while let task = edit.previewTask { await task.value }
        let margin = edit.grownMargin
        session.updateFilter(FilterSettings(radius: 20), preview: true)
        #expect(edit.grownMargin == margin, "nothing was padded during the change itself")
        while let task = edit.previewTask { await task.value }
        #expect(edit.grownMargin >= 62 && edit.grownImage?.width == 40 + 2 * Int(edit.grownMargin))
        let preview = try #require(edit.previewImage(for: edit.layerID))
        #expect(preview.width == edit.previewSource.width, "the preview was made from the grid it is shown with")
        // OK straight after a bigger change, before its preview padded anything, still gives the blur its room.
        session.updateFilter(FilterSettings(radius: 50), preview: true)
        await session.commitFilter()
        let result = try #require(session.activeLayer?.asset?.image)
        #expect(result.height > 20 + 2 * 62, "the blur spread past the room the radius-20 preview had: \(result.height)")
    }

    /// Cancelling a preview reaches its background work, which stops at its next check instead of running on unseen.
    @Test func cancellingThePreviewCancelsItsBackgroundWork() async throws {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let preview = Task { () -> Bool in
            (try? await PixelAdjust.detached {
                signal.yield()
                // Fails rather than hangs should the cancellation never arrive. Generous, because in a full parallel
                // run the main actor can be held for seconds before this test gets to cancel.
                let start = Date()
                while !Task.isCancelled && Date().timeIntervalSince(start) < 120 { usleep(1_000) }
                return Task.isCancelled
            }) ?? false
        }
        // Cancel once the background work is running, not after a guessed delay.
        for await _ in started { break }
        preview.cancel()
        #expect(await preview.value)
    }

    /// Levels' OK, when its layer was replaced while it rendered, keeps the newer pixels and says it didn't apply.
    @Test func levelsApplyDroppedForAChangedLayerIsReported() async throws {
        let session = try halfSession()
        session.beginLevels()
        var settings = LevelsSettings(); settings.ranges[0].white = 128
        session.updateLevels(settings, preview: true)
        let commit = Task { await session.commitLevels() }
        await Task.yield()
        let image = try #require(try BrushRaster.context(width: 40, height: 20, mask: false).makeImage())
        session.document?.layers[0].asset = ImportedImage(image: image, thumbnail: image, name: "Replaced")
        await commit.value
        #expect(session.levels == nil && session.document?.layers[0].asset?.image === image)
        #expect(session.brushError?.contains("Levels") == true)
    }
}
