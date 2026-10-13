import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct ProjectTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorProjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func projectRoundTripSurvivesSourceRemovalAndPackageMove() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        let session = EditorSession()
        await session.importImages([source])
        try FileManager.default.removeItem(at: source)
        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.origin = CGPoint(x: -27.5, y: 88.25)
        transform.size = CGSize(width: 123, height: 47)
        transform.rotation = 38
        transform.flipX = true
        transform.flipY = true
        transform.sampling = .nearest
        session.previewTransform(transform)
        session.commitTransform()
        let imageID = try #require(session.activeLayerID)
        session.renameLayer(imageID, to: "Paint & sky 🌤")
        session.toggleLayerVisibility(imageID)
        session.addBlankLayer()
        let before = try #require(session.projectSnapshot())
        let original = root.appendingPathComponent("Original.comp")
        let moved = root.appendingPathComponent("Moved.comp")
        try await ProjectStore.shared.save(before, to: original)
        try FileManager.default.moveItem(at: original, to: moved)
        let loaded = try await ProjectStore.shared.load(from: moved)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: moved)
        // Reloading creates new CGImage identities; compare persisted metadata here,
        // and decoded source pixels below, instead of in-memory snapshot identity.
        #expect(reopened.document?.id == session.document?.id)
        #expect(reopened.document?.size == session.document?.size)
        #expect(reopened.document?.resolution == session.document?.resolution)
        #expect(reopened.document?.layers.map(\.id) == session.document?.layers.map(\.id))
        #expect(reopened.document?.layers.map(\.name) == session.document?.layers.map(\.name))
        #expect(reopened.document?.layers.map(\.isVisible) == session.document?.layers.map(\.isVisible))
        #expect(reopened.document?.layers.map(\.transform) == session.document?.layers.map(\.transform))
        #expect(reopened.activeLayerID == session.activeLayerID)
        #expect(reopened.document?.layers.last?.asset == nil)
        #expect(!reopened.isModified)
        #expect(!reopened.canUndo)
        let image = try #require(loaded.images[imageID]?.image)
        #expect(image.width == 64 && image.height == 32)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).redComponent > 0.95)
        #expect(try #require(bitmap.colorAt(x: 63, y: 0)).alphaComponent == 0)
        reopened.renameLayer(imageID, to: "Edited")
        #expect(reopened.isModified)
        reopened.undo()
        #expect(!reopened.isModified)
    }

    /// Folders took an opacity of their own in 1.1.6, but project validation still demanded that
    /// every folder be fully opaque, so a document with a dimmed folder could not be saved at all.
    @Test func aDimmedFolderSavesAndReopens() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        await session.importImages([try ImageImportTests().fixture(.png)])
        let child = try #require(session.activeLayerID)
        session.selectLayers([child], primary: child)
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        session.selectLayers([folder], primary: folder)
        session.setLayerOpacity(0.5)
        #expect(session.document?.layers.first { $0.id == folder }?.opacity == 0.5)

        let url = root.appendingPathComponent("Dimmed.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let saved = try #require(loaded.manifest.layers.first { $0.isGroup == true })
        #expect(saved.opacity == 0.5)
    }

    @Test func overwriteReplacesPackageAndDropsRemovedAssets() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let destination = root.appendingPathComponent("Overwrite.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: destination)
        session.deleteActiveLayer()
        session.addBlankLayer()
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: destination)
        let loaded = try await ProjectStore.shared.load(from: destination)
        #expect(loaded.images.isEmpty)
        #expect(loaded.manifest.layers.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("images").path).isEmpty)
    }

    @Test func failedSavePreservesPreviouslySavedPackage() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Safe.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let original = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        var invalid = snapshot.manifest
        invalid.version = 99
        await #expect(throws: ProjectError.version(99)) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: invalid, images: [:]), to: url)
        }
        #expect(try Data(contentsOf: url.appendingPathComponent("manifest.json")) == original)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.count == 1)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        // Foundation's own error, which names the folder that couldn't be written.
        let failure = await #expect(throws: CocoaError.self) {
            try await ProjectStore.shared.save(snapshot, to: blocker.appendingPathComponent("CannotSave.comp"))
        }
        #expect(failure?.isFileError == true)
        #expect(try Data(contentsOf: url.appendingPathComponent("manifest.json")) == original)
    }

    @Test func unsupportedCorruptAndUnsafeMetadataAreRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Invalid.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let metadata = url.appendingPathComponent("manifest.json")
        var future = snapshot.manifest
        future.version = 42
        try JSONEncoder().encode(future).write(to: metadata)
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Future version opened")
        } catch ProjectError.version(let version) { #expect(version == 42) }
        // A filename that isn't the layer's own is refused before any file is looked at; paths that reach
        // outside the package through links are covered by linkedAssetsAreRefusedWhereverTheyPoint.
        let record = try #require(snapshot.manifest.layers.first)
        var unsafe = snapshot.manifest
        unsafe.layers = [ProjectLayerRecord(id: record.id, name: record.name, isVisible: true,
            transform: record.transform, imageFile: "../../outside.png")]
        try JSONEncoder().encode(unsafe).write(to: metadata)
        await #expect(throws: ProjectError.invalid) { try await ProjectStore.shared.load(from: url) }
        try Data("not json".utf8).write(to: metadata)
        await #expect(throws: ProjectError.invalid) { try await ProjectStore.shared.load(from: url) }
        try FileManager.default.removeItem(at: metadata)
        await #expect(throws: ProjectError.invalid) { try await ProjectStore.shared.load(from: url) }
        #expect(session.document?.layers.count == 1)
    }

    @Test func missingEmbeddedImageIsRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Missing.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let filename = try #require(snapshot.manifest.layers.first?.imageFile)
        let asset = url.appendingPathComponent("images").appendingPathComponent(filename)
        try FileManager.default.removeItem(at: asset)
        await #expect(throws: ProjectError.missingImage) { try await ProjectStore.shared.load(from: url) }
        // A folder (or any other non-file) where the image should be is just as missing.
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: false)
        await #expect(throws: ProjectError.missingImage) { try await ProjectStore.shared.load(from: url) }
    }

    // MARK: Hostile packages

    /// A saved one-image project, and where its manifest and image are, for tests that then damage it.
    private func savedImageProject(in root: URL) async throws -> (url: URL, manifest: ProjectManifest, image: URL) {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Hostile.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let filename = try #require(snapshot.manifest.layers.first?.imageFile)
        return (url, snapshot.manifest, url.appendingPathComponent("images").appendingPathComponent(filename))
    }

    private func write(_ manifest: ProjectManifest, into url: URL) throws {
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
    }

    @Test func oversizedCanvasAndTooManyLayersAreTooLarge() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedImageProject(in: root)
        for (width, height) in [(30_001, 10), (10, 30_001), (0, 10)] {
            let manifest = ProjectManifest(documentID: UUID(), width: width, height: height, activeLayerID: nil,
                                           layers: project.manifest.layers)
            try write(manifest, into: project.url)
            await #expect(throws: ProjectError.tooLarge, "\(width) × \(height)") { try await ProjectStore.shared.load(from: project.url) }
        }
        // Blank layers carry no image, so only the count is over.
        let blank = (0...10_000).map { index in
            ProjectLayerRecord(id: UUID(), name: "Layer \(index)", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)), imageFile: nil)
        }
        var crowded = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: nil, layers: blank)
        try write(crowded, into: project.url)
        await #expect(throws: ProjectError.tooLarge) { try await ProjectStore.shared.load(from: project.url) }
        crowded.layers.removeLast()
        try write(crowded, into: project.url)
        #expect(try await ProjectStore.shared.load(from: project.url).manifest.layers.count == 10_000)
    }

    /// Two 60-megapixel images: each is within the per-image limits, but together they pass the 100-megapixel
    /// budget, and the second is refused from its header before it is decoded.
    @Test func imagesPastTheHundredMegapixelBudgetAreTooLarge() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedImageProject(in: root)
        let context = try #require(CGContext(data: nil, width: 10_000, height: 6_000, bitsPerComponent: 8, bytesPerRow: 10_000,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let large = try #require(context.makeImage())
        let first = try #require(project.manifest.layers.first)
        let id = UUID()
        var manifest = project.manifest
        manifest.layers.append(ProjectLayerRecord(id: id, name: "Second", isVisible: true, transform: first.transform,
                                                  imageFile: "\(id.uuidString).png"))
        let images = project.image.deletingLastPathComponent()
        for record in manifest.layers {
            let file = images.appendingPathComponent(try #require(record.imageFile))
            try? FileManager.default.removeItem(at: file)
            let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, large, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        try write(manifest, into: project.url)
        await #expect(throws: ProjectError.tooLarge) { try await ProjectStore.shared.load(from: project.url) }
        manifest.layers.removeLast()
        try write(manifest, into: project.url)
        #expect(try await ProjectStore.shared.load(from: project.url).images.count == 1)
    }

    /// Sizes are read from the file system before anything is read, so sparse files stand in for huge ones.
    @Test func oversizedAssetAndManifestAreTooLarge() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedImageProject(in: root)
        let handle = try FileHandle(forWritingTo: project.image)
        try handle.truncate(atOffset: 512 * 1024 * 1024 + 1)
        try handle.close()
        await #expect(throws: ProjectError.tooLarge) { try await ProjectStore.shared.load(from: project.url) }
        let manifest = try FileHandle(forWritingTo: project.url.appendingPathComponent("manifest.json"))
        try manifest.truncate(atOffset: 4 * 1024 * 1024 + 1)
        try manifest.close()
        await #expect(throws: ProjectError.tooLarge) { try await ProjectStore.shared.load(from: project.url) }
    }

    /// A link is refused wherever it points: outside the package (the image folder swapped for a link to
    /// another folder holding a same-named file — a real path traversal), or to another file inside it.
    @Test func linkedAssetsAreRefusedWhereverTheyPoint() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedImageProject(in: root)
        let images = project.image.deletingLastPathComponent()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: project.image, to: outside.appendingPathComponent(project.image.lastPathComponent))
        let kept = root.appendingPathComponent("kept-images")
        try FileManager.default.moveItem(at: images, to: kept)
        try FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
        await #expect(throws: ProjectError.unsafeFile) { try await ProjectStore.shared.load(from: project.url) }

        try FileManager.default.removeItem(at: images)
        try FileManager.default.moveItem(at: kept, to: images)
        #expect(try await ProjectStore.shared.load(from: project.url).images.count == 1)
        let inside = images.appendingPathComponent("elsewhere.png")
        try FileManager.default.moveItem(at: project.image, to: inside)
        try FileManager.default.createSymbolicLink(at: project.image, withDestinationURL: inside)
        await #expect(throws: ProjectError.unsafeFile) { try await ProjectStore.shared.load(from: project.url) }
        try FileManager.default.removeItem(at: project.image)
        try FileManager.default.createSymbolicLink(at: project.image, withDestinationURL: outside.appendingPathComponent(project.image.lastPathComponent))
        await #expect(throws: ProjectError.unsafeFile) { try await ProjectStore.shared.load(from: project.url) }
    }

    /// Effects and shapes are only drawn at render time, so a damaged one has to be caught on open rather
    /// than opening fine and failing the first export.
    @Test func damagedEffectsAndShapesAreRejectedOnOpen() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedImageProject(in: root)
        var manifest = project.manifest
        manifest.layers[0].effects = LayerEffects(stroke: StrokeEffect(size: 4))
        try write(manifest, into: project.url)
        #expect(try await ProjectStore.shared.load(from: project.url).manifest.layers[0].effects?.stroke?.size == 4)
        for effects in [LayerEffects(stroke: StrokeEffect(size: 9_999)), LayerEffects(shadow: ShadowEffect(opacity: 2)),
                        LayerEffects(outerGlow: OuterGlowEffect(red: -1))] {
            manifest.layers[0].effects = effects
            try write(manifest, into: project.url)
            await #expect(throws: ProjectError.invalid) { try await ProjectStore.shared.load(from: project.url) }
        }
        manifest.layers[0].effects = nil
        let shape = LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 4)
        manifest.layers[0].shape = shape
        try write(manifest, into: project.url)
        #expect(try await ProjectStore.shared.load(from: project.url).manifest.layers[0].shape == shape)
        var damaged = [shape, shape, shape]
        damaged[0].cornerRadius = -3
        damaged[1].green = 4
        damaged[2].start = CGPoint(x: 0.5, y: 7)
        for style in damaged {
            manifest.layers[0].shape = style
            try write(manifest, into: project.url)
            await #expect(throws: ProjectError.invalid) { try await ProjectStore.shared.load(from: project.url) }
        }
    }

    @Test func projectOperationsBlockEditsAndQueueImageImports() async throws {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let before = session.document
        session.isProjectBusy = true
        session.deleteActiveLayer()
        session.createDocument(width: 400, height: 400)
        session.undo()
        #expect(session.document == before)
        let pending = Task { await session.importImages([source]) }
        await Task.yield()
        #expect(!session.isImporting)
        session.isProjectBusy = false
        await pending.value
        #expect(session.document?.layers.count == 2)
        session.clearProject()
        #expect(session.document == nil && session.projectURL == nil)
        #expect(!session.isModified && !session.canUndo)
    }

    @Test func projectRoundTripPreservesAllLayerEffects() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)

        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 8, red: 0.1, green: 0.8, blue: 0.2, opacity: 0.9, inside: false)
        effects.shadow = ShadowEffect(angle: 45, distance: 15, blur: 10, red: 0.2, green: 0.2, blue: 0.3, opacity: 0.75)
        effects.colorOverlay = ColorOverlayEffect(red: 0.9, green: 0.1, blue: 0.4, opacity: 0.65)
        effects.innerShadow = InnerShadowEffect(angle: 135, distance: 6, blur: 4, red: 0.05, green: 0.05, blue: 0.05, opacity: 0.5)
        session.setEffects(effects, on: id)

        #expect(session.activeLayer?.effects == effects)

        let snapshot = try #require(session.projectSnapshot())
        let record = try #require(snapshot.manifest.layers.first { $0.id == id })
        #expect(record.effects == effects)

        let fileURL = root.appendingPathComponent("EffectsProject.comp")
        try await ProjectStore.shared.save(snapshot, to: fileURL)

        let loaded = try await ProjectStore.shared.load(from: fileURL)
        let loadedRecord = try #require(loaded.manifest.layers.first { $0.id == id })
        #expect(loadedRecord.effects == effects)

        let reopened = EditorSession()
        reopened.installProject(loaded, from: fileURL)

        let restored = try #require(reopened.document?.layers.first { $0.id == id })
        #expect(restored.effects == effects)

        // Verify individual effect parameters survive round trip
        let stroke = try #require(restored.effects?.stroke)
        #expect(stroke.size == 8)
        #expect(!stroke.inside)
        #expect(stroke.opacity == 0.9)
        #expect(abs(stroke.red - 0.1) < 0.001 && abs(stroke.green - 0.8) < 0.001)

        let shadow = try #require(restored.effects?.shadow)
        #expect(shadow.angle == 45)
        #expect(shadow.distance == 15)
        #expect(shadow.blur == 10)
        #expect(shadow.opacity == 0.75)

        let colorOverlay = try #require(restored.effects?.colorOverlay)
        #expect(colorOverlay.opacity == 0.65)
        #expect(abs(colorOverlay.red - 0.9) < 0.001 && abs(colorOverlay.blue - 0.4) < 0.001)

        let innerShadow = try #require(restored.effects?.innerShadow)
        #expect(innerShadow.angle == 135)
        #expect(innerShadow.distance == 6)
        #expect(innerShadow.blur == 4)
        #expect(innerShadow.opacity == 0.5)
    }

    @Test func layerEffectsAreRenderedInExport() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 80, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let redImage = try #require(context.makeImage())

        let session = EditorSession()
        session.createDocument(width: 60, height: 60)
        session.insert(ImportedImage(image: redImage, thumbnail: redImage, name: "Square"))

        let id = try #require(session.activeLayerID)
        session.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 20, y: 20), size: CGSize(width: 20, height: 20))

        // Before adding effects, area outside the layer is transparent
        let unstyledSnapshot = try #require(session.projectSnapshot())
        let unstyledRaster = try await ImageExporter.shared.render(unstyledSnapshot)
        let unstyledBitmap = NSBitmapImageRep(cgImage: unstyledRaster.image)
        #expect(try #require(unstyledBitmap.colorAt(x: 15, y: 30)).alphaComponent == 0)
        #expect(try #require(unstyledBitmap.colorAt(x: 30, y: 30)).redComponent > 0.9)

        // Apply outside green stroke of width 6px
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 6, red: 0, green: 1, blue: 0, opacity: 1, inside: false)
        session.setEffects(effects, on: id)

        let styledSnapshot = try #require(session.projectSnapshot())
        #expect(styledSnapshot.manifest.layers.first?.effects != nil)

        let styledRaster = try await ImageExporter.shared.render(styledSnapshot)
        let styledBitmap = NSBitmapImageRep(cgImage: styledRaster.image)

        // Pixel at (15, 30) is 5px to the left of the layer (x=20..40), inside the 6px stroke
        let strokePixel = try #require(styledBitmap.colorAt(x: 15, y: 30))
        #expect(strokePixel.greenComponent > 0.9)
        #expect(strokePixel.alphaComponent > 0.9)

        // The layer itself at (30, 30) remains red
        let centerPixel = try #require(styledBitmap.colorAt(x: 30, y: 30))
        #expect(centerPixel.redComponent > 0.9)
    }
}
