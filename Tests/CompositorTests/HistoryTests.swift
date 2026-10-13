import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct HistoryTests {
    @Test func everyLayerEditRoundTripsWithSelection() throws {
        let session = EditorSession()
        var states: [(CanvasDocument?, UUID?)] = [(nil, nil)]
        func capture() { states.append((session.document, session.activeLayerID)) }
        session.createDocument(width: 800, height: 600); capture()
        session.addBlankLayer(); capture()
        session.addBlankLayer(); capture()
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Foreground"); capture()
        session.toggleLayerVisibility(id); capture()
        session.placeLayer(id, in: nil, atBottom: true); capture()
        session.moveActiveLayer(by: 1); capture()
        session.deleteActiveLayer(); capture()
        for expected in states.dropLast().reversed() {
            #expect(session.canUndo)
            session.undo()
            #expect(session.document == expected.0)
            #expect(session.activeLayerID == expected.1)
        }
        #expect(!session.canUndo)
        for expected in states.dropFirst() {
            session.redo()
            #expect(session.document == expected.0)
            #expect(session.activeLayerID == expected.1)
        }
        #expect(!session.canRedo)
    }

    @Test func navigationNoOpsAndSaveRevisionPreserveHistory() throws {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600)
        session.addBlankLayer()
        let id = try #require(session.activeLayerID)
        session.history.markSaved()
        #expect(!session.isModified)
        session.renameLayer(id, to: "Changed")
        #expect(session.isModified)
        session.undo()
        #expect(!session.isModified)
        let count = session.history.undoCount
        session.zoom(to: 2)
        session.renameLayer(id, to: "Layer 1")
        session.renameLayer(id, to: "   ")
        session.placeLayer(id, in: nil) // Already there.
        #expect(session.history.undoCount == count)
        #expect(session.canRedo)
        session.redo()
        #expect(session.viewport.zoom == 2)
        #expect(session.isModified)
        session.undo()
        session.addBlankLayer()
        #expect(!session.canRedo)
        #expect(session.isModified)
    }

    @Test func replacementCanvasAndNestedTransactionsUndoAsOne() {
        let session = EditorSession()
        session.createDocument(width: 100, height: 200)
        session.beginEdit("Layer Setup")
        session.addBlankLayer()
        session.addBlankLayer()
        #expect(!session.canUndo)
        session.endEdit()
        #expect(session.history.undoName == "Layer Setup")
        session.undo()
        #expect(session.document?.layers.isEmpty == true)
        session.redo()
        let previous = session.document
        session.createDocument(width: 300, height: 400)
        session.undo()
        #expect(session.document == previous)
        session.redo()
        #expect(session.document?.size == CGSize(width: 300, height: 400))
    }

    @Test func historyBlockedDuringImportsAndDialogs() {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        session.isImporting = true
        session.undo()
        #expect(session.document != nil)
        session.isImporting = false
        session.showsNewDocument = true
        session.undo()
        #expect(session.document != nil)
        session.showsNewDocument = false
        session.undo()
        session.showsImporter = true
        session.redo()
        #expect(session.document == nil)
        session.showsImporter = false
        session.redo()
        #expect(session.document != nil)
    }

    @Test func batchImportIsOneEntryAndFailuresDoNotAddHistory() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = url.appendingPathExtension("missing")
        let session = EditorSession()
        await session.importImages([url, missing, url])
        #expect(session.history.undoCount == 1)
        let imported = session.document
        let selection = session.activeLayerID
        #expect(imported?.layers.count == 2)
        session.importError = nil
        session.undo()
        #expect(session.document == nil)
        session.redo()
        #expect(session.document == imported)
        #expect(session.activeLayerID == selection)
        let pixels = try #require(imported?.layers.first?.asset?.image)
        #expect(session.document?.layers.first?.asset?.image === pixels)
        await session.importImages([missing])
        #expect(session.history.undoCount == 1)
    }

    @Test func queuedImportsHaveSeparateUndoEntries() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        async let first: Void = session.importImages([url])
        async let second: Void = session.importImages([url])
        _ = await (first, second)
        #expect(session.history.undoCount == 2)
        session.undo()
        #expect(session.document?.layers.count == 1)
        session.undo()
        #expect(session.document == nil)
    }

    @Test func historyBoundsEntriesAndUniqueRetainedPixels() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try await ImageImporter.shared.decode(url)
        let history = DocumentHistory(entryLimit: 2, retainedByteLimit: 0)
        var doc = CanvasDocument(width: 64, height: 32)
        doc.layers = [ImageLayer(asset: asset, origin: .zero)]
        for name in ["A", "B", "C"] {
            history.begin("Rename", document: doc, selection: doc.layers[0].id)
            doc.layers[0].name = name
            history.end(document: doc, selection: doc.layers[0].id)
        }
        #expect(history.undoCount == 2)
        #expect(history.retainedBytes(current: doc) == 0)
        history.begin("Delete", document: doc, selection: doc.layers[0].id)
        doc.layers.removeAll()
        history.end(document: doc, selection: nil)
        // Over the byte limit, older steps go but the one just made stays undoable.
        #expect(history.undoCount == 1)
        #expect(history.undoName == "Delete")
        #expect(history.retainedBytes(current: doc) > 0)
    }

    @Test func anEditLargerThanTheByteLimitCanStillBeUndone() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try await ImageImporter.shared.decode(url)
        let history = DocumentHistory(entryLimit: 100, retainedByteLimit: 1)
        var doc = CanvasDocument(width: 64, height: 32)
        history.begin("Add", document: doc, selection: nil)
        doc.layers = [ImageLayer(asset: asset, origin: .zero)]
        history.end(document: doc, selection: doc.layers[0].id)
        history.begin("Delete", document: doc, selection: doc.layers[0].id)
        doc.layers.removeAll()
        history.end(document: doc, selection: nil)
        #expect(history.undoCount == 1)
        let restored = try #require(history.undo())
        #expect(restored.document?.layers.first?.asset?.image === asset.image)
        #expect(history.canRedo)
    }

    /// The history keeps a running count of the bytes only it holds rather than rescanning every entry on every edit.
    /// Checked against that full rescan after every step of a long run of edits that share, swap, mask, and delete
    /// images, with undo and redo between them and both limits evicting: the counts and the evictions must agree.
    @Test func retainedBytesStayEqualToAFullRecount() throws {
        func image(_ width: Int, _ height: Int, mask: Bool = false) throws -> CGImage {
            try #require(try BrushRaster.context(width: width, height: height, mask: mask).makeImage())
        }
        var pool: [ImportedImage] = []
        for width in [8, 16, 24, 40] {
            pool.append(ImportedImage(image: try image(width, 8), thumbnail: try image(2, 2), name: "\(width)"))
        }
        let masks = try (0..<2).map { _ in LayerMask(asset: ImportedImage(image: try image(12, 6, mask: true), thumbnail: try image(2, 1, mask: true), name: "Mask")) }

        // The rescan the history used to run, over a model of its entries kept by the same rules.
        func images(_ document: CanvasDocument?) -> [CGImage] {
            (document?.layers ?? []).flatMap { layer in
                [layer.asset, layer.mask?.asset].compactMap { $0 }.flatMap { [$0.image, $0.thumbnail] }
            }
        }
        func recount(_ entries: [(CanvasDocument, CanvasDocument)], current: CanvasDocument) -> Int {
            var seen = Set(images(current).map(ObjectIdentifier.init)), bytes = 0
            for entry in entries {
                for image in images(entry.0) + images(entry.1) where seen.insert(ObjectIdentifier(image)).inserted {
                    bytes += image.bytesPerRow * image.height
                }
            }
            return bytes
        }
        let entryLimit = 12, byteLimit = 6_000
        let history = DocumentHistory(entryLimit: entryLimit, retainedByteLimit: byteLimit)
        var past: [(CanvasDocument, CanvasDocument)] = [], future: [(CanvasDocument, CanvasDocument)] = []
        var doc = CanvasDocument(width: 64, height: 32)
        func trim() {
            while past.count + future.count > entryLimit
                    || (past.count + future.count > 1 && recount(past + future, current: doc) > byteLimit) {
                if !past.isEmpty { past.removeFirst() } else { future.removeFirst() }
            }
        }
        func edit(_ change: (inout CanvasDocument) -> Void) {
            let before = doc
            history.begin("Edit", document: doc, selection: nil)
            change(&doc)
            history.end(document: doc, selection: nil)
            guard doc != before else { return }
            past.append((before, doc)); future.removeAll(); trim()
        }
        var state: UInt32 = 12345
        func next(_ bound: Int) -> Int { state = state &* 1_664_525 &+ 1_013_904_223; return Int(state >> 8) % bound }
        for step in 0..<300 {
            switch next(8) {
            case 0: edit { $0.layers.append(ImageLayer(asset: pool[next(pool.count)], origin: .zero)) }
            case 1:
                // A fresh image, so some steps hold pixels no other entry shares.
                let fresh = ImportedImage(image: try image(8 + next(4) * 8, 8), thumbnail: try image(2, 2), name: "Fresh")
                pool[next(pool.count)] = fresh
                edit { $0.layers.append(ImageLayer(asset: fresh, origin: .zero)) }
            case 2: edit { if !$0.layers.isEmpty { $0.layers[next($0.layers.count)].asset = pool[next(pool.count)] } }
            case 3: edit { if !$0.layers.isEmpty { $0.layers.remove(at: next($0.layers.count)) } }
            case 4: edit { if !$0.layers.isEmpty { $0.layers[next($0.layers.count)].mask = masks[next(masks.count)] } }
            case 5: edit { if !$0.layers.isEmpty { $0.layers[next($0.layers.count)].name = "Step \(step)" } }
            case 6:
                if let snapshot = history.undo(), let entry = past.popLast() {
                    future.append(entry); doc = try #require(snapshot.document); trim()
                }
            default:
                if let snapshot = history.redo(), let entry = future.popLast() {
                    past.append(entry); doc = try #require(snapshot.document); trim()
                }
            }
            #expect(history.undoCount == past.count, "step \(step): the same entries were evicted")
            #expect(history.canRedo == !future.isEmpty, "step \(step)")
            #expect(history.retainedBytes(current: doc) == recount(past + future, current: doc), "step \(step)")
        }
        history.reset()
        #expect(history.retainedBytes(current: doc) == 0)
    }

    // MARK: Effects panel

    /// A document with one image layer, selected.
    private func effectsSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        let context = try BrushRaster.context(width: 32, height: 32, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        let image = try #require(context.makeImage())
        session.beginEdit("Add Layer")
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Square"), origin: .zero)
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        session.endEdit()
        return session
    }

    /// Every slider tick in the effects panel is an edit; one panel session must still be one undo step, or a drag
    /// pushes everything done before it out of the 100-step history.
    @Test func anEffectsPanelSessionIsOneUndoStep() throws {
        let session = try effectsSession()
        session.renameLayer(try #require(session.activeLayerID), to: "Before")
        let before = session.document
        let count = session.history.undoCount
        session.addEffect(.shadow)
        for step in 0..<150 {
            session.changeEffects { $0.shadow?.distance = CGFloat(step % 100) }
            session.changeEffects { $0.shadow?.opacity = Double(step % 10) / 10 }
        }
        session.previewEffectColor()
        session.finishEffectsEditing(commit: true)
        #expect(session.activeLayer?.effects?.shadow?.distance == 49)
        #expect(session.history.undoCount == count + 1)
        #expect(session.history.undoName == "Add Drop Shadow")
        session.undo()
        #expect(session.document == before)
        #expect(session.activeLayer?.name == "Before", "the edit before the panel is still there")

        // Opening the panel again on the same effect is a step of its own.
        session.redo()
        let committed = session.document
        session.selectEffect(.shadow, on: try #require(session.activeLayerID), editing: true)
        session.changeEffects { $0.shadow?.blur = 7 }
        session.changeEffects { $0.shadow?.blur = 9 }
        session.finishEffectsEditing(commit: true)
        #expect(session.history.undoCount == count + 2)
        #expect(session.history.undoName == "Edit Drop Shadow")
        session.undo()
        #expect(session.document == committed)
    }

    @Test func cancellingAnEffectsPanelLeavesNothingToUndo() throws {
        let session = try effectsSession()
        session.history.markSaved()
        let before = session.document
        let count = session.history.undoCount
        session.addEffect(.stroke)
        session.changeEffects { $0.stroke?.size = 12 }
        session.finishEffectsEditing(commit: false)
        #expect(session.document == before)
        #expect(session.history.undoCount == count)
        #expect(!session.isModified)
    }

    // MARK: Painted layers

    /// A painted layer's snapshots share their base and every tile they didn't touch; the history counts those once,
    /// not the whole layer for every step.
    @Test func paintSnapshotsAreCountedByTheTilesTheyShare() throws {
        let side = 1024
        let baseContext = try BrushRaster.context(width: side, height: side, mask: false)
        baseContext.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        baseContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let baseImage = try #require(baseContext.makeImage())
        let thumbnail = try #require(try BrushRaster.context(width: 2, height: 2, mask: false).makeImage())
        let original = ImportedImage(image: baseImage, thumbnail: thumbnail, name: "Photo")
        func tile(_ x: Int, _ y: Int) throws -> BrushPatch {
            let context = try BrushRaster.context(width: 256, height: 256, mask: false)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            return BrushPatch(rect: CGRect(x: x, y: y, width: 256, height: 256), image: try #require(context.makeImage()))
        }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        func painted(_ source: ImportedImage, _ patch: BrushPatch) throws -> ImportedImage {
            let raster = RasterSnapshot.replacing(source: source, sourceRect: bounds, patches: [patch], crop: bounds)
            return ImportedImage(image: try raster.makeImage(), thumbnail: thumbnail, name: "Photo", raster: raster)
        }
        let first = try painted(original, try tile(0, 0))
        let second = try painted(first, try tile(512, 512))
        let third = try painted(second, try tile(256, 768))
        #expect(third.raster?.base === baseImage && third.raster?.patches.count == 3)

        let history = DocumentHistory(entryLimit: 100, retainedByteLimit: 256 * 1024 * 1024)
        var doc = CanvasDocument(width: side, height: side)
        doc.layers = [ImageLayer(asset: original, origin: .zero)]
        let id = doc.layers[0].id
        for asset in [first, second, third] {
            history.begin("Brush", document: doc, selection: id)
            doc.layers[0].asset = asset
            history.end(document: doc, selection: id)
        }
        history.begin("Delete", document: doc, selection: id)
        doc.layers.removeAll()
        history.end(document: doc, selection: nil)
        // The base and three tiles (each tile cropped from nothing, so counted at its own size), and the thumbnail.
        let tileBytes = 256 * 256 * 4
        let expected = baseImage.bytesPerRow * side + 3 * tileBytes + thumbnail.bytesPerRow * thumbnail.height
        #expect(history.retainedBytes(current: doc) == expected)
        #expect(history.retainedBytes(current: doc) < 2 * side * side * 4, "not a full layer per step")
        // None of the snapshots had to make its whole image to be counted.
        #expect([first, second, third].allSatisfy { $0.raster?.hasMaterializedPixels == false })
    }
}
