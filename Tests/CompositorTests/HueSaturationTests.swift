import AppKit
import Testing
@testable import Compositor

@MainActor
struct HueSaturationTests {
    /// A 40×20 canvas: left half pure red, right half mid gray, with a half-transparent strip.
    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        // Replace, so the strip really is half transparent rather than blended onto the colors.
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 16, width: 40, height: 4))
        context.setBlendMode(.normal)
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Colors"))
        return session
    }
    private func pixel(_ session: EditorSession, x: Int, y: Int) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
    /// The color cube is interpolated, so allow a few levels.
    private func near(_ value: [Int], _ target: [Int], _ tolerance: Int = 8) -> Bool {
        zip(value, target).allSatisfy { abs($0 - $1) <= tolerance }
    }
    private func apply(_ session: EditorSession, _ settings: HueSaturationSettings) async {
        session.beginHueSaturation()
        session.updateHueSaturation(settings, preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
    }

    @Test func defaultsAreAnExactNoOp() async throws {
        let session = try makeSession()
        let before = session.document
        let count = session.history.undoCount
        session.beginHueSaturation()
        #expect(session.hueSaturation != nil && !session.canEditLayers) // Other edits wait.
        session.updateHueSaturation(HueSaturationSettings(), preview: true)
        await session.commitHueSaturation()
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.hueSaturation == nil && session.canEditLayers)
    }

    @Test func hueRotatesSaturationAndLightnessFollowPhotoshopRanges() async throws {
        let session = try makeSession()
        await apply(session, HueSaturationSettings(hue: 120))
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 255, 0, 255]))   // Red → green.
        #expect(near(try await pixel(session, x: 30, y: 5), [128, 128, 128, 255])) // Gray unchanged.
        session.undo()

        await apply(session, HueSaturationSettings(saturation: -100))
        let gray = try await pixel(session, x: 5, y: 5)
        #expect(gray[0] == gray[1] && gray[1] == gray[2] && gray[3] == 255)
        session.undo()

        await apply(session, HueSaturationSettings(lightness: 100))
        #expect(near(try await pixel(session, x: 5, y: 5), [255, 255, 255, 255]))
        session.undo()

        await apply(session, HueSaturationSettings(lightness: -100))
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 0, 0, 255]))
    }

    @Test func colorizeGivesEverythingOneHueAndKeepsAlpha() async throws {
        let session = try makeSession()
        await apply(session, HueSaturationSettings(hue: 240, saturation: 100, lightness: 0, colorize: true))
        let left = try await pixel(session, x: 5, y: 5), right = try await pixel(session, x: 30, y: 5)
        #expect(left[2] > left[0] && right[2] > right[0])   // Both now blue-ish.
        #expect(left[3] == 255)
        // The half-transparent strip keeps its alpha.
        let strip = try await pixel(session, x: 5, y: 18)
        #expect(abs(strip[3] - 128) <= 2)
    }

    @Test func adjustmentStaysInsideTheSelectionAndIsOneUndoStep() async throws {
        let session = try makeSession()
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 20), transform: nil),
                               mode: .replace, name: "Select")
        let count = session.history.undoCount
        await apply(session, HueSaturationSettings(hue: 120))
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Hue/Saturation")
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 255, 0, 255]))     // Inside: rotated.
        #expect(near(try await pixel(session, x: 15, y: 5), [255, 0, 0, 255]))    // Outside: untouched.
        session.undo()
        #expect(near(try await pixel(session, x: 5, y: 5), [255, 0, 0, 255]))
    }

    /// Previews are drawn on the canvas from a downscaled copy; the document is untouched
    /// until OK, so these read the preview image rather than an export.
    @Test func previewIsLiveDoesNotTouchTheDocumentAndNeverAccumulates() async throws {
        let session = try makeSession()
        let before = session.document
        let count = session.history.undoCount
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        await session.hueSaturationTask?.value
        let edit = try #require(session.hueSaturation)
        #expect(near(try previewPixel(edit, x: 5, y: 5), [0, 255, 0, 255]))
        #expect(session.document == before && session.history.undoCount == count)
        // Dragging further starts from the original each time, never stacking.
        session.updateHueSaturation(HueSaturationSettings(hue: 240), preview: true)
        await session.hueSaturationTask?.value
        #expect(near(try previewPixel(edit, x: 5, y: 5), [0, 0, 255, 255]))
        // Preview off drops back to the layer's own pixels.
        session.updateHueSaturation(HueSaturationSettings(hue: 240), preview: false)
        #expect(edit.previewImage(for: edit.layerID) == nil)
        session.cancelHueSaturation()
        #expect(session.document == before && session.hueSaturation == nil)
        // OK renders at full size and only then changes the layer.
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
        #expect(session.document?.layers.first?.asset?.image.width == before?.layers.first?.asset?.image.width)
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 255, 0, 255]))
    }

    /// Cancel leaves its render running in the background. Reopening and moving a slider straight away used to wait on
    /// that cancelled render, which then found its panel gone and returned without starting the new one: the canvas
    /// showed the plain layer until the next slider change.
    @Test func reopeningRightAfterCancelPreviewsTheFirstChange() async throws {
        let session = try makeSession()
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        let abandoned = try #require(session.hueSaturationTask)
        session.cancelHueSaturation()
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        let edit = try #require(session.hueSaturation)
        await abandoned.value
        await session.hueSaturationTask?.value
        #expect(edit.previewImage(for: edit.layerID) != nil, "the reopened panel's first change is previewed")
        #expect(near(try previewPixel(edit, x: 5, y: 5), [0, 255, 0, 255]))
        session.cancelHueSaturation()
    }

    /// A render cancelled after it started must not put its picture back once the preview has been cleared.
    @Test func aCancelledRenderNeverRepaintsAClearedPreview() async throws {
        let session = try makeSession()
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        let running = try #require(session.hueSaturationTask)
        session.updateHueSaturation(HueSaturationSettings(), preview: true)
        await running.value
        let edit = try #require(session.hueSaturation)
        #expect(edit.previewImage(for: edit.layerID) == nil)
        session.cancelHueSaturation()
    }

    /// OK whose layer changed while it rendered is dropped, and says so rather than closing as if it had applied.
    @Test func applyDroppedForAChangedLayerIsReported() async throws {
        let session = try makeSession()
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        let commit = Task { await session.commitHueSaturation() }
        await Task.yield()
        let replacement = try BrushRaster.context(width: 40, height: 20, mask: false).makeImage()
        let image = try #require(replacement)
        session.document?.layers[0].asset = ImportedImage(image: image, thumbnail: image, name: "Replaced")
        await commit.value
        #expect(session.hueSaturation == nil)
        #expect(session.document?.layers[0].asset?.image === image, "the newer pixels stay")
        #expect(session.brushError?.contains("Hue/Saturation") == true)
    }

    /// A pixel of the live preview image, which may be smaller than the layer.
    private func previewPixel(_ edit: HueSaturationEdit, x: Int, y: Int) throws -> [Int] {
        let image = try #require(edit.previewImage(for: edit.layerID))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    /// A 40×20 canvas: left half pure red, right half pure blue, both opaque.
    private func redAndBlue() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "RedBlue"))
        return session
    }

    @Test func bandWeightsRampThroughFalloffAndWrapAround() {
        let reds = ColorRange.reds.defaultBand // 315 / 345 / 15 / 45, wrapping past 0.
        #expect(reds.weight(of: 0) == 1 && reds.weight(of: 345) == 1 && reds.weight(of: 15) == 1)
        #expect(abs(reds.weight(of: 330) - 0.5) < 0.001)   // Halfway up the shoulder.
        #expect(abs(reds.weight(of: 30) - 0.5) < 0.001)    // Halfway down the far shoulder.
        #expect(reds.weight(of: 315) == 0 && reds.weight(of: 45) == 0 && reds.weight(of: 180) == 0)
        #expect(ColorRange.master.defaultBand.weight(of: 123) == 1)
        // Handles keep their order: crossing moves are refused.
        var band = ColorRange.greens.defaultBand
        band.setHandle(1, to: 200) // rangeStart past rangeEnd.
        #expect(band == ColorRange.greens.defaultBand)
        band.setHandle(1, to: 110)
        #expect(band.rangeStart == 110)
    }

    @Test func colorRangesAdjustIndependently() async throws {
        let session = try redAndBlue()
        var settings = HueSaturationSettings(hue: 60, range: .reds)
        settings.adjustments[.blues] = RangeAdjustment(saturation: -100)
        session.beginHueSaturation()
        session.updateHueSaturation(settings, preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
        let red = try await pixel(session, x: 5, y: 5), blue = try await pixel(session, x: 30, y: 5)
        #expect(near(red, [255, 255, 0, 255]))              // Reds rotated to yellow.
        #expect(blue[0] == blue[1] && blue[1] == blue[2])   // Blues desaturated to gray.
    }

    @Test func rangesLeaveOtherHuesAloneAndInvertFlipsTheBand() async throws {
        let session = try redAndBlue()
        let before = try await pixel(session, x: 30, y: 5)
        await apply(session, HueSaturationSettings(lightness: -100, range: .reds))
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 0, 0, 255]))  // Reds → black.
        #expect(near(try await pixel(session, x: 30, y: 5), before))         // Blues untouched.
        session.undo()

        var inverted = HueSaturationSettings(lightness: -100, range: .reds)
        inverted.invertRange = true
        await apply(session, inverted)
        #expect(near(try await pixel(session, x: 5, y: 5), [255, 0, 0, 255])) // Reds untouched.
        #expect(near(try await pixel(session, x: 30, y: 5), [0, 0, 0, 255]))  // Everything else → black.
    }

    @Test func slidersEditTheSelectedRangeAndTheAfterBarFollowsHueShifts() {
        var settings = HueSaturationSettings()
        settings.hue = 30                       // Master.
        settings.range = .greens
        #expect(settings.hue == 0)              // Greens start untouched.
        settings.hue = -40
        #expect(settings.adjustments[.master]?.hue == 30 && settings.adjustments[.greens]?.hue == -40)
        settings.range = .master
        #expect(settings.hue == 30 && !settings.isIdentity)
        // The "after" spectrum shifts hues inside a band and leaves far-away hues alone.
        var greensOnly = HueSaturationSettings(hue: 60, range: .greens)
        greensOnly.adjustments[.master] = RangeAdjustment()
        #expect(abs(HueSaturationFilter.shiftedHue(120, settings: greensOnly) - 180) < 0.001)
        #expect(abs(HueSaturationFilter.shiftedHue(0, settings: greensOnly) - 0) < 0.001)
    }

    @Test func eyedroppersRecenterWidenAndNarrowTheBand() async throws {
        let session = try redAndBlue() // Red at hue 0 on the left, blue at 240 on the right.
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 10, range: .greens), preview: false)
        session.hueSampleMode = .replace
        session.sampleHueRange(at: CGPoint(x: 5, y: 5))
        var band = try #require(session.hueSaturation).settings.band
        #expect(band.weight(of: 0) == 1 && band.weight(of: 120) == 0) // Centered on red.

        session.hueSampleMode = .add
        session.sampleHueRange(at: CGPoint(x: 30, y: 5))
        band = try #require(session.hueSaturation).settings.band
        #expect(band.weight(of: 240) == 1 && band.weight(of: 0) == 1) // Blue folded in.

        session.hueSampleMode = .remove
        session.sampleHueRange(at: CGPoint(x: 30, y: 5))
        band = try #require(session.hueSaturation).settings.band
        #expect(band.weight(of: 240) == 0)                            // Blue pushed back out.
        session.cancelHueSaturation()
        #expect(session.hueSampleMode == nil)
    }

    @Test func targetedAdjustmentPicksTheRangeUnderTheCursor() async throws {
        let session = try redAndBlue()
        session.beginHueSaturation()
        session.hueTargeting = true
        #expect(session.beginHueTargeting(at: CGPoint(x: 30, y: 5))) // Blue half.
        #expect(session.hueSaturation?.settings.range == .blues)
        session.dragHueTargeting(byViewDelta: 60, adjustsHue: false)
        #expect(session.hueSaturation?.settings.adjustments[.blues]?.saturation == 30)
        // Each drag is measured from where it started, so it never accumulates.
        session.dragHueTargeting(byViewDelta: 20, adjustsHue: false)
        #expect(session.hueSaturation?.settings.adjustments[.blues]?.saturation == 10)
        session.dragHueTargeting(byViewDelta: -40, adjustsHue: true) // Command holds hue.
        #expect(session.hueSaturation?.settings.adjustments[.blues]?.hue == -20)
        session.endHueTargeting()
        session.cancelHueSaturation()
        #expect(!session.hueTargeting)
    }

    @Test func samplingNeedsAColorRangeAndAColorfulPixel() throws {
        let session = try redAndBlue()
        session.beginHueSaturation()
        let untouched = try #require(session.hueSaturation).settings.band
        session.hueSampleMode = .replace
        session.sampleHueRange(at: CGPoint(x: 5, y: 5))   // Master is selected: nothing to retarget.
        #expect(session.hueSaturation?.settings.band == untouched)
        // A gray pixel has no hue to sample.
        let gray = try makeSession() // Right half is mid gray.
        gray.beginHueSaturation()
        gray.updateHueSaturation(HueSaturationSettings(range: .reds), preview: false)
        let before = try #require(gray.hueSaturation).settings.band
        gray.hueSampleMode = .replace
        gray.sampleHueRange(at: CGPoint(x: 30, y: 5))
        #expect(gray.hueSaturation?.settings.band == before)
    }

    /// Hue/Saturation opened over a gradient still being placed: the gradient goes onto the layer first and the panel
    /// adjusts that, as Levels does. Reading the layer before the gradient landed made OK drop the adjustment.
    @Test func waitsForAPendingGradientAndAdjustsIt() async throws {
        let session = try makeSession()
        session.selectTool(.gradient)
        session.gradientSettings.style = .foregroundToBackground
        session.beginGradient(at: CGPoint(x: 0.5, y: 2))
        session.moveGradient(end: CGPoint(x: 39.5, y: 2))
        session.endGradientDrag()
        #expect(session.gradientEdit != nil)
        let count = session.history.undoCount
        session.beginHueSaturation()
        for _ in 0..<500 where session.hueSaturation == nil { try await Task.sleep(for: .milliseconds(5)) }
        let edit = try #require(session.hueSaturation)
        #expect(session.gradientEdit == nil && session.history.undoCount == count + 1, "the gradient was committed first")
        #expect(edit.original.image === session.activeLayer?.asset?.image, "the panel reads the layer with the gradient on it")
        let gradient = try await pixel(session, x: 39, y: 5)
        session.updateHueSaturation(HueSaturationSettings(lightness: -100), preview: true)
        await session.commitHueSaturation()
        #expect(session.brushError == nil, "nothing was dropped: \(session.brushError ?? "")")
        #expect(session.history.undoCount == count + 2 && session.history.undoName == "Hue/Saturation")
        #expect(gradient[0] > 128, "the far end of the gradient is light: \(gradient)")
        #expect(near(try await pixel(session, x: 39, y: 5), [0, 0, 0, 255]), "and the adjustment darkened it")
    }

    /// Colorize wraps a negative hue round the wheel: −60° is magenta (300°), not the red a negative sector gave.
    @Test func colorizeWrapsANegativeHue() {
        let negative = HueSaturationSettings(hue: -60, saturation: 100, colorize: true)
        let wrapped = HueSaturationSettings(hue: 300, saturation: 100, colorize: true)
        let color = HueSaturationFilter.adjust(red: 0.5, green: 0.5, blue: 0.5, settings: negative)
        let expected = HueSaturationFilter.adjust(red: 0.5, green: 0.5, blue: 0.5, settings: wrapped)
        #expect(abs(color.red - expected.red) < 1e-12 && abs(color.green - expected.green) < 1e-12
                && abs(color.blue - expected.blue) < 1e-12)
        #expect(color.red > 0.9 && color.blue > 0.9 && color.green < 0.1, "magenta: \(color)")
        let past = HueSaturationFilter.adjust(red: 0.5, green: 0.5, blue: 0.5,
                                              settings: HueSaturationSettings(hue: -420, saturation: 100, colorize: true))
        #expect(abs(past.red - expected.red) < 1e-12 && abs(past.blue - expected.blue) < 1e-12, "a full turn further back too")
    }

    /// A layer past the preview limit opens the panel at once, reading the layer itself, and the smaller copy its
    /// previews read is made off the main actor; previews wait for it rather than render at full size.
    @Test func aLargeLayerIsCopiedForPreviewsInTheBackground() async throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 2)
        let context = try BrushRaster.context(width: HueSaturationEdit.previewLimit + 400, height: 2, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: HueSaturationEdit.previewLimit + 400, height: 2))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Wide"))
        session.beginHueSaturation()
        let edit = try #require(session.hueSaturation)
        #expect(edit.previewSource === image, "nothing was drawn while the panel opened")
        let setup = try #require(edit.setupTask)
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        #expect(session.hueSaturationTask == nil, "the preview waits for the copy")
        await setup.value
        #expect(edit.previewSource.width == HueSaturationEdit.previewLimit && edit.setupTask == nil)
        await session.hueSaturationTask?.value
        let preview = try #require(edit.previewImage(for: edit.layerID))
        #expect(preview.width == HueSaturationEdit.previewLimit, "the preview was made from the copy")
        session.cancelHueSaturation()
    }
}
