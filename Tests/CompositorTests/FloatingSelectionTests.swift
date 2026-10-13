import AppKit
import Testing
@testable import Compositor

/// Transforming selected pixels (Cmd-T with a selection): they float on a layer of their own, and merge back once
/// the transform is applied.
@MainActor
struct FloatingSelectionTests {
    /// A 100 × 40 canvas whose one layer is red on the left half and blue on the right.
    private func makeSession() async -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.setPaletteColor(PaletteColor(red: 1, green: 0, blue: 0), background: false)
        session.setPaletteColor(PaletteColor(red: 0, green: 0, blue: 1), background: true)
        await session.fillSelection(with: .background)
        select(session, CGRect(x: 0, y: 0, width: 50, height: 40))
        await session.fillSelection(with: .foreground)
        session.deselect()
        return session
    }
    private func select(_ session: EditorSession, _ rect: CGRect) {
        session.applySelection(CGPath(rect: rect, transform: nil), mode: .replace, name: "Select")
    }
    private func rendered(_ session: EditorSession) async throws -> [UInt8] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }
    /// An image that only says how big it is: its pixels are made (as zeros) only if something draws it.
    private func placeholder(width: Int, height: Int) throws -> CGImage {
        var callbacks = CGDataProviderSequentialCallbacks(version: 0, getBytes: { _, buffer, count in
            memset(buffer, 0, count)
            return count
        }, skipForward: { _, count in count }, rewind: { _ in }, releaseInfo: nil)
        let provider = try #require(CGDataProvider(sequentialInfo: nil, callbacks: &callbacks))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Lifting the pixels clears them from their layer first. When that fails, floating them anyway made the
    /// transform a copy rather than a move; now the float is abandoned, and the failure said.
    @Test func aClearThatFailsAbandonsTheFloatRatherThanCopyingThePixels() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        // Another layer holding the whole pixel budget leaves the clear no room for even one tile.
        let huge = try placeholder(width: 10_000, height: 10_000)
        let small = try placeholder(width: 1, height: 1)
        session.document?.layers.insert(ImageLayer(asset: ImportedImage(image: huge, thumbnail: small, name: "Huge"), origin: .zero), at: 0)
        #expect(session.activeLayerID == source)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        let before = session.document, count = session.history.undoCount
        #expect(session.canTransformSelection)
        await session.beginSelectionTransform()
        #expect(session.transformEdit == nil && session.brushError != nil)
        #expect(session.document == before && session.activeLayerID == source)
        #expect(session.history.undoCount <= count)
    }

    /// Apply renders the floating merge off the main thread, then commits it: the same document as committing at
    /// once, as one undo step.
    @Test func applyMergesOffTheMainThreadExactlyAsACommitDoes() async throws {
        func moved(_ apply: (EditorSession) async -> Void) async throws -> (EditorSession, [UInt8]) {
            let session = await makeSession()
            select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
            await session.beginSelectionTransform()
            var draft = try #require(session.transformEdit?.draft)
            draft.origin = CGPoint(x: 70, y: 20)
            draft.size = CGSize(width: 15, height: 12)
            session.previewTransform(draft)
            #expect(session.pendingTransformResamples)
            let count = session.history.undoCount
            await apply(session)
            #expect(session.transformEdit == nil && !session.isProjectBusy)
            #expect(session.history.undoCount == count + 1 && session.history.undoName == "Transform Selection")
            #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 70, y: 20, width: 15, height: 12))
            return (session, try await rendered(session))
        }
        let (applied, viaApply) = try await moved { await $0.applyTransform() }
        let (_, viaCommit) = try await moved { $0.commitTransform() }
        let (_, viaSettle) = try await moved { await $0.settleTransform() }
        #expect(viaApply == viaCommit && viaSettle == viaCommit)
        // Red moved onto the blue side, leaving a hole.
        #expect(Array(viaApply[((25 * 100) + 75) * 4..<((25 * 100) + 75) * 4 + 4]) == [255, 0, 0, 255])
        #expect(viaApply[((15 * 100) + 15) * 4 + 3] == 0)
        #expect(applied.document?.layers.count == 1)
    }

    /// A merge made for one placement isn't used for another: the commit redoes it.
    @Test func aRenderedMergeIsOnlyUsedForWhatItWasMadeFrom() async throws {
        let session = await makeSession()
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        await session.beginSelectionTransform()
        let edit = try #require(session.transformEdit)
        let layers = try #require(session.document?.layers)
        let pixels = try #require(layers.first { $0.id == edit.layerID }?.asset?.image)
        let source = try #require(layers.first { $0.id == edit.floating?.sourceID })
        var draft = edit.draft
        draft.origin.x += 40
        let job = FloatingMerge.Job(pixels: pixels, draft: draft, corners: nil, source: source)
        let rendered = FloatingMerge.Rendered(job: job, merged: try FloatingMerge.render(job))
        #expect(rendered.matches(job))
        var elsewhere = draft
        elsewhere.origin.x += 1
        #expect(!rendered.matches(FloatingMerge.Job(pixels: pixels, draft: elsewhere, corners: nil, source: source)))
        var renamed = source
        renamed.name = "Other"
        #expect(!rendered.matches(FloatingMerge.Job(pixels: pixels, draft: draft, corners: nil, source: renamed)))
    }
}
