import AppKit
import Testing
@testable import Compositor

/// Object Selection's Vision model isn't deterministic enough to pin down here; what is around it is.
@MainActor
struct ObjectSelectionTests {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func aPointOffTheImageSelectsNothing() throws {
        let image = try image(width: 30, height: 20)
        for point in [CGPoint(x: -1, y: 5), CGPoint(x: 30, y: 5), CGPoint(x: 5, y: 20), CGPoint(x: CGFloat.nan, y: 5),
                      CGPoint(x: 5, y: CGFloat.infinity)] {
            #expect(try ObjectSelection.select(in: image, at: point, edgeOffset: 0, smoothEdges: true) == nil, "\(point)")
        }
    }

    @Test func aClickOffTheCanvasLeavesTheSelectionAndHistoryAlone() async throws {
        let session = EditorSession()
        session.createDocument(width: 30, height: 20)
        let image = try image(width: 30, height: 20)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Green"))
        session.applySelection(CGPath(rect: CGRect(x: 2, y: 2, width: 5, height: 5), transform: nil), mode: .replace, name: "Select")
        let selection = session.selection, count = session.history.undoCount
        await session.selectObject(at: CGPoint(x: 31, y: 4), mode: .replace)
        await session.selectObject(at: CGPoint(x: 4, y: -0.5), mode: .add)
        #expect(session.selection == selection && session.history.undoCount == count && !session.isProjectBusy)
    }

    /// What the selection tools read: the active layer's own pixels where it is shown, or everything visible.
    @Test func theSampleIsTheActiveLayerOrTheComposite() throws {
        let session = EditorSession()
        session.createDocument(width: 30, height: 20)
        let image = try image(width: 10, height: 10)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Square"), centeredAt: CGPoint(x: 10, y: 10))
        session.setLayerOpacity(0.5)
        let document = try #require(session.document)
        func alpha(_ sample: CGImage, _ x: Int, _ y: Int) throws -> UInt8 {
            let context = try BrushRaster.context(width: sample.width, height: sample.height, mask: false)
            BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height), mask: false, context: context)
            return try #require(context.data).assumingMemoryBound(to: UInt8.self)[y * context.bytesPerRow + x * 4 + 3]
        }
        let own = try #require(session.selectionSource(document, sampleAllLayers: false)).render()
        let all = try #require(session.selectionSource(document, sampleAllLayers: true)).render()
        #expect(own.width == 30 && own.height == 20 && all.width == 30 && all.height == 20)
        #expect(try alpha(own, 10, 10) == 255 && alpha(own, 2, 2) == 0)   // Its own pixels, opacity aside.
        #expect(try (127...128).contains(alpha(all, 10, 10)) && alpha(all, 2, 2) == 0) // As the canvas shows it.
    }

    /// The session's click turns a non-finite point away too, before Vision or any `Int(_:)` sees it.
    @Test func aNonFiniteClickLeavesTheSelectionAlone() async throws {
        let session = EditorSession()
        session.createDocument(width: 30, height: 20)
        let image = try image(width: 30, height: 20)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Green"))
        session.applySelection(CGPath(rect: CGRect(x: 2, y: 2, width: 5, height: 5), transform: nil), mode: .replace, name: "Select")
        let selection = session.selection, count = session.history.undoCount
        for point in [CGPoint(x: CGFloat.nan, y: 4), CGPoint(x: 4, y: CGFloat.nan), CGPoint(x: CGFloat.infinity, y: 4),
                      CGPoint(x: 4, y: -CGFloat.infinity)] {
            await session.selectObject(at: point, mode: .replace)
        }
        #expect(session.selection == selection && session.history.undoCount == count && !session.isProjectBusy)
    }

    // MARK: Edge offset, against the Swift it replaced

    private enum Reference {
        static func adjusted(binaryMask: [UInt8], width: Int, height: Int, edgeOffset: Int) -> [UInt8] {
            var mask = binaryMask
            let steps = min(10, abs(edgeOffset))
            guard steps > 0, width > 0, height > 0 else { return mask }
            for _ in 0..<steps {
                mask = edgeOffset > 0 ? eroded(mask, width: width, height: height) : dilated(mask, width: width, height: height)
            }
            return mask
        }
        static func eroded(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
            var result = mask
            for y in 0..<height {
                for x in 0..<width where mask[y * width + x] != 0 {
                    var keep = true
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] == 0 {
                            keep = false
                        }
                    }
                    result[y * width + x] = keep ? 255 : 0
                }
            }
            return result
        }
        static func dilated(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
            var result = mask
            for y in 0..<height {
                for x in 0..<width where mask[y * width + x] == 0 {
                    var fill = false
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] != 0 {
                            fill = true
                        }
                    }
                    if fill { result[y * width + x] = 255 }
                }
            }
            return result
        }
    }

    /// Blobs, single pixels, lines one pixel wide and the image's own edges, with stray values other than 255.
    private func blobs(width: Int, height: Int, seed: UInt32) -> [UInt8] {
        var state = seed
        func next() -> UInt32 { state = state &* 1_664_525 &+ 1_013_904_223; return state >> 8 }
        var mask = [UInt8](repeating: 0, count: width * height)
        for _ in 0..<(width * height / 12) {
            let cx = Int(next() % UInt32(width)), cy = Int(next() % UInt32(height)), r = Int(next() % 4)
            let value: UInt8 = next() % 5 == 0 ? UInt8(1 + next() % 254) : 255
            for y in max(0, cy - r)...min(height - 1, cy + r) {
                for x in max(0, cx - r)...min(width - 1, cx + r) { mask[y * width + x] = value }
            }
        }
        // Too small for any blobs: one set corner, or none.
        if seed % 2 == 1 { mask[0] = 255 }
        return mask
    }

    @Test(arguments: [(1, 1), (1, 9), (9, 1), (2, 2), (37, 23), (64, 48)])
    func edgeOffsetMatchesTheSwiftItReplaced(_ size: (Int, Int)) throws {
        let (width, height) = size
        for seed in [UInt32(1), 7, 42] {
            let mask = blobs(width: width, height: height, seed: seed)
            for offset in [-11, -10, -3, -1, 0, 1, 2, 5, 10, 12] {
                let fast = try ObjectSelection.adjusted(binaryMask: mask, width: width, height: height, edgeOffset: offset)
                let slow = Reference.adjusted(binaryMask: mask, width: width, height: height, edgeOffset: offset)
                #expect(fast == slow, "\(width)×\(height) seed \(seed) offset \(offset)")
            }
        }
    }
}
