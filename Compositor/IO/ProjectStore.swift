import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

extension UTType {
    static let compositorProject = UTType(exportedAs: "com.compositor.project", conformingTo: .package)
    static let photoshopImage = UTType(importedAs: "com.adobe.photoshop-image")
    static let importableImages: [UTType] = [.jpeg, .png, .heic, .tiff, .photoshopImage, .rawImage]
}

nonisolated struct ProjectManifest: Codable, Sendable {
    var format = "com.compositor.project"
    var version = 9
    var colorSpace = "sRGB"
    var resolution: Double? = nil // Older version-1 projects default to 72 pixels/inch.
    let documentID: UUID
    let width: Int
    let height: Int
    let activeLayerID: UUID?
    var layers: [ProjectLayerRecord]
    /// Alignment guides. Missing on versions 1–7.
    var guides: [CanvasGuide]? = nil
}

nonisolated struct ProjectLayerRecord: Codable, Sendable {
    let id: UUID
    let name: String
    var isVisible: Bool
    let transform: LayerTransform
    let imageFile: String?
    var parentID: UUID? = nil
    var isGroup: Bool? = nil
    var opacity: Double? = nil
    var blendMode: LayerBlendMode? = nil
    var maskFile: String? = nil
    var maskEnabled: Bool? = nil
    var maskSourceID: UUID? = nil
    var adjustment: LayerAdjustment? = nil
    /// A mask moved apart from its layer: where it sits on the document.
    var maskPlacement: LayerTransform? = nil
    /// Nil (older projects) is linked.
    var maskLinked: Bool? = nil
    /// A shape layer's shape, drawn again when the layer is scaled. Older versions ignore it and keep the pixels.
    var shape: LayerShapeStyle? = nil
    /// The stroke and drop shadow drawn around the layer.
    var effects: LayerEffects? = nil
    var text: LayerTextStyle? = nil
}

nonisolated extension LayerShapeStyle {
    /// What a saved shape must hold to be drawn again: an sRGB color, a radius and line width that are real
    /// lengths, and line ends inside the layer's box (the Shape tool only ever stores fractions of it).
    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && cornerRadius.isFinite && cornerRadius >= 0
            && (lineWidth.map { $0.isFinite && $0 >= 0 } ?? true)
            && [start, end].allSatisfy { point in
                point.map { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) } ?? true
            }
    }
}

nonisolated struct ProjectSnapshot: Sendable {
    let manifest: ProjectManifest
    let images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage] = [:]
}

nonisolated enum ProjectError: LocalizedError, Equatable {
    case invalid, version(Int), missingImage, tooLarge, encode, unsafeFile, manifestTooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Compositor project, or its metadata is damaged."
        case .version(let version): "This project uses format version \(version). This app supports versions 1–9."
        case .missingImage: "An image inside the project is missing or damaged. The current document has not been replaced."
        case .tooLarge: "This project exceeds the supported canvas, layer, file-size, or 100-megapixel image limit."
        case .encode: "An image could not be saved. The previous project has not been replaced."
        case .unsafeFile: "This project contains a link where a file should be, so it was not opened."
        case .manifestTooLarge: "This project’s layer details (names, text and settings) are larger than the 4 MB a project can hold. Shorten long layer names or text, or remove layers."
        }
    }
}

actor ProjectStore {
    static let shared = ProjectStore()
    private nonisolated static let log = Logger.compositor("Projects")
    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    /// The largest `manifest.json` a project may hold, as saved and as read back.
    nonisolated static let maximumManifestBytes = 4 * 1024 * 1024

    /// A layer's PNG as an earlier save encoded it, and the image it was encoded from.
    private struct EncodedAsset {
        let image: CGImage
        let data: Data
    }

    /// Each recently saved document's encoded assets by filename, so a Save or autosave encodes only the
    /// layers that changed. An entry is reused only for the very image it was made from (`===`); images are
    /// immutable, so the same image always encodes to the same file.
    private var encodedAssets: [UUID: [String: EncodedAsset]] = [:]
    /// Documents in `encodedAssets`, least recently saved first.
    private var encodedOrder: [UUID] = []
    /// Bounds on what the cache keeps alive: a few documents, and no more source pixels than two full
    /// documents' worth beyond the one just saved (entries hold their images, even after a document closes).
    private static let cachedDocumentLimit = 4
    private static let cachedPixelLimit = 200_000_000
    /// PNG encodes run by this store, for tests that check unchanged assets are reused.
    private(set) var encodeCount = 0

    func save(_ snapshot: ProjectSnapshot, to url: URL) throws {
        let metadata = try Self.encodedManifest(snapshot.manifest)
        let documentID = snapshot.manifest.documentID
        let previous = encodedAssets[documentID] ?? [:]
        var encoded: [String: EncodedAsset] = [:]
        var images: [String: FileWrapper] = [:]
        var pixels = 0, maskPixels = 0
        for layer in snapshot.manifest.layers {
            for isMask in [false, true] {
                guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
                guard let asset = (isMask ? snapshot.masks : snapshot.images)[layer.id] else { throw ProjectError.missingImage }
                if isMask {
                    guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }
                    try checkSize(width: asset.image.width, height: asset.image.height, used: &maskPixels)
                } else { try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels) }
                let data: Data
                if let cached = previous[filename], cached.image === asset.image {
                    data = cached.data
                } else {
                    // A painted layer whose pixels can't be made from its tiles would otherwise save as a blank image.
                    try asset.raster?.materialize()
                    data = try Self.pngData(asset.image)
                    encodeCount += 1
                }
                encoded[filename] = EncodedAsset(image: asset.image, data: data)
                images[filename] = FileWrapper(regularFileWithContents: data)
            }
        }
        // Kept even if the write below fails: the encodings are still right for these images.
        remember(encoded, for: documentID)
        let package = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: metadata),
            "images": FileWrapper(directoryWithFileWrappers: images)
        ])
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do { try Self.replace(destination, with: package) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }

    /// Writes the whole package somewhere else on the destination's volume, then swaps it in, so a save that
    /// fails at any point leaves the previous file as it was. FileWrapper's own `.atomic` write doesn't: when
    /// the package can't be replaced (its folder is read-only, say) it has already emptied the old one.
    private nonisolated static func replace(_ destination: URL, with package: FileWrapper) throws {
        let manager = FileManager.default
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer {
            // Usually empty by now; still there with the staged copy when the swap failed.
            do { if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) } }
            catch { log.error("A save's staging folder couldn’t be removed: \(error.localizedDescription, privacy: .public)") }
        }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try package.write(to: staged, options: [], originalContentsURL: nil)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }

    func load(from url: URL) throws -> ProjectSnapshot {
        var coordinationError: NSError?
        var result: Result<ProjectSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try readPackage(source) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectError.invalid }
        return try result.get()
    }

    private func readPackage(_ url: URL) throws -> ProjectSnapshot {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ProjectError.invalid }
        let metadataURL = url.appendingPathComponent("manifest.json")
        try checkFile(metadataURL, inside: url, maximumBytes: Self.maximumManifestBytes, missing: .invalid)
        let manifest: ProjectManifest
        let metadata = try Data(contentsOf: metadataURL)
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: metadata) }
        catch { throw ProjectError.invalid }
        guard header.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard (1...9).contains(header.version) else { throw ProjectError.version(header.version) }
        do { manifest = try JSONDecoder().decode(ProjectManifest.self, from: metadata) }
        catch { throw ProjectError.invalid }
        try Self.validate(manifest)
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var pixels = 0, maskPixels = 0
        for layer in manifest.layers {
            for isMask in [false, true] {
                guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
                let file = url.appendingPathComponent("images").appendingPathComponent(filename)
                try checkFile(file, inside: url, maximumBytes: 512 * 1024 * 1024, missing: .missingImage)
                let asset = try autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetType(source) as String? == UTType.png.identifier,
                          CGImageSourceGetCount(source) == 1,
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw ProjectError.missingImage }
                    if isMask { try checkSize(width: width, height: height, used: &maskPixels) }
                    else { try checkSize(width: width, height: height, used: &pixels) }
                    guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 96,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { throw ProjectError.missingImage }
                    if isMask, !LayerMask.isValid(image) { throw ProjectError.invalid }
                    return ImportedImage(image: image, thumbnail: thumbnail, name: layer.name)
                }
                if isMask { masks[layer.id] = asset } else { images[layer.id] = asset }
            }
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }

    private nonisolated static func pngData(_ image: CGImage) throws -> Data {
        try autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw ProjectError.encode
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
            return data as Data
        }
    }

    private func remember(_ assets: [String: EncodedAsset], for documentID: UUID) {
        encodedOrder.removeAll { $0 == documentID }
        encodedAssets[documentID] = assets
        encodedOrder.append(documentID)
        func pixels(_ id: UUID) -> Int {
            encodedAssets[id]?.values.reduce(0) { $0 + $1.image.width * $1.image.height } ?? 0
        }
        var older = encodedOrder.dropLast().reduce(0) { $0 + pixels($1) }
        while encodedOrder.count > 1,
              encodedOrder.count > Self.cachedDocumentLimit || older > Self.cachedPixelLimit {
            let oldest = encodedOrder.removeFirst()
            older -= pixels(oldest)
            encodedAssets[oldest] = nil
        }
    }

    /// Everything a manifest must satisfy to be saved or opened. Static so imports (PSD) can hold
    /// what they build to the same rules before it reaches the document.
    nonisolated static func validate(_ manifest: ProjectManifest) throws {
        _ = try encodedManifest(manifest)
    }

    /// The manifest as Save writes it, once it passes every rule. The size limit is checked on these exact
    /// bytes, so a manifest that validates always fits when saved: each field's own limit allows far more
    /// than 4 MiB in total (10,000 layers of 16 KiB names). Compact rather than pretty-printed, which
    /// would spend much of the budget on indentation.
    nonisolated static func encodedManifest(_ manifest: ProjectManifest) throws -> Data {
        try validateFields(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(manifest) } catch { throw ProjectError.invalid }
        guard data.count <= maximumManifestBytes else { throw ProjectError.manifestTooLarge }
        return data
    }

    private nonisolated static func validateFields(_ manifest: ProjectManifest) throws {
        guard manifest.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard (1...9).contains(manifest.version) else { throw ProjectError.version(manifest.version) }
        guard manifest.colorSpace == "sRGB" else { throw ProjectError.invalid }
        if let resolution = manifest.resolution {
            guard resolution.isFinite, (1...9600).contains(resolution) else { throw ProjectError.invalid }
        }
        guard (1...30_000).contains(manifest.width), (1...30_000).contains(manifest.height),
              manifest.layers.count <= 10_000 else { throw ProjectError.tooLarge }
        for layer in manifest.layers {
            if let text = layer.text {
                guard text.isValid, layer.imageFile != nil, layer.isGroup != true, layer.adjustment == nil else { throw ProjectError.invalid }
            }
            // Effects and shapes are drawn from these values at render and export time; an out-of-range
            // one would open, silently not draw, and then fail the export.
            if let effects = layer.effects {
                guard effects.isValid, layer.isGroup != true else { throw ProjectError.invalid }
            }
            if let shape = layer.shape {
                guard shape.isValid, layer.isGroup != true else { throw ProjectError.invalid }
            }
            if let adjustment = layer.adjustment {
                guard manifest.version >= 7, layer.isGroup != true, layer.imageFile == nil, adjustment.isValid else { throw ProjectError.invalid }
                if adjustment.kind == .gaussianBlur || adjustment.kind == .motionBlur || adjustment.kind == .addNoise {
                    guard manifest.version >= 9 else { throw ProjectError.invalid }
                }
            }
            // Layer masks arrived in version 4, folder masks in version 6.
            guard layer.maskFile == nil || (manifest.version >= (layer.isGroup == true ? 6 : 4)
                && layer.maskFile == "\(layer.id.uuidString).mask.png"),
                layer.maskEnabled == nil || layer.maskFile != nil,
                layer.maskPlacement.map({ $0.isValid && layer.maskFile != nil }) ?? true else { throw ProjectError.invalid }
            let opacity = layer.opacity ?? 1
            let blend = layer.blendMode ?? .normal
            // Folders took an opacity of their own in version 8, which multiplies into what is inside
            // them; their blend mode is still pass-through, so it stays Normal.
            guard opacity.isFinite, (0...1).contains(opacity),
                  (manifest.version >= 3 || (opacity == 1 && blend == .normal)),
                  (layer.isGroup != true || (blend == .normal && (manifest.version >= 8 || opacity == 1))) else { throw ProjectError.invalid }
        }
        try LayerHierarchy.validate(manifest.layers)
        try LiveMaskGraph.validate(manifest.layers)
        if manifest.version < 5, manifest.layers.contains(where: { $0.maskSourceID != nil }) { throw ProjectError.invalid }
        if manifest.version == 1, manifest.layers.contains(where: { $0.parentID != nil || $0.isGroup == true }) { throw ProjectError.invalid }
        var ids = Set<UUID>()
        for layer in manifest.layers {
            guard ids.insert(layer.id).inserted, layer.transform.isValid,
                  !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  layer.name.utf8.count <= 16_384,
                  layer.imageFile == nil || layer.imageFile == "\(layer.id.uuidString).png" else { throw ProjectError.invalid }
        }
        if let id = manifest.activeLayerID, !ids.contains(id) { throw ProjectError.invalid }
        try validateGuides(manifest)
    }

    private nonisolated static func validateGuides(_ manifest: ProjectManifest) throws {
        let guides = manifest.guides ?? []
        if manifest.version < 8 {
            guard guides.isEmpty else { throw ProjectError.invalid }
            return
        }
        guard guides.count <= 1_000 else { throw ProjectError.tooLarge }
        var ids = Set<UUID>()
        for guide in guides {
            guard ids.insert(guide.id).inserted, guide.position.isFinite, abs(guide.position) <= 1_000_000 else {
                throw ProjectError.invalid
            }
        }
    }

    private func checkSize(width: Int, height: Int, used: inout Int) throws {
        guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000 - used else {
            throw ProjectError.tooLarge
        }
        used += width * height
    }

    /// `missing` is what an absent file (or a folder or device in its place) means for this file.
    private func checkFile(_ file: URL, inside package: URL, maximumBytes: Int, missing: ProjectError) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw ProjectError.unsafeFile }
        let values: URLResourceValues
        do { values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw missing }
        // A link is refused even when it points inside the package: what it points at can change after this check.
        guard values.isSymbolicLink != true else { throw ProjectError.unsafeFile }
        guard values.isRegularFile == true, let size = values.fileSize else { throw missing }
        guard size <= maximumBytes else { throw ProjectError.tooLarge }
    }
}
