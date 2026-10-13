import SwiftUI

nonisolated struct ImageLayer: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isVisible == rhs.isVisible && lhs.transform == rhs.transform
            && lhs.asset?.image === rhs.asset?.image && lhs.parentID == rhs.parentID && lhs.isGroup == rhs.isGroup && lhs.opacity == rhs.opacity && lhs.blendMode == rhs.blendMode && lhs.mask == rhs.mask && lhs.maskSourceID == rhs.maskSourceID && lhs.adjustment == rhs.adjustment && lhs.shape == rhs.shape && lhs.text == rhs.text && lhs.effects == rhs.effects
    }
    let id: UUID
    var asset: ImportedImage?
    var transform: LayerTransform
    var origin: CGPoint { transform.origin }
    var name: String
    var isVisible = true
    var parentID: UUID?
    var isGroup = false
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    var maskSourceID: UUID?
    var mask: LayerMask?
    var adjustment: LayerAdjustment?
    /// Set on layers the Shape tool made; see `liveShape`.
    var shape: LayerShape?
    /// Layer effects (stroke, shadows, glows, color overlay) drawn with the layer, kept apart from its pixels.
    var effects: LayerEffects?
    var text: LayerText?
    var size: CGSize { transform.size }

    init(asset: ImportedImage, origin: CGPoint) {
        self.id = UUID()
        self.asset = asset
        self.transform = LayerTransform(origin: origin, size: CGSize(width: asset.image.width, height: asset.image.height))
        self.name = asset.name
    }

    init(name: String, blankSize: CGSize) {
        self.id = UUID()
        self.asset = nil // Allocate pixels when painting begins, not when adding an empty layer.
        self.transform = LayerTransform(origin: .zero, size: blankSize)
        self.name = name
    }

    init(id: UUID, asset: ImportedImage?, name: String, isVisible: Bool, transform: LayerTransform, parentID: UUID? = nil, isGroup: Bool = false, opacity: Double = 1, blendMode: LayerBlendMode = .normal, mask: LayerMask? = nil, maskSourceID: UUID? = nil, adjustment: LayerAdjustment? = nil, shape: LayerShape? = nil, effects: LayerEffects? = nil, text: LayerText? = nil) {
        self.id = id
        self.asset = asset
        self.name = name
        self.isVisible = isVisible
        self.transform = transform
        self.parentID = parentID
        self.isGroup = isGroup
        self.opacity = opacity
        self.blendMode = blendMode
        self.mask = mask
        self.maskSourceID = maskSourceID
        self.adjustment = adjustment
        self.shape = shape
        self.effects = effects
        self.text = text
    }

    /// This layer holding new pixels. Everything else carries over, effects included; live shape and text
    /// metadata is dropped, since it no longer describes these pixels. Edits that replace a layer's pixels
    /// go through here rather than the memberwise init, whose defaults would quietly clear anything left out.
    func replacingPixels(_ asset: ImportedImage, transform: LayerTransform? = nil, mask: LayerMask?) -> ImageLayer {
        var copy = self
        copy.asset = asset
        copy.transform = transform ?? self.transform
        copy.mask = mask
        copy.shape = nil
        copy.text = nil
        return copy
    }
}

struct CanvasDocument: Equatable {
    let id: UUID
    let width: Int
    let height: Int
    var resolution: Double = 72
    var layers: [ImageLayer] = [] // Bottom to top.
    /// User-placed alignment lines. Saved with the project; undo covers them.
    var guides: [CanvasGuide] = []
    /// Part of the document so undo/redo covers selection changes. Not saved to disk.
    var selection: DocumentSelection?
    var size: CGSize { CGSize(width: width, height: height) }
    /// "Layer 1", "Folder 2", …: the first of `prefix` numbered from 1 that no layer is called yet.
    func unusedName(_ prefix: String) -> String {
        let names = Set(layers.map(\.name))
        var number = 1
        while names.contains("\(prefix) \(number)") { number += 1 }
        return "\(prefix) \(number)"
    }
    init(id: UUID = UUID(), width: Int, height: Int, layers: [ImageLayer] = [], resolution: Double = 72, guides: [CanvasGuide] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.layers = layers
        self.resolution = resolution
        self.guides = guides
    }

    // Geometry limit; raster memory limits will be established with image import.
    static func validDimension(_ value: String) -> Int? {
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)),
              (1...30_000).contains(n) else { return nil }
        return n
    }
}
