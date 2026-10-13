import AppKit
import Testing
@testable import Compositor

/// The Blur tool (Blur mode): paints a softened copy of the layer, made off the main thread when the stroke starts.
@MainActor
struct BlurToolTests {
    private func opaque(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        // Columns of alternating color, so blurring changes something everywhere but alpha.
        for x in 0..<width {
            context.setFillColor(x % 2 == 0 ? CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return try #require(context.makeImage())
    }
    private func alphas(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] }
    }
    private func session(width: Int = 40, height: Int = 20) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        let image = try opaque(width: width, height: height)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Stripes"))
        session.selectTool(.blur)
        session.blurMode = .blur
        session.brushSettings = BrushSettings(diameter: 30, hardness: 1, opacity: 1)
        return session
    }

    /// Past the canvas's edge the blur reads the edge again, not transparency, so an opaque layer stays opaque there.
    @Test func theSampleStaysOpaqueToTheCanvasEdge() throws {
        let session = try session()
        let sample = try session.blurSample(try #require(session.document))
        #expect(sample.width == 40 && sample.height == 20)
        #expect(try alphas(sample).allSatisfy { $0 == 255 })
    }

    @Test func aStrokeAlongTheEdgeLeavesItOpaqueAsOneUndoStep() async throws {
        let session = try session()
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 0, y: 0))
        session.continueBrush(at: CGPoint(x: 39, y: 0))
        await session.finishBrush()
        #expect(session.brushError == nil && session.brushStroke == nil && !session.isProjectBusy)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Blur")
        let result = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(try alphas(result).allSatisfy { $0 == 255 })
    }

    /// Mouse-up can come before the source is made: the stroke is held, busy, and committed once it lands.
    @Test func aStrokeLetGoBeforeItsSourceLandsIsStillCommitted() async throws {
        let session = try session()
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 10, y: 10))
        #expect(session.brushStroke != nil)
        session.continueBrush(at: CGPoint(x: 20, y: 10))
        #expect(session.finishBrushImmediately())
        #expect(await waitUntil { !session.isProjectBusy && session.brushStroke == nil })
        #expect(session.brushError == nil && session.history.undoCount == count + 1 && session.history.undoName == "Blur")
    }

    /// A canvas too large for the sample's buffer says so, rather than leaving the stroke to do nothing.
    @Test func aCanvasTooLargeForTheSampleReportsIt() async throws {
        let session = try session()
        let document = try #require(session.document)
        // Rows of 2³¹ bytes: more than a bitmap can hold.
        session.document = CanvasDocument(id: document.id, width: 1 << 29, height: 20, layers: document.layers)
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 10, y: 10))
        session.continueBrush(at: CGPoint(x: 12, y: 10))
        await session.finishBrush()
        #expect(await waitUntil { session.brushError != nil })
        #expect(session.brushStroke == nil && !session.isProjectBusy && session.history.undoCount == count)
    }
}
