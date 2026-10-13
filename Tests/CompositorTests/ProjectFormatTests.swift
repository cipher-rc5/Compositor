import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

/// What a project file holds, through `ProjectStore` save and open rather than in-memory JSON: the newest
/// records, files written in older format versions, damaged packages, failed writes, and reuse of
/// unchanged assets between saves.
@MainActor
struct ProjectFormatTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorProjectFormatTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func color(_ width: Int, _ height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> ImportedImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Color")
    }

    private func gray(_ width: Int, _ height: Int, value: CGFloat) throws -> ImportedImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Mask")
    }

    private func colorAt(_ image: CGImage?, x: Int, y: Int) throws -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: try #require(image))
        return try #require(bitmap.colorAt(x: x, y: y))
    }

    private func graySample(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return Int((try #require(bitmap.colorAt(x: x, y: y)).whiteComponent * 255).rounded())
    }

    // MARK: Version 9 records

    private struct Rich {
        let session: EditorSession
        let photo: UUID, gaussian: UUID, motion: UUID, noise: UUID
        let gaussianSettings: LayerAdjustment, motionSettings: LayerAdjustment, noiseSettings: LayerAdjustment
        let effects: LayerEffects
        let placement: LayerTransform
    }

    /// A pixel layer with Inner and Outer Glow and a mask moved apart from it and unlinked, under the three
    /// adjustment kinds version 9 added.
    private func richSession() throws -> Rich {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        var effects = LayerEffects()
        effects.outerGlow = OuterGlowEffect(enabled: false, size: 12, red: 0.25, green: 0.5, blue: 1, opacity: 0.4)
        effects.innerGlow = InnerGlowEffect(size: 3.5, red: 1, green: 0.75, blue: 0, opacity: 0.9)
        let placement = LayerTransform(origin: CGPoint(x: 6, y: -2), size: CGSize(width: 12, height: 9), rotation: 30,
                                       flipX: true, flipY: false, sampling: .smooth)
        let photo = ImageLayer(id: UUID(), asset: try color(20, 10, red: 1, green: 0, blue: 0), name: "Photo", isVisible: true,
                               transform: LayerTransform(origin: CGPoint(x: 4, y: 5), size: CGSize(width: 20, height: 10)),
                               mask: LayerMask(asset: try gray(10, 5, value: 0.5), isEnabled: true, placement: placement, isLinked: false),
                               effects: effects)
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: 40, height: 30))
        var gaussianSettings = LayerAdjustment(kind: .gaussianBlur)
        gaussianSettings.blurRadius = 37.5
        var motionSettings = LayerAdjustment(kind: .motionBlur)
        motionSettings.motionAngle = -42
        motionSettings.motionDistance = 1_250
        var noiseSettings = LayerAdjustment(kind: .addNoise)
        noiseSettings.noiseAmount = 123.4
        noiseSettings.noiseGaussian = true
        noiseSettings.noiseMonochromatic = true
        noiseSettings.noiseSeed = 4_000_000_000
        let layers = [photo] + [("Gaussian Blur", gaussianSettings), ("Motion Blur", motionSettings), ("Add Noise", noiseSettings)].map {
            ImageLayer(id: UUID(), asset: nil, name: $0.0, isVisible: true, transform: canvas, adjustment: $0.1)
        }
        session.document?.layers = layers
        session.selectLayer(layers[0].id)
        return Rich(session: session, photo: layers[0].id, gaussian: layers[1].id, motion: layers[2].id, noise: layers[3].id,
                    gaussianSettings: gaussianSettings, motionSettings: motionSettings, noiseSettings: noiseSettings,
                    effects: effects, placement: placement)
    }

    @Test func versionNineAdjustmentsGlowsAndMaskPlacementSurviveSaveAndOpen() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let rich = try richSession()
        let url = root.appendingPathComponent("Rich.comp")
        try await ProjectStore().save(try #require(rich.session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore().load(from: url)
        #expect(loaded.manifest.version == 9)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        let layers = try #require(reopened.document?.layers)
        #expect(layers.map(\.id) == [rich.photo, rich.gaussian, rich.motion, rich.noise])
        #expect(layers[1].adjustment == rich.gaussianSettings && layers[1].asset == nil)
        #expect(layers[2].adjustment == rich.motionSettings)
        #expect(layers[3].adjustment == rich.noiseSettings)
        #expect(layers[3].adjustment?.noiseSeed == 4_000_000_000)

        let photo = layers[0]
        #expect(photo.effects == rich.effects)
        #expect(photo.effects?.outerGlow?.isEnabled == false && photo.effects?.innerGlow?.isEnabled == true)
        let mask = try #require(photo.mask)
        #expect(mask.placement == rich.placement && !mask.isLinked && mask.isEnabled)
        #expect(mask.asset.image.width == 10 && mask.asset.image.height == 5)
        #expect(try graySample(mask.asset.image, x: 3, y: 2) == 128)
        #expect(photo.asset?.image.width == 20 && photo.transform == LayerTransform(origin: CGPoint(x: 4, y: 5), size: CGSize(width: 20, height: 10)))
        #expect(reopened.projectSnapshot()?.manifest.layers.map(\.maskLinked) == [false, nil, nil, nil])
    }

    /// The same records in a file that declares version 8 are refused rather than half-read.
    @Test func versionNineAdjustmentsAreRefusedInAnOlderVersion() async throws {
        let rich = try richSession()
        var manifest = try #require(rich.session.projectSnapshot()).manifest
        manifest.version = 8
        #expect(throws: ProjectError.invalid) { try ProjectStore.validate(manifest) }
    }

    // MARK: Files written in older format versions

    /// The test bundle's copy of a checked-in fixture file (Tests/CompositorTests/Fixtures). The manifests there
    /// were written by hand to docs/project-format.md for the version each declares, as an older build would
    /// have saved them, and must not be regenerated by this build: they are what keeps old files opening.
    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: FixtureBundle.self)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return try #require(bundle.url(forResource: base, withExtension: ext)
                            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Fixtures"), "\(name)")
    }

    /// Lays a checked-in manifest and the images it names out as a package, as an older build saved it.
    private func package(_ manifestName: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent((manifestName as NSString).deletingPathExtension + ".comp")
        let images = url.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let manifestFile = try fixture(manifestName)
        try FileManager.default.copyItem(at: manifestFile, to: url.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestFile))
        for name in manifest.layers.flatMap({ [$0.imageFile, $0.maskFile].compactMap { $0 } }) {
            try FileManager.default.copyItem(at: try fixture(name), to: images.appendingPathComponent(name))
        }
        return url
    }

    private func id(_ value: String) throws -> UUID { try #require(UUID(uuidString: value)) }

    @Test func aVersionSixProjectOpensWithFolderMasksAndClippingMasks() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try package("ProjectV6.json", in: root)
        let loaded = try await ProjectStore().load(from: url)
        #expect(loaded.manifest.version == 6 && loaded.manifest.resolution == 144 && loaded.manifest.guides == nil)
        let session = EditorSession()
        session.installProject(loaded, from: url)
        let document = try #require(session.document)
        #expect(document.width == 8 && document.height == 6 && document.resolution == 144)
        #expect(document.layers.map(\.name) == ["Background", "Group", "Red", "Clipped"])
        let folder = document.layers[1], red = document.layers[2], clipped = document.layers[3]
        let folderID = try id("6A000000-0000-4000-8000-000000000002")
        #expect(folder.isGroup && folder.asset == nil && folder.id == folderID)
        let folderMask = try #require(folder.mask)
        #expect(folderMask.isEnabled && folderMask.isLinked && folderMask.placement == nil)
        #expect(try graySample(folderMask.asset.image, x: 1, y: 1) == 255 && graySample(folderMask.asset.image, x: 6, y: 1) == 0)
        #expect(red.parentID == folder.id && red.opacity == 0.75 && red.blendMode == .multiply)
        #expect(red.transform.rotation == 90 && red.transform.flipX && red.transform.origin == CGPoint(x: 2, y: 1))
        #expect(red.mask?.isEnabled == false)
        #expect(clipped.maskSourceID == red.id && !clipped.isVisible && clipped.transform.sampling == .nearest)
        #expect(session.activeLayerID == red.id)
        let pixel = try colorAt(clipped.asset?.image, x: 0, y: 3)
        #expect(pixel.alphaComponent == 0)

        // Saved again, it is a version 9 file holding the same document.
        let resaved = root.appendingPathComponent("Resaved.comp")
        try await ProjectStore().save(try #require(session.projectSnapshot()), to: resaved)
        let again = try await ProjectStore().load(from: resaved)
        #expect(again.manifest.version == 9)
        let reopened = EditorSession()
        reopened.installProject(again, from: resaved)
        #expect(reopened.document?.layers.map(\.id) == document.layers.map(\.id))
        #expect(reopened.document?.layers.map(\.transform) == document.layers.map(\.transform))
        #expect(reopened.document?.layers.map(\.maskSourceID) == document.layers.map(\.maskSourceID))
        #expect(reopened.document?.layers.map { $0.mask?.isEnabled } == document.layers.map { $0.mask?.isEnabled })
    }

    @Test func aVersionEightProjectOpensWithGuidesAdjustmentsAndAPlacedMask() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try package("ProjectV8.json", in: root)
        let loaded = try await ProjectStore().load(from: url)
        #expect(loaded.manifest.version == 8 && loaded.manifest.resolution == nil)
        let session = EditorSession()
        session.installProject(loaded, from: url)
        let document = try #require(session.document)
        #expect(document.resolution == 72)
        #expect(document.guides.map(\.axis) == [.horizontal, .vertical] && document.guides.map(\.position) == [2.5, -4])
        #expect(document.layers.map(\.name) == ["Photo", "Dimmed", "Levels 1", "Stroked"])
        let photo = document.layers[0], folder = document.layers[1], levels = document.layers[2], stroked = document.layers[3]
        let mask = try #require(photo.mask)
        #expect(!mask.isLinked && mask.placement == LayerTransform(origin: CGPoint(x: 2, y: 3), size: CGSize(width: 5, height: 5)))
        #expect(try graySample(mask.asset.image, x: 2, y: 2) == 200)
        #expect(folder.isGroup && folder.opacity == 0.5)
        let adjustment = try #require(levels.adjustment)
        #expect(adjustment.kind == .levels && levels.asset == nil && levels.parentID == folder.id)
        #expect(adjustment.levels.ranges[0] == LevelRange(black: 10, gamma: 1.5, white: 245))
        #expect(adjustment.levels.ranges[1...].allSatisfy { $0 == LevelRange() })
        #expect(stroked.effects == LayerEffects(stroke: StrokeEffect(size: 2, red: 1, green: 0, blue: 0, opacity: 1, inside: false)))
        #expect(stroked.effects?.stroke?.isEnabled == true)
        #expect(session.activeLayerID == levels.id)
        let corner = try colorAt(photo.asset?.image, x: 0, y: 0)
        #expect(corner.redComponent < 0.01 && corner.alphaComponent == 1)
    }

    // MARK: Damaged packages

    private func savedPackage(in root: URL) async throws -> (url: URL, manifest: ProjectManifest) {
        let session = EditorSession()
        session.createDocument(width: 20, height: 10)
        let layer = ImageLayer(asset: try color(8, 4, red: 0, green: 1, blue: 0), origin: CGPoint(x: 1, y: 1))
        session.document?.layers = [layer]
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Damaged.comp")
        try await ProjectStore().save(snapshot, to: url)
        return (url, snapshot.manifest)
    }

    private func manifestText(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("manifest.json"), encoding: .utf8)
    }

    @Test func nonFiniteTransformsAreRefused() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedPackage(in: root)
        let original = try manifestText(project.url)
        let origin = "\"origin\":[1,1]"
        #expect(original.contains(origin))
        // JSON has no NaN or infinity; a file can still spell them, or a number too large for a Double.
        for spelling in ["[NaN,1]", "[1,Infinity]", "[1e999,1]", "[\"nan\",1]"] {
            try original.replacingOccurrences(of: origin, with: "\"origin\":\(spelling)")
                .write(to: project.url.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            await #expect(throws: ProjectError.invalid, "\(spelling)") { try await ProjectStore().load(from: project.url) }
        }
        // In memory a transform can hold them; neither validation nor Save lets one through.
        for value in [CGFloat.nan, .infinity, -.infinity] {
            var manifest = project.manifest
            let record = manifest.layers[0]
            var transform = record.transform
            transform.rotation = value
            manifest.layers[0] = ProjectLayerRecord(id: record.id, name: record.name, isVisible: true, transform: transform,
                                                    imageFile: record.imageFile)
            #expect(throws: ProjectError.invalid) { try ProjectStore.validate(manifest) }
        }
    }

    @Test func duplicateLayerIDsAreRefused() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedPackage(in: root)
        var manifest = project.manifest
        let record = manifest.layers[0]
        manifest.layers.append(ProjectLayerRecord(id: record.id, name: "Twin", isVisible: true, transform: record.transform,
                                                  imageFile: nil))
        try JSONEncoder().encode(manifest).write(to: project.url.appendingPathComponent("manifest.json"))
        await #expect(throws: ProjectError.invalid) { try await ProjectStore().load(from: project.url) }
        // A folder sharing a layer's ID is just as ambiguous.
        manifest.layers[1] = ProjectLayerRecord(id: record.id, name: "Folder", isVisible: true, transform: record.transform,
                                                imageFile: nil, isGroup: true)
        try JSONEncoder().encode(manifest).write(to: project.url.appendingPathComponent("manifest.json"))
        await #expect(throws: ProjectError.invalid) { try await ProjectStore().load(from: project.url) }
    }

    @Test func corruptImagesAreRefused() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await savedPackage(in: root)
        let file = project.url.appendingPathComponent("images").appendingPathComponent(try #require(project.manifest.layers[0].imageFile))
        let png = try Data(contentsOf: file)
        // Not an image at all; a JPEG under the PNG's name; and a PNG cut off inside its header.
        let jpeg = try #require(NSBitmapImageRep(data: png)?.representation(using: .jpeg, properties: [:]))
        for (label, bytes) in [("garbage", Data("not a png".utf8)), ("jpeg", jpeg), ("truncated header", png.prefix(20))] {
            try bytes.write(to: file)
            await #expect(throws: ProjectError.missingImage, "\(label)") { try await ProjectStore().load(from: project.url) }
        }
        try png.write(to: file)
        #expect(try await ProjectStore().load(from: project.url).images.count == 1)
    }

    // MARK: Failed writes

    @Test func aSaveThatCannotBeWrittenLeavesThePreviousFileAndReports() async throws {
        let root = try temporaryFolder()
        let folder = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try await savedPackage(in: folder)
        let original = try Data(contentsOf: project.url.appendingPathComponent("manifest.json"))
        let session = EditorSession()
        session.installProject(try await ProjectStore().load(from: project.url), from: project.url)
        session.addBlankLayer()
        let changed = try #require(session.projectSnapshot())
        // The package can't be replaced once its folder is read-only: the staged copy has nowhere to go.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        await #expect(throws: (any Error).self) { try await ProjectStore().save(changed, to: project.url) }
        #expect(try Data(contentsOf: project.url.appendingPathComponent("manifest.json")) == original)
        #expect(try await ProjectStore().load(from: project.url).manifest.layers.count == 1)

        // An image that can't be encoded fails before anything is written.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let missing = ProjectSnapshot(manifest: changed.manifest, images: [:])
        await #expect(throws: ProjectError.missingImage) { try await ProjectStore().save(missing, to: project.url) }
        #expect(try Data(contentsOf: project.url.appendingPathComponent("manifest.json")) == original)
    }

    @Test func anExportThatCannotBeWrittenReports() async throws {
        let root = try temporaryFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let session = EditorSession()
        session.createDocument(width: 20, height: 10)
        session.document?.layers = [ImageLayer(asset: try color(8, 4, red: 1, green: 0, blue: 0), origin: .zero)]
        let snapshot = try #require(session.projectSnapshot())
        let destination = root.appendingPathComponent("Export.png")
        try await ImageExporter.shared.exportPNG(snapshot, to: destination)
        let written = try Data(contentsOf: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) { try await ImageExporter.shared.exportPNG(snapshot, to: destination) }
        await #expect(throws: (any Error).self) {
            try await ImageExporter.shared.exportPNG(snapshot, to: root.appendingPathComponent("New.png"))
        }
        #expect(try Data(contentsOf: destination) == written)
    }

    // MARK: The manifest budget

    /// Every field within its own limit, but 300 names of 16 KiB come to more than the 4 MiB a manifest may be.
    @Test func aManifestPastFourMegabytesIsRefusedByValidationNotJustBySave() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = String(repeating: "n", count: 16_384)
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        var manifest = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: nil, layers: (0..<300).map { _ in
            ProjectLayerRecord(id: UUID(), name: name, isVisible: true, transform: transform, imageFile: nil)
        })
        #expect(throws: ProjectError.manifestTooLarge) { try ProjectStore.validate(manifest) }
        let url = root.appendingPathComponent("Long names.comp")
        await #expect(throws: ProjectError.manifestTooLarge) {
            try await ProjectStore().save(ProjectSnapshot(manifest: manifest, images: [:]), to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Just under the budget it validates, and then it saves and opens.
        manifest.layers.removeLast(300 - 250)
        try ProjectStore.validate(manifest)
        try await ProjectStore().save(ProjectSnapshot(manifest: manifest, images: [:]), to: url)
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("manifest.json").path)[.size] as? Int)
        #expect(size <= ProjectStore.maximumManifestBytes)
        #expect(try await ProjectStore().load(from: url).manifest.layers.count == 250)
    }

    // MARK: Reusing unchanged assets

    @Test func unchangedLayersAreNotEncodedAgain() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let rich = try richSession()
        let store = ProjectStore()
        let first = root.appendingPathComponent("First.comp"), second = root.appendingPathComponent("Second.comp")
        try await store.save(try #require(rich.session.projectSnapshot()), to: first)
        #expect(await store.encodeCount == 2) // The photo and its mask.
        try await store.save(try #require(rich.session.projectSnapshot()), to: second)
        #expect(await store.encodeCount == 2)
        for path in try FileManager.default.subpathsOfDirectory(atPath: first.path) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: first.appendingPathComponent(path).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            #expect(try Data(contentsOf: first.appendingPathComponent(path)) == Data(contentsOf: second.appendingPathComponent(path)), "\(path)")
        }

        // New pixels on one layer encode that layer alone.
        let index = try #require(rich.session.document?.layers.firstIndex { $0.id == rich.photo })
        rich.session.document?.layers[index].asset = try color(20, 10, red: 0, green: 0, blue: 1)
        try await store.save(try #require(rich.session.projectSnapshot()), to: second)
        #expect(await store.encodeCount == 3)
        let reloaded = try await store.load(from: second)
        let pixel = try colorAt(reloaded.images[rich.photo]?.image, x: 5, y: 5)
        #expect(pixel.blueComponent > 0.9 && pixel.redComponent < 0.5)
    }

    /// A store keeps only a few documents' encodings, so closed documents' images aren't held for good.
    @Test func reuseIsKeptForOnlyAFewDocuments() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore()
        let sessions = try (0..<6).map { _ in
            let session = EditorSession()
            session.createDocument(width: 4, height: 4)
            session.document?.layers = [ImageLayer(asset: try color(4, 4, red: 1, green: 1, blue: 0), origin: .zero)]
            return session
        }
        for (index, session) in sessions.enumerated() {
            try await store.save(try #require(session.projectSnapshot()), to: root.appendingPathComponent("\(index).comp"))
        }
        #expect(await store.encodeCount == 6)
        // The most recent are reused; the first, pushed out, encodes again.
        try await store.save(try #require(sessions[5].projectSnapshot()), to: root.appendingPathComponent("5.comp"))
        #expect(await store.encodeCount == 6)
        try await store.save(try #require(sessions[0].projectSnapshot()), to: root.appendingPathComponent("0.comp"))
        #expect(await store.encodeCount == 7)
    }
}

/// Finds the test bundle, which holds the checked-in fixtures.
private final class FixtureBundle {}
