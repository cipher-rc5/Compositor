import SwiftUI

extension EditorSession {
    /// Puts the develop sheet up and waits for the choice; nil means the import was cancelled.
    func developRaw(_ url: URL) async -> RawDevelopSettings? {
        let asShot = RawImporter.asShot(url) ?? RawDevelopSettings()
        if let confirmRawDevelop { return await confirmRawDevelop(url, asShot) }
        return await withCheckedContinuation { continuation in
            rawContinuation = continuation
            rawDevelop = (url, asShot)
            showsRawDevelop = true
        }
    }
    func finishRawDevelop(_ settings: RawDevelopSettings?) {
        showsRawDevelop = false
        rawDevelop = nil
        Task { await RawImporter.Queue.shared.release() }
        let continuation = rawContinuation
        rawContinuation = nil
        continuation?.resume(returning: settings)
    }

    func importImages(_ urls: [URL], at point: CGPoint? = nil) async {
        guard !urls.isEmpty else { return }
        if brushStroke != nil { await finishBrush() }
        cancelCrop()
        commitTransform()
        // Hold sandbox grants while requests wait behind an in-progress decode.
        let files = urls.map { (url: $0, scoped: $0.startAccessingSecurityScopedResource()) }
        await waitForProjectAccess()
        await withCheckedContinuation { completion in
            pendingImports.append(ImportRequest(files: files, point: point, completion: completion))
            if !isImporting {
                isImporting = true
                Task { await drainImports() }
            }
        }
    }

    private func drainImports() async {
        var failures: [String] = []
        while !pendingImports.isEmpty {
            let request = pendingImports.removeFirst()
            let psdOnly = request.files.allSatisfy { PSDReader.matches($0.0) }
            beginEdit(psdOnly ? "Import Photoshop File" : "Import Images")
            // No document: the first successful image determines the canvas, regardless of drop point.
            let point = document == nil ? nil : request.point
            for (url, scoped) in request.files {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard url.isFileURL else { throw ImageImportError.unsupported }
                    let usedPixels = usedImagePixels()
                    // Masks have a budget of their own, as in a saved project.
                    let usedMaskPixels = document?.layers.reduce(0) { total, layer in
                        guard let image = layer.mask?.asset.image else { return total }
                        return total + image.width * image.height
                    } ?? 0
                    if RawImporter.matches(url) {
                        guard let size = RawImporter.pixelSize(url) else { throw ImageImportError.unreadable }
                        guard size.width <= 30_000, size.height <= 30_000,
                              size.width * size.height <= 100_000_000 - usedPixels else { throw ImageImportError.tooLarge }
                        guard let settings = await developRaw(url) else { continue }
                        // Seconds of work: off the main actor, or pressing Import freezes the window.
                        let developed = try await RawImporter.Queue.shared.develop(url, settings: settings, limit: nil)
                        // Counted again: the document can change while the develop sheet is up.
                        try RawImporter.checkDeveloped(developed, usedPixels: usedImagePixels())
                        let thumbnail = try PixelAdjust.thumbnail(of: developed)
                        insert(ImportedImage(image: developed, thumbnail: thumbnail,
                                             name: url.deletingPathExtension().lastPathComponent), centeredAt: point)
                    } else if PSDReader.matches(url) {
                        beginPSDReading(title: "Open “\(url.lastPathComponent)”?", confirmTitle: "Import")
                        let imported: PSDImport
                        do {
                            let parsed = try await ImageImporter.shared.loadPhotoshop(url, remainingPixels: 100_000_000 - usedPixels,
                                                                                   remainingMaskPixels: 100_000_000 - usedMaskPixels)
                            let assets = try await ImageImporter.shared.photoshopAssets(parsed)
                            imported = try PSDDocumentBuilder.makeImport(parsed, assets: assets)
                        } catch {
                            endPSDReading()
                            throw error
                        }
                        if !(await finishPSDReading(imported.conversions)) { continue }
                        try insertPhotoshop(imported, named: url.deletingPathExtension().lastPathComponent, centeredAt: point)
                    } else {
                        let asset = try await ImageImporter.shared.decode(url, remainingPixels: 100_000_000 - usedPixels)
                        insert(asset, centeredAt: point)
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            endEdit()
            request.completion.resume()
        }
        isImporting = false
        if !failures.isEmpty { importError = failures.joined(separator: "\n\n") }
    }

    /// Image pixels the document already holds, out of the 100 million a project may store.
    func usedImagePixels() -> Int {
        document?.layers.reduce(0) { total, layer in
            guard let image = layer.asset?.image else { return total }
            return total + image.width * image.height
        } ?? 0
    }

    func insert(_ asset: ImportedImage, centeredAt point: CGPoint? = nil) {
        beginEdit("Import Image")
        defer { endEdit() }
        if document == nil {
            document = CanvasDocument(width: asset.image.width, height: asset.image.height)
            viewport.fit(documentSize: document!.size)
        }
        guard let document else { return }
        let center = point ?? CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        var layer = ImageLayer(asset: asset, origin: CGPoint(
            x: floor(center.x - CGFloat(asset.image.width) / 2),
            y: floor(center.y - CGFloat(asset.image.height) / 2)))
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        self.document?.layers.append(layer)
        activeLayerID = layer.id
    }

    /// Puts the sheet up before the file is read, so a big PSD doesn't leave the click unanswered.
    /// `finishPSDReading` fills it in, or takes it away when there is nothing to report.
    func beginPSDReading(title: String, confirmTitle: String) {
        guard confirmConversions == nil else { return }
        conversionCancelled = false
        conversionRequest = PSDConversionRequest(title: title, confirmTitle: confirmTitle, conversions: [], isReading: true)
        showsConversionSheet = true
    }
    func finishPSDReading(_ conversions: [PSDConversion]) async -> Bool {
        if let confirmConversions {
            if conversions.isEmpty { return true }
            return await confirmConversions(conversions)
        }
        if conversionCancelled { endPSDReading(); return false }
        guard !conversions.isEmpty else { endPSDReading(); return true }
        return await withCheckedContinuation { continuation in
            conversionContinuation = continuation
            conversionRequest?.conversions = conversions
            conversionRequest?.isReading = false
        }
    }
    /// Takes the sheet away without an answer: nothing to report, or the read failed.
    func endPSDReading() {
        guard conversionContinuation == nil else { return }
        showsConversionSheet = false
        conversionRequest = nil
    }
    func confirmPSDConversions(_ conversions: [PSDConversion], title: String, confirmTitle: String) async -> Bool {
        if let confirmConversions { return await confirmConversions(conversions) }
        return await withCheckedContinuation { continuation in
            conversionContinuation = continuation
            conversionRequest = PSDConversionRequest(title: title, confirmTitle: confirmTitle, conversions: conversions)
            showsConversionSheet = true
        }
    }

    func finishConversion(_ confirmed: Bool) {
        if !confirmed, conversionRequest?.isReading == true { conversionCancelled = true }
        showsConversionSheet = false
        conversionRequest = nil
        let continuation = conversionContinuation
        conversionContinuation = nil
        continuation?.resume(returning: confirmed)
    }

    func insertPhotoshop(_ imported: PSDImport, named: String, centeredAt point: CGPoint? = nil) throws {
        beginEdit("Import Photoshop File")
        defer { endEdit() }
        var incoming = imported.layers
        let wrapping = document != nil
        let added = incoming.count + (wrapping ? 1 : 0)
        if (document?.layers.count ?? 0) + added > 10_000 { throw ImageImportError.tooLarge }
        if document == nil {
            document = CanvasDocument(width: imported.width, height: imported.height, layers: incoming, resolution: imported.resolution)
            viewport.fit(documentSize: document!.size)
            activeLayerID = incoming.last(where: { $0.parentID == nil })?.id ?? incoming.last?.id
            return
        }
        guard document != nil else { return }
        var group = ImageLayer(name: named, blankSize: document!.size)
        group.isGroup = true
        group.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let point {
            let box = incoming.filter { !$0.isGroup }.reduce(CGRect.null) { $0.union(CGRect(origin: $1.origin, size: $1.size)) }
            if !box.isNull, !box.isInfinite, !box.isEmpty, box.origin.x.isFinite, box.origin.y.isFinite {
                let dx = point.x - box.midX, dy = point.y - box.midY
                for index in incoming.indices {
                    incoming[index].transform.origin.x += dx
                    incoming[index].transform.origin.y += dy
                }
            }
        }
        for index in incoming.indices where incoming[index].parentID == nil {
            incoming[index].parentID = group.id
        }
        // The import arrives inside a new folder under the active one, which can push its own folders past the 64
        // levels a project may nest; refuse rather than build a document that can't be saved.
        guard Self.nestingFits(document!.layers + [group] + incoming) else { throw ImageImportError.tooDeep }
        self.document?.layers.append(group)
        self.document?.layers.append(contentsOf: incoming)
        if let parent = group.parentID { collapsedGroupIDs.remove(parent) }
        collapsedGroupIDs.remove(group.id)
        activeLayerID = group.id
    }

    /// The rule `LayerHierarchy.validate` applies on save: at most 64 folders above any layer, 63 above a folder.
    nonisolated static func nestingFits(_ layers: [ImageLayer]) -> Bool {
        let parents = Dictionary(layers.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        return layers.allSatisfy { layer in
            var ancestors = 0, parent = layer.parentID
            while let id = parent {
                ancestors += 1
                if ancestors > 64 { return false }
                parent = parents[id] ?? nil
            }
            return layer.isGroup ? ancestors < 64 : true
        }
    }
}
