import SwiftUI
import UniformTypeIdentifiers
import os

/// Resolve in pasteboard order; the importer validates contents rather than trusting extensions.
@MainActor
enum ImageFileDrop {
    nonisolated private static let log = Logger.compositor("Import")

    static func importProviders(_ providers: [NSItemProvider], into session: EditorSession, at point: CGPoint?, projects: ProjectController? = nil, workspace: ProjectWorkspace? = nil, destination: UUID? = nil) async {
        var urls: [URL] = []
        // Folders holding copies made for this drop. Imports read every pixel before they finish, so the
        // copies are deleted once they have.
        var temporaries: [URL] = []
        defer {
            for folder in temporaries {
                do { try FileManager.default.removeItem(at: folder) }
                catch { log.error("Couldn’t delete a dropped image’s temporary copy: \(error.localizedDescription, privacy: .public)") }
            }
        }
        var unreadable = false
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    // Expected for image data that isn't a file; logged in case it is a file that failed.
                    if let error { log.debug("A dropped item has no file URL: \(error.localizedDescription, privacy: .public)") }
                    continuation.resume(returning: url?.isFileURL == true ? url : nil)
                }
            }
            if let url { urls.append(url) }
            // Not a file on disk: a screenshot's thumbnail, or an image dragged from a web page or another app,
            // hands over image data (or a file it only promises). Copy it somewhere the importer can read.
            else if let copy = await temporaryFile(from: provider) {
                urls.append(copy)
                temporaries.append(copy.deletingLastPathComponent())
            }
            else { unreadable = true }
        }
        if let workspace { await workspace.receive(urls, into: destination, at: point) }
        else if let projects { await projects.receive(urls, at: point) }
        else { await session.importImages(urls, at: point) }
        if unreadable, !providers.isEmpty {
            let message = "Some dropped items couldn’t be read. Drag JPEG, PNG, HEIC, TIFF, or Photoshop (PSD) files from Finder."
            session.importError = [session.importError, message].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    /// A dropped item's image written to a temporary file, or nil when it holds no image.
    private static func temporaryFile(from provider: NSItemProvider) async -> URL? {
        let types = [UTType.png, .jpeg, .heic, .tiff, .photoshopImage, .rawImage, .image].map(\.identifier)
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { return nil }
        return await withCheckedContinuation { continuation in
            // The file only exists until this closure returns, so it is copied, not referenced.
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    log.error("A dropped image couldn’t be loaded: \(error?.localizedDescription ?? "no file", privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                let name = url.deletingPathExtension().lastPathComponent
                let suffix = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : url.pathExtension
                // A unique folder rather than a unique file name: the copy keeps the name the file
                // was dropped under, which is the name the import sheet and the new layers show.
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let copy = folder
                    .appendingPathComponent(name.isEmpty ? "Dropped" : name)
                    .appendingPathExtension(suffix)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    log.error("A dropped image couldn’t be copied for import: \(error.localizedDescription, privacy: .public)")
                    try? FileManager.default.removeItem(at: folder)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
