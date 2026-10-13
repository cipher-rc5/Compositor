import AppKit
import Testing
@testable import Compositor

/// Serialized: every test shares the one system pasteboard.
@MainActor @Suite(.serialized)
struct SelectionClipboardTests {
    private let red = PaletteColor(red: 1, green: 0, blue: 0)
    private let blue = PaletteColor(red: 0, green: 0, blue: 1)

    /// A 100×40 canvas whose layer is red on the left half and blue on the right.
    private func makeSession() async -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.setPaletteColor(red, background: false)
        session.setPaletteColor(blue, background: true)
        await session.fillSelection(with: .background)
        select(session, CGRect(x: 0, y: 0, width: 50, height: 40))
        await session.fillSelection(with: .foreground)
        session.deselect()
        return session
    }
    private func select(_ session: EditorSession, _ rect: CGRect) {
        session.applySelection(CGPath(rect: rect, transform: nil), mode: .replace, name: "Select")
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }
    /// Renders only one layer, to check a layer's own pixels.
    private func layerPixel(_ session: EditorSession, _ id: UUID, x: Int, y: Int) async throws -> [Int] {
        let full = try #require(session.document)
        var solo = full
        solo.layers = full.layers.filter { $0.id == id }
        session.document = solo
        defer { session.document = full }
        return try pixel(try await render(session), x: x, y: y)
    }

    @Test func copyAndPastePutsPixelsOnANewLayerInPlace() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 40, y: 10, width: 20, height: 20)) // Straddles red and blue.
        session.copySelection()
        let count = session.history.undoCount
        #expect(session.canPaste)
        session.paste()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Paste")
        let pasted = try #require(session.activeLayer)
        #expect(pasted.id != source && pasted.name == "Layer 2" && session.selection == nil)
        #expect(pasted.transform.origin == CGPoint(x: 40, y: 10) && pasted.size == CGSize(width: 20, height: 20))
        #expect(try await layerPixel(session, pasted.id, x: 45, y: 15) == [255, 0, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 55, y: 15) == [0, 0, 255, 255])
        #expect(try await layerPixel(session, pasted.id, x: 30, y: 15)[3] == 0)
        #expect(try await layerPixel(session, source, x: 45, y: 15) == [255, 0, 0, 255]) // Source untouched.
        session.undo()
        #expect(session.document?.layers.count == 1)
    }

    @Test func cutLeavesAHoleAndPasteRestoresThePixels() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        await session.cutSelection()
        #expect(try await layerPixel(session, source, x: 15, y: 15)[3] == 0)
        session.paste()
        #expect(try pixel(try await render(session), x: 15, y: 15) == [255, 0, 0, 255])
    }

    @Test func layerViaCopyCopiesTheSelectionOrDuplicatesTheLayer() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayer)
        select(session, CGRect(x: 60, y: 0, width: 10, height: 40))
        session.layerViaCopy()
        #expect(session.history.undoName == "Layer via Copy" && session.document?.layers.count == 2)
        #expect(session.activeLayer?.size == CGSize(width: 10, height: 40) && session.selection == nil,
                "size \(String(describing: session.activeLayer?.size))")
        session.selectLayer(source.id)
        session.layerViaCopy()
        #expect(session.history.undoName == "Duplicate Layer" && session.activeLayer?.name == "\(source.name) copy")
        #expect(session.activeLayer?.asset?.image === source.asset?.image)
    }

    @Test func transformSelectionMovesPixelsAndOutlineAsOneUndo() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        let before = session.document
        let count = session.history.undoCount
        #expect(session.canTransformSelection)
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        #expect(session.transformEdit?.floating != nil && session.tool == .move)
        draft.origin = CGPoint(x: 70, y: 20)
        session.previewTransform(draft)
        #expect(session.displayedSelection?.path.boundingBoxOfPath == CGRect(x: 70, y: 20, width: 10, height: 10))
        session.commitTransform()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Transform Selection")
        #expect(session.document?.layers.count == 1 && session.activeLayerID == source)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 70, y: 20, width: 10, height: 10))
        let result = try await render(session)
        #expect(try pixel(result, x: 15, y: 15)[3] == 0)                // Hole where they were.
        #expect(try pixel(result, x: 75, y: 25) == [255, 0, 0, 255])    // Red now on the blue side.
        #expect(try pixel(result, x: 85, y: 25) == [0, 0, 255, 255])
        session.undo()
        #expect(session.document == before)
    }

    @Test func escapeRestoresExactlyWithoutAnUndoStep() async throws {
        let session = await makeSession()
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        let before = session.document, active = session.activeLayerID
        let count = session.history.undoCount
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        draft.origin.x += 30
        session.previewTransform(draft)
        session.cancelTransform()
        #expect(session.document == before && session.activeLayerID == active)
        #expect(session.transformEdit == nil && session.history.undoCount == count)
    }

    @Test func applyingAnUnchangedTransformLeavesSoftEdgesUntouched() async throws {
        let session = await makeSession()
        session.selectionAntialiased = true
        session.applySelection(CGPath(ellipseIn: CGRect(x: 10.3, y: 5.7, width: 30, height: 25), transform: nil),
                               mode: .replace, name: "Select")
        let before = session.document
        let count = session.history.undoCount
        await session.beginSelectionTransform()
        session.commitTransform()
        #expect(session.document == before && session.history.undoCount == count)
    }

    @Test func scalingAndMovingPastTheLayerEdgeGrowsTheLayer() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 0, y: 0, width: 10, height: 10))
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        draft.size = CGSize(width: 20, height: 20)   // 2× larger…
        draft.origin = CGPoint(x: 90, y: 30)          // …and hanging off the canvas corner.
        session.previewTransform(draft)
        session.selectTool(.lasso)                    // Switching tools applies it, rendered off the main thread.
        #expect(await waitUntil { session.tool == .lasso })
        #expect(session.transformEdit == nil && session.history.undoName == "Transform Selection")
        let layer = try #require(session.document?.layers.first { $0.id == source })
        #expect(layer.size == CGSize(width: 110, height: 50))
        let result = try await render(session)
        #expect(try pixel(result, x: 95, y: 35) == [255, 0, 0, 255])
        #expect(try pixel(result, x: 5, y: 5)[3] == 0)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 90, y: 30, width: 20, height: 20))
    }

    @Test func lassoShapedSelectionCopiesAndPastes() async throws {
        let session = await makeSession()
        session.selectTool(.lasso)
        // A triangle drawn with the lasso, over the red half.
        session.beginLasso(at: CGPoint(x: 10, y: 5), mode: .replace)
        for point in [CGPoint(x: 40, y: 5), CGPoint(x: 10, y: 35)] { session.extendLasso(to: point) }
        session.finishLasso()
        #expect(session.history.undoName == "Lasso" && session.canCopyPixels)
        session.copySelection()
        session.paste()
        let pasted = try #require(session.activeLayer)
        #expect(pasted.transform.origin == CGPoint(x: 10, y: 5) && pasted.size == CGSize(width: 30, height: 30))
        #expect(try await layerPixel(session, pasted.id, x: 15, y: 10) == [255, 0, 0, 255]) // Inside the triangle.
        #expect(try await layerPixel(session, pasted.id, x: 38, y: 33)[3] == 0)             // Past the diagonal.
    }

    @Test func copyMergedTakesEveryVisibleLayerNotJustTheActiveOne() async throws {
        let session = await makeSession()
        // A small green layer on top of the red/blue one.
        let context = try BrushRaster.context(width: 20, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let square = try #require(context.makeImage())
        session.insert(ImportedImage(image: square, thumbnail: square, name: "Green"))
        let green = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == green })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 60, y: 10), size: CGSize(width: 20, height: 20))
        select(session, CGRect(x: 55, y: 5, width: 30, height: 30))

        session.copySelection() // Active layer only: just the green square.
        session.paste()
        var pasted = try #require(session.activeLayer)
        #expect(try await layerPixel(session, pasted.id, x: 65, y: 15) == [0, 255, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 58, y: 8)[3] == 0)
        session.undo()

        session.selectLayer(green)
        select(session, CGRect(x: 55, y: 5, width: 30, height: 30))
        #expect(session.canCopyMerged)
        await session.copyMergedSelection() // Every visible layer.
        session.paste()
        pasted = try #require(session.activeLayer)
        #expect(try await layerPixel(session, pasted.id, x: 65, y: 15) == [0, 255, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 58, y: 8) == [0, 0, 255, 255])
        session.undo()

        // Hidden layers are left out.
        session.selectLayer(green)
        session.toggleLayerVisibility(green)
        select(session, CGRect(x: 55, y: 5, width: 30, height: 30))
        await session.copyMergedSelection()
        session.paste()
        pasted = try #require(session.activeLayer)
        #expect(try await layerPixel(session, pasted.id, x: 65, y: 15) == [0, 0, 255, 255])
    }

    /// Cut clears only what it managed to copy: when the copy fails, the pixels stay and nothing is recorded.
    @Test func aCutThatCopiesNothingClearsNothing() async throws {
        let session = await makeSession()
        // A sliver too thin to hold a whole pixel: there is nothing to copy, though Clear would still run.
        select(session, CGRect(x: 20, y: 10, width: 0.0005, height: 20))
        #expect(session.canCopyPixels && session.selectionCopyRegion() == nil)
        let before = session.document, count = session.history.undoCount
        #expect(!session.copySelection())
        await session.cutSelection()
        #expect(session.document == before && session.history.undoCount == count)
        await session.clearSelectedPixels()
        #expect(session.history.undoCount == count + 1, "Clear on its own records a step, so the cut above really skipped it")
    }

    /// On a pasteboard of the test's own, not the system's: what the person running the tests copied stays put.
    @Test func copyPutsAPNGOnThePasteboard() async throws {
        let session = await makeSession()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CompositorTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        session.pasteboard = pasteboard
        let systemChangeCount = NSPasteboard.general.changeCount
        select(session, CGRect(x: 40, y: 10, width: 20, height: 20))
        #expect(session.copySelection())
        await session.pasteboardWrite?.value
        let data = try #require(pasteboard.data(forType: .png))
        let image = try #require(NSBitmapImageRep(data: data)?.cgImage)
        #expect(image.width == 20 && image.height == 20)
        #expect(try pixel(image, x: 2, y: 2) == [255, 0, 0, 255] && pixel(image, x: 17, y: 2) == [0, 0, 255, 255])
        // Writing the PNG doesn't count as another app's copy: Paste still puts the pixels back in place.
        #expect(session.canPaste && session.pixelClipboard?.changeCount == pasteboard.changeCount)
        #expect(NSPasteboard.general.changeCount == systemChangeCount)
    }

    // MARK: The 100-megapixel budget a project can save

    /// A gray image of the given size whose pixels are never touched, so a test can stand near the budget cheaply.
    private func untouched(width: Int, height: Int) throws -> ImportedImage {
        let provider = try #require(CGDataProvider(data: Data(count: width * height) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ImportedImage(image: image, thumbnail: image, name: "Large")
    }

    /// `makeSession`'s canvas with a layer of `megapixels` million image pixels added beneath, never drawn.
    private func crowdedSession(holding megapixels: Int) async throws -> EditorSession {
        let session = await makeSession()
        let large = ImageLayer(asset: try untouched(width: 10_000, height: megapixels * 100), origin: .zero)
        session.document?.layers.insert(large, at: 0)
        return session
    }

    @Test func duplicatingPastTheBudgetIsRefusedAndSaysSo() async throws {
        let session = try await crowdedSession(holding: 60)
        let large = try #require(session.document?.layers.first)
        session.selectLayer(large.id)
        let before = session.document, count = session.history.undoCount
        session.duplicateActiveLayer()
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.brushError?.contains("100 megapixels") == true)
        // The small layer still fits.
        session.brushError = nil
        session.selectLayer(try #require(session.document?.layers.last?.id))
        session.duplicateActiveLayer()
        #expect(session.document?.layers.count == 3 && session.brushError == nil)
    }

    @Test func pastingPastTheBudgetIsRefusedAndSaysSo() async throws {
        let session = try await crowdedSession(holding: 99)
        let clip = try untouched(width: 2_000, height: 1_000)
        session.pixelClipboard = PixelClipboard(image: clip.image, origin: .zero, changeCount: NSPasteboard.general.changeCount)
        let before = session.document, count = session.history.undoCount
        #expect(session.canPaste)
        session.paste()
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.brushError?.contains("Paste") == true)
        session.pixelClipboard = nil
    }

    @Test func layerViaCopyPastTheBudgetIsRefusedAndSaysSo() async throws {
        // 99,995,000 beside the canvas's own 4,000: the 2,000 more a copy of half the canvas needs don't fit.
        let session = await makeSession()
        let large = ImageLayer(asset: try untouched(width: 19_999, height: 5_000), origin: .zero)
        session.document?.layers.insert(large, at: 0)
        session.selectLayer(try #require(session.document?.layers.last?.id))
        select(session, CGRect(x: 0, y: 0, width: 50, height: 40))
        let before = session.document, count = session.history.undoCount
        session.layerViaCopy()
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.brushError?.contains("Layer via Copy") == true)
        // Room for it once the large layer is gone.
        session.brushError = nil
        session.document?.layers.removeFirst()
        session.layerViaCopy()
        #expect(session.document?.layers.count == 2 && session.brushError == nil)
    }

    @Test func aShapePastTheBudgetIsRefusedAndSaysSo() async throws {
        // 99,004,000 held: a 1000 × 1000 shape doesn't fit, a 10 × 10 one does.
        let session = try await crowdedSession(holding: 99)
        session.selectTool(.shape)
        func drag(to end: CGPoint) {
            session.beginShape(at: .zero)
            session.dragShape(to: end, square: false, fromCenter: false)
            session.finishShape()
        }
        let before = session.document, count = session.history.undoCount
        drag(to: CGPoint(x: 1_000, y: 1_000))
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.brushError?.contains("The new shape") == true && session.brushError?.contains("100 megapixels") == true)
        session.brushError = nil
        drag(to: CGPoint(x: 10, y: 10))
        #expect(session.document?.layers.count == 3 && session.activeLayer?.liveShape != nil && session.brushError == nil)
    }

    @Test func aTextLayerPastTheBudgetIsRefusedAndKeepsItsDraft() async throws {
        let session = try await crowdedSession(holding: 99)
        session.selectTool(.type)
        session.beginText(in: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        session.textDraft?.style.content = "Too large"
        let draft = try #require(session.textDraft)
        let before = session.document, count = session.history.undoCount
        #expect(!session.applyText(draft))
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.brushError?.contains("The new text layer") == true && session.brushError?.contains("100 megapixels") == true)
        // The draft stays open, so what was typed isn't lost, and it goes in once there is room.
        #expect(session.textDraft?.style.content == "Too large")
        session.brushError = nil
        session.document?.layers.removeFirst()
        #expect(session.applyText(try #require(session.textDraft)))
        #expect(session.document?.layers.count == 2 && session.activeLayer?.liveText != nil && session.brushError == nil)
    }
}
