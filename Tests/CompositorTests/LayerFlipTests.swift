import AppKit
import Testing
@testable import Compositor

@MainActor
struct LayerFlipTests {
    /// 20 × 10: red on the left half, blue on the right.
    private func halves() throws -> ImportedImage {
        let context = try BrushRaster.context(width: 20, height: 10, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Halves")
    }

    private func pixel(_ session: EditorSession, x: Int, y: Int) async throws -> [UInt8] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { bytes[y * context.bytesPerRow + x * 4 + $0] }
    }

    @Test func mirroringAcrossALineFlipsAndMovesTheBox() {
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 5), size: CGSize(width: 20, height: 10))
        let across = transform.mirrored(horizontally: true, across: 50)
        #expect(across.flipX && !across.flipY && across.origin == CGPoint(x: 70, y: 5) && across.size == transform.size)
        let down = transform.mirrored(horizontally: false, across: 5)
        #expect(down.flipY && !down.flipX && down.origin == CGPoint(x: 10, y: -5))
        // About its own middle it stays where it is, and twice is the identity.
        #expect(transform.mirrored(horizontally: true, across: transform.center.x).origin == transform.origin)
        #expect(across.mirrored(horizontally: true, across: 50) == transform)
    }

    @Test func flippingALayerMirrorsItInPlaceAsOneUndoStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 60, height: 30)
        session.insert(try halves(), centeredAt: CGPoint(x: 20, y: 10))
        let original = try #require(session.activeLayer?.transform)
        #expect(try await pixel(session, x: 12, y: 10) == [255, 0, 0, 255])
        let count = session.history.undoCount
        session.flipLayers(horizontally: true)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Flip Horizontal")
        let flipped = try #require(session.activeLayer?.transform)
        #expect(flipped.flipX && flipped.origin == original.origin && flipped.size == original.size)
        #expect(try await pixel(session, x: 12, y: 10) == [0, 0, 255, 255])
        #expect(try await pixel(session, x: 27, y: 10) == [255, 0, 0, 255])
        session.undo()
        #expect(session.activeLayer?.transform == original)
    }

    @Test func severalLayersFlipAboutTheMiddleOfTheirBox() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40)
        session.insert(try halves(), centeredAt: CGPoint(x: 10, y: 5))  // (0, 0)–(20, 10)
        let left = try #require(session.activeLayerID)
        session.insert(try halves(), centeredAt: CGPoint(x: 70, y: 25)) // (60, 20)–(80, 30)
        let right = try #require(session.activeLayerID)
        session.selectLayers([left, right], primary: right)
        session.flipLayers(horizontally: false)
        let layers = try #require(session.document?.layers)
        // The box is (0, 0)–(80, 30): each layer's top lands where the other side's bottom was.
        #expect(layers.first { $0.id == left }?.transform.origin == CGPoint(x: 0, y: 20))
        #expect(layers.first { $0.id == right }?.transform.origin == CGPoint(x: 60, y: 0))
        #expect(layers.allSatisfy { $0.transform.flipY && !$0.transform.flipX })
    }

    @Test func flippingTheCanvasMirrorsLayersAndTheSelection() async throws {
        let session = EditorSession()
        session.createDocument(width: 60, height: 30)
        session.insert(try halves(), centeredAt: CGPoint(x: 20, y: 10)) // (10, 5)–(30, 15)
        session.applySelection(CGPath(rect: CGRect(x: 5, y: 2, width: 10, height: 6), transform: nil), mode: .replace, name: "Select")
        let before = session.document
        session.flipCanvas(horizontally: true)
        #expect(session.history.undoName == "Flip Canvas Horizontal")
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 30, y: 5) && session.activeLayer?.transform.flipX == true)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 45, y: 2, width: 10, height: 6))
        // Red, on the layer's left, is now on its right.
        #expect(try await pixel(session, x: 47, y: 10) == [255, 0, 0, 255])
        #expect(try await pixel(session, x: 32, y: 10) == [0, 0, 255, 255])
        session.undo()
        #expect(session.document == before)
    }
}
