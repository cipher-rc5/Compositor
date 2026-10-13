import AppKit
import Testing
@testable import Compositor

/// Effects that can't be drawn at full size are reported rather than quietly left out, and composites drawn on the
/// main actor never wait on a full-size effects render.
@MainActor
struct LayerEffectsRenderingTests {
    private func square(side: Int = 32) throws -> CGImage {
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        return try #require(context.makeImage())
    }

    /// A shadow 5000 pixels away is a valid setting, but grows any layer past the 100-megapixel drawing budget.
    private var farShadow: LayerEffects {
        LayerEffects(shadow: ShadowEffect(angle: 90, distance: 5000, blur: 0, red: 0, green: 0, blue: 0, opacity: 1))
    }

    @Test func effectsOverTheBudgetFailExportWithAClearError() async throws {
        let image = try square(side: 10)
        #expect(farShadow.isValid)
        #expect(throws: LayerEffectsError.tooLarge) { try LayerEffectsRenderer.render(image, mask: nil, effects: farShadow) }
        // On the canvas and in other composites the layer is drawn without them, and that is logged.
        #expect(LayerEffectsRenderer.cached(image, mask: nil, effects: farShadow) == nil)

        let id = UUID()
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        let record = ProjectLayerRecord(id: id, name: "Far Shadow", isVisible: true, transform: transform,
                                        imageFile: "\(id).png", effects: farShadow)
        let manifest = ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: id, layers: [record])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [id: ImportedImage(image: image, thumbnail: image, name: "Far Shadow")])
        do {
            _ = try await ImageExporter.shared.render(snapshot)
            Issue.record("Export left the effects out instead of failing")
        } catch let error as LayerEffectsError {
            guard case .cannotExport(let layer, _) = error else { Issue.record("\(error)"); return }
            #expect(layer == "Far Shadow")
            #expect(error.localizedDescription.contains("Far Shadow"))
        }

        // The same layer with its effects hidden exports as usual.
        var hidden = farShadow
        hidden.setEnabled(false, for: .shadow)
        let visible = ProjectLayerRecord(id: id, name: "Far Shadow", isVisible: true, transform: transform,
                                         imageFile: "\(id).png", effects: hidden)
        let plain = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: id, layers: [visible]),
                                    images: snapshot.images)
        #expect(try await ImageExporter.shared.render(plain).image.width == 10)
    }

    /// The eyedropper and Clone Stamp composite on the main actor; they take effects already made, or the canvas's
    /// preview, and never start a full-size render there.
    @Test func mainActorCompositesUseMadeEffectsOnly() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        let image = try square()
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Square"), origin: .zero)
        // An outside stroke 4 pixels wide, blue, around the red square.
        layer.effects = LayerEffects(stroke: StrokeEffect(size: 4, red: 0, green: 0, blue: 1, opacity: 1))
        session.document?.layers = [layer]
        session.activeLayerID = layer.id
        let document = try #require(session.document)
        func sample(_ x: Int, _ y: Int) throws -> [UInt8] {
            let context = try BrushRaster.context(width: 32, height: 32, mask: false)
            session.drawLiveComposite(document, in: context)
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let i = y * context.bytesPerRow + x * 4
            return Array(UnsafeBufferPointer(start: bytes + i, count: 4))
        }
        // Nothing made yet: the layer is drawn plain, and nothing was rendered for it.
        #expect(try sample(6, 16) == [0, 0, 0, 0])
        #expect(LayerEffectsRenderer.existing(image, mask: nil, effects: layer.effects) == nil)

        // With the canvas's preview made, the composite shows it.
        let preview = try EffectsPreviewCache.render(image, mask: nil, effects: try #require(layer.effects), sideLimit: 1536)
        session.effectsPreviews.seed(layer.id, image: preview.image,
                                     placement: LayerEffectsRenderer.placed(layer.transform, image: preview.image, inset: preview.inset))
        #expect(try sample(6, 16)[2] > 200)
        #expect(LayerEffectsRenderer.existing(image, mask: nil, effects: layer.effects) == nil)

        // Off the main actor (merge, copy, export) effects are still drawn at full size.
        let full = try session.liveComposite(document).render()
        let context = try BrushRaster.context(width: 32, height: 32, mask: false)
        BrushRaster.draw(full, in: CGRect(x: 0, y: 0, width: 32, height: 32), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[16 * context.bytesPerRow + 6 * 4 + 2] > 200)
        #expect(LayerEffectsRenderer.existing(image, mask: nil, effects: layer.effects) != nil)
    }
}
