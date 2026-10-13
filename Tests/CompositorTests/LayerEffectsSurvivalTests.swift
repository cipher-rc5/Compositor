import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Layer effects are kept apart from pixels, so an edit that replaces a layer's pixels, or rebuilds the whole
/// document, must carry them over rather than quietly dropping them.
@MainActor
struct LayerEffectsSurvivalTests {
    private func sessionWithEffects() async throws -> (EditorSession, LayerEffects, URL) {
        let url = try ImageImportTests().fixture(.png)
        let session = EditorSession()
        await session.importImages([url])
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 4, red: 0.1, green: 0.8, blue: 0.2, opacity: 0.9, inside: false)
        let index = try #require(session.document?.layers.indices.first)
        session.document?.layers[index].effects = effects
        return (session, effects, url)
    }

    @Test func replacingPixelsKeepsEverythingButThePixels() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try await ImageImporter.shared.decode(url)
        var layer = ImageLayer(asset: asset, origin: .zero)
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 2, red: 1, green: 0, blue: 0, opacity: 1, inside: true)
        layer.effects = effects
        layer.opacity = 0.5
        layer.blendMode = .multiply
        let replaced = layer.replacingPixels(asset, mask: nil)
        #expect(replaced.id == layer.id && replaced.effects == effects)
        #expect(replaced.opacity == 0.5 && replaced.blendMode == .multiply)
        #expect(replaced.shape == nil && replaced.text == nil)
    }

    @Test func pixelCommandsKeepEffects() async throws {
        let (session, effects, url) = try await sessionWithEffects()
        defer { try? FileManager.default.removeItem(at: url) }

        session.beginFilter(.curves)
        var curves = FilterSettings()
        curves.curves.channels[0] = [CurvePoint(x: 0, y: 40), CurvePoint(x: 255, y: 255)]
        session.updateFilter(curves, preview: true)
        await session.commitFilter()
        #expect(session.activeLayer?.effects == effects, "Curves")

        session.beginHueSaturation()
        var hue = try #require(session.hueSaturation).settings
        hue.hue = 60
        session.updateHueSaturation(hue, preview: true)
        await session.commitHueSaturation()
        #expect(session.activeLayer?.effects == effects, "Hue/Saturation")

        session.beginLevels()
        var levels = try #require(session.levels).settings
        levels.ranges[0].outputWhite = 200
        session.updateLevels(levels, preview: true)
        await session.commitLevels()
        #expect(session.activeLayer?.effects == effects, "Levels")

        let before = session.activeLayer?.asset?.image
        await session.invertPixels()
        #expect(session.activeLayer?.asset?.image !== before)
        #expect(session.activeLayer?.effects == effects, "Invert")
    }

    @Test func documentSizeChangesKeepEffects() async throws {
        let (session, effects, url) = try await sessionWithEffects()
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()),
            to: CanvasSizeOptions(width: 80, height: 40, anchor: 4))
        session.applyDocumentSize(canvas, actionName: "Canvas Size")
        #expect(session.document?.width == 80)
        #expect(session.activeLayer?.effects == effects, "Canvas Size")

        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 40, height: 20, resolution: 72))
        session.applyImageSize(resized)
        #expect(session.document?.width == 40)
        #expect(session.activeLayer?.effects == effects, "Image Size")

        session.cropRect = CGRect(x: 0, y: 0, width: 30, height: 20)
        await session.commitCrop()
        #expect(session.document?.width == 30)
        #expect(session.activeLayer?.effects == effects, "Crop")

        session.undo()
        #expect(session.document?.width == 40)
        #expect(session.activeLayer?.effects == effects)
    }

    /// Trim rebuilds the document; the Gaussian Blur filter grows the layer; Fill and Clear replace its pixels.
    @Test func trimBlurFillAndClearKeepEffects() async throws {
        let (session, effects, url) = try await sessionWithEffects()
        defer { try? FileManager.default.removeItem(at: url) }

        // The fixture is opaque on its left half only, so Trim has most of the right half (all but the stroke around
        // the pixels) to cut away.
        #expect(try await session.applyTrim(TrimOptions(basedOn: .transparentPixels)))
        #expect((session.document?.width ?? 64) < 64)
        #expect(session.activeLayer?.effects == effects, "Trim")

        let before = session.activeLayer?.asset?.image
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 2), preview: true)
        await session.commitFilter()
        #expect(session.activeLayer?.asset?.image !== before)
        #expect(session.activeLayer?.effects == effects, "Gaussian Blur")

        session.applySelection(CGPath(rect: CGRect(x: 4, y: 4, width: 8, height: 8), transform: nil), mode: .replace, name: "Select")
        var image = session.activeLayer?.asset?.image
        #expect(await session.fillSelection(with: .foreground))
        #expect(session.activeLayer?.asset?.image !== image)
        #expect(session.activeLayer?.effects == effects, "Fill")

        image = session.activeLayer?.asset?.image
        #expect(await session.clearSelectedPixels())
        #expect(session.activeLayer?.asset?.image !== image)
        #expect(session.activeLayer?.effects == effects, "Clear")
    }

    /// A layer copied to another project tab arrives with its effects.
    @Test func crossProjectCopyKeepsEffects() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 100, height: 100)
        first.session.insert(try LiveMaskTests().asset([255, 255, 255, 255]))
        let original = try #require(first.session.activeLayerID)
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 3, red: 0.2, green: 0.4, blue: 0.9, opacity: 1, inside: false)
        effects.shadow = ShadowEffect(angle: 90, distance: 4, blur: 2, red: 0, green: 0, blue: 0, opacity: 0.5)
        let index = try #require(first.session.document?.layers.firstIndex { $0.id == original })
        first.session.document?.layers[index].effects = effects
        let second = workspace.addTab()
        second.session.createDocument(width: 200, height: 200)
        await workspace.copyLayer(original, into: second.id)
        let copied = try #require(second.session.document?.layers.first)
        #expect(copied.id != original)
        #expect(copied.effects == effects)
    }
}

