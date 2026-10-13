import AppKit
import Testing
@testable import Compositor

@MainActor
struct LayerMergeTests {
    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int, height: Int) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Solid")
    }

    /// A 60 × 40 canvas: a red 40 × 30 layer at (0, 0) with a blue 20 × 20 one over it at (30, 10), half opaque.
    private func twoLayers() throws -> (EditorSession, red: UUID, blue: UUID) {
        let session = EditorSession()
        session.createDocument(width: 60, height: 40)
        session.insert(try solid(1, 0, 0, width: 40, height: 30), centeredAt: CGPoint(x: 20, y: 15))
        let red = try #require(session.activeLayerID)
        session.insert(try solid(0, 0, 1, width: 20, height: 20), centeredAt: CGPoint(x: 40, y: 20))
        let blue = try #require(session.activeLayerID)
        session.setLayerOpacity(0.5)
        return (session, red, blue)
    }

    private func rendered(_ session: EditorSession) async throws -> [UInt8] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    @Test func mergeDownKeepsTheLookInOneTrimmedLayerAsOneUndoStep() async throws {
        let (session, red, blue) = try twoLayers()
        let before = try await rendered(session)
        let count = session.history.undoCount
        #expect(session.canMergeLayers && session.mergeTitle == "Merge Down")
        await session.mergeLayers()
        #expect(!session.isProjectBusy)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Merge Down")
        let layers = try #require(session.document?.layers)
        #expect(layers.count == 1 && layers[0].id == session.activeLayerID && layers[0].opacity == 1)
        #expect(!layers.contains { $0.id == red || $0.id == blue })
        // Trimmed to what the two covered: (0, 0) to (50, 30).
        #expect(layers[0].transform.origin == .zero && layers[0].transform.size == CGSize(width: 50, height: 30))
        let after = try await rendered(session)
        #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        session.undo()
        #expect(session.document?.layers.map(\.id) == [red, blue])
    }

    @Test func severalSelectedLayersMergeIntoTheTopOne() async throws {
        let (session, red, blue) = try twoLayers()
        session.insert(try solid(0, 1, 0, width: 10, height: 10), centeredAt: CGPoint(x: 55, y: 35))
        let green = try #require(session.activeLayerID)
        session.selectLayers([red, green], primary: green)
        #expect(session.mergeTitle == "Merge Layers")
        await session.mergeLayers()
        let layers = try #require(session.document?.layers)
        // Blue, unselected, stays put above the merged red and green, which take the top one's place.
        #expect(layers.count == 2 && layers[0].id == blue && layers[1].name == "Solid" && session.history.undoName == "Merge Layers")
        #expect(layers[1].transform.origin == .zero && layers[1].transform.size == CGSize(width: 60, height: 40))
    }

    @Test func nothingBelowMeansNothingToMerge() async throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 20)
        session.insert(try solid(1, 0, 0, width: 20, height: 20))
        let count = session.history.undoCount
        #expect(!session.canMergeLayers)
        await session.mergeLayers()
        #expect(session.history.undoCount == count && session.document?.layers.count == 1)
    }

    /// A merge that can't be drawn (here, a canvas too wide for a bitmap) leaves the layers alone and says why,
    /// rather than beeping.
    @Test func aMergeThatFailsSaysSoAndChangesNothing() async throws {
        let (session, _, _) = try twoLayers()
        let document = try #require(session.document)
        // Rows of 2³¹ bytes: more than a bitmap can hold.
        session.document = CanvasDocument(id: document.id, width: 1 << 29, height: 40, layers: document.layers)
        let before = session.document, count = session.history.undoCount
        #expect(session.canMergeLayers)
        await session.mergeLayers()
        #expect(session.brushError?.contains("Merge Down") == true)
        #expect(session.document == before && session.history.undoCount == count && !session.isProjectBusy)
    }
}
