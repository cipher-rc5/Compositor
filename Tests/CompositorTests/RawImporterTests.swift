import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

/// What can be checked without a camera file in the repository: which files count as RAW, the settings'
/// own behavior, and that a file the system can't develop says so instead of failing quietly.
@MainActor
struct RawImporterTests {
    /// Bytes under a RAW extension that no decoder will open.
    private func garbageRaw() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        try Data("not a camera file".utf8).write(to: url)
        return url
    }

    /// A real PNG named as a RAW: ImageIO reads its size from the contents, but there is nothing to develop.
    private func pngNamedAsRaw() throws -> URL {
        let png = try ImageImportTests().fixture(.png)
        let url = png.deletingPathExtension().appendingPathExtension("dng")
        try FileManager.default.moveItem(at: png, to: url)
        return url
    }

    @Test func rawFilesAreRecognizedByTheirType() {
        for name in ["photo.dng", "photo.CR2", "photo.nef", "photo.arw"] {
            #expect(RawImporter.matches(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["photo.png", "photo.jpg", "photo.psd", "photo"] {
            #expect(!RawImporter.matches(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func settingsResetToWhatTheCameraChose() {
        var settings = RawDevelopSettings(temperature: 6500, tint: 10, asShotTemperature: 6500, asShotTint: 10)
        #expect(settings.isAsShot)
        settings.exposure = 1.5
        settings.temperature = 3000
        settings.boost = 0.2
        #expect(!settings.isAsShot)
        settings.reset()
        #expect(settings.isAsShot)
        #expect(settings.temperature == 6500 && settings.tint == 10 && settings.exposure == 0 && settings.boost == 1)
    }

    @Test func undecodableFilesReportWhyInsteadOfReturningNothing() async throws {
        let url = try garbageRaw()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RawImporter.pixelSize(url) == nil)
        #expect(throws: RawImportError.developFailed) { try RawImporter.develop(url, settings: RawDevelopSettings()) }
        // Both the sheet's preview (a size limit) and the import itself (none) surface the error.
        for limit: CGFloat? in [800, nil] {
            await #expect(throws: RawImportError.developFailed) {
                try await RawImporter.Queue.shared.develop(url, settings: RawDevelopSettings(), limit: limit)
            }
        }
        await RawImporter.Queue.shared.release()
    }

    /// The system's RAW filter develops any image it can read, which gives the success path a fixture.
    @Test func aReadableFileDevelopsAtFullSize() async throws {
        let url = try pngNamedAsRaw()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RawImporter.matches(url))
        #expect(RawImporter.pixelSize(url).map { [$0.width, $0.height] } == [64, 32])
        let developed = try await RawImporter.Queue.shared.develop(url, settings: RawDevelopSettings(), limit: nil)
        #expect(developed.width == 64 && developed.height == 32)
    }

    /// A file that passes the size check but won't develop (here, replaced while the sheet was up) fails the
    /// import with the RAW error rather than a generic one, and leaves no document behind.
    @Test func aFailedDevelopIsReportedByTheImport() async throws {
        let url = try pngNamedAsRaw()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmRawDevelop = { url, settings in
            try? Data("no longer an image".utf8).write(to: url)
            return settings
        }
        await session.importImages([url])
        #expect(session.document == nil)
        let message = try #require(session.importError)
        #expect(message.contains(url.lastPathComponent))
        #expect(message.contains(try #require(RawImportError.developFailed.errorDescription)))
    }

    @Test func cancellingTheDevelopImportsNothing() async throws {
        let url = try pngNamedAsRaw()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmRawDevelop = { _, _ in nil }
        await session.importImages([url])
        #expect(session.document == nil)
        #expect(session.importError == nil)
    }

    /// The size check before the sheet reads the file's header; what actually develops is held to the same
    /// limits before it reaches the document. Here the file grows past 30,000 pixels a side while the sheet is up.
    @Test func aFrameThatDevelopsPastTheLimitsIsRefused() async throws {
        let url = try pngNamedAsRaw()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmRawDevelop = { url, settings in
            guard let context = CGContext(data: nil, width: 30_001, height: 1, bitsPerComponent: 8, bytesPerRow: 30_001 * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? settings : nil
        }
        await session.importImages([url])
        #expect(session.document == nil)
        let message = try #require(session.importError)
        #expect(message.contains(try #require(ImageImportError.tooLarge.errorDescription)))
    }

    @Test func developedPixelsCountAgainstTheDocumentsBudget() throws {
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let developed = try #require(context.makeImage())
        try RawImporter.checkDeveloped(developed, usedPixels: 100_000_000 - 64 * 32)
        #expect(throws: ImageImportError.tooLarge) {
            try RawImporter.checkDeveloped(developed, usedPixels: 100_000_000 - 64 * 32 + 1)
        }
    }
}
