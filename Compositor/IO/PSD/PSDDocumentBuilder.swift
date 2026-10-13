import CoreGraphics
import Foundation

nonisolated struct PSDImport: Sendable {
    let width: Int
    let height: Int
    let resolution: Double
    let layers: [ImageLayer]
    let conversions: [PSDConversion]
}

nonisolated enum PSDDocumentBuilder {
    static func assets(from document: PSDDocument) throws -> [UUID: ImportedImage] {
        var result: [UUID: ImportedImage] = [:]
        for record in document.layers {
            guard let image = record.image else { continue }
            result[record.id] = try imported(image, name: record.name)
        }
        return result
    }

    @MainActor
    static func makeImport(_ document: PSDDocument, assets: [UUID: ImportedImage] = [:]) throws -> PSDImport {
        var conversions: [PSDConversion] = []
        var layers: [ImageLayer] = []
        let canvas = CGSize(width: document.width, height: document.height)
        for record in document.layers {
            if record.isDissolved {
                let lost = record.mask == nil ? "" : " Its mask was not kept."
                conversions.append(PSDConversion(layerName: record.name, message:
                    "Folders can be nested \(PSDReader.maximumFolderDepth) deep. This folder was removed and its layers moved into the folder above.\(lost)"))
                continue
            }
            var notes: [String] = []
            if record.kind == .text {
                notes.append("Editable Photoshop text becomes pixels and can’t be retyped.")
            }
            if record.kind == .smartObject {
                notes.append("The smart object was rasterized. Linked contents can’t be edited.")
            }
            if record.kind == .effects {
                notes.append("Layer effects were discarded, so the appearance may differ.")
            }
            if record.kind == .vector {
                if record.shape != nil {
                    notes.append(contentsOf: record.shapeNotes)
                } else {
                    notes.append("Vector shape was rasterized to pixels.")
                }
            }
            if record.isGroup {
                if record.blendKey != "pass" && record.blendKey != "norm" {
                    notes.append("Folder blend mode “\(record.blendKey)” isn’t supported. The folder will be pass-through.")
                }
            } else if record.blendMode == nil, record.blendKey != "pass" {
                notes.append("Blend mode “\(record.blendKey.trimmingCharacters(in: .whitespaces))” isn’t supported and will be applied as Normal.")
            }
            if record.kind == .adjustment {
                if record.adjustment == nil {
                    notes.append("This adjustment type isn’t supported and was skipped.")
                } else {
                    notes.append("Adjustment parameters may not match Photoshop exactly.")
                }
            }
            for note in notes {
                conversions.append(PSDConversion(layerName: record.name, message: note))
            }
            if record.kind == .adjustment, record.adjustment == nil { continue }
            var layer: ImageLayer
            if record.isGroup {
                // Folders carry an opacity of their own (1.1.6), which multiplies into what's inside
                // them just as Photoshop's group opacity does.
                layer = ImageLayer(id: record.id, asset: nil, name: record.name, isVisible: record.isVisible,
                                   transform: LayerTransform(origin: .zero, size: canvas), parentID: record.parentID,
                                   isGroup: true, opacity: min(1, max(0, record.opacity)))
            } else if let adjustment = record.adjustment {
                layer = ImageLayer(id: record.id, asset: nil, name: record.name, isVisible: record.isVisible,
                                   transform: LayerTransform(origin: .zero, size: canvas), parentID: record.parentID,
                                   opacity: min(1, max(0, record.opacity)),
                                   blendMode: record.blendMode ?? .normal, adjustment: adjustment)
            } else if let image = record.image {
                let asset = try assets[record.id] ?? imported(image, name: record.name)
                // Projects keep layers within a million pixels of the canvas. Anything further out is far
                // off the canvas either way, so it is moved in to that edge rather than refused.
                func clamped(_ value: CGFloat) -> CGFloat { min(1_000_000, max(-1_000_000, value)) }
                let origin = CGPoint(x: clamped(record.bounds.minX), y: clamped(record.bounds.minY))
                let size = record.bounds.size.width > 0 && record.bounds.size.height > 0
                    ? record.bounds.size
                    : CGSize(width: image.width, height: image.height)
                layer = ImageLayer(id: record.id, asset: asset, name: record.name, isVisible: record.isVisible,
                                   transform: LayerTransform(origin: origin, size: size), parentID: record.parentID,
                                   opacity: min(1, max(0, record.opacity)),
                                   blendMode: record.blendMode ?? .normal,
                                   shape: record.shape.map { LayerShape(style: $0, image: image) })
            } else {
                layer = ImageLayer(id: record.id, asset: nil, name: record.name, isVisible: record.isVisible,
                                   transform: LayerTransform(origin: .zero, size: canvas), parentID: record.parentID,
                                   opacity: min(1, max(0, record.opacity)),
                                   blendMode: record.blendMode ?? .normal)
            }
            if let maskImage = record.mask, let maskAsset = try? LayerMask.asset(from: maskImage) {
                layer.mask = LayerMask(asset: maskAsset, isEnabled: record.maskEnabled, isLinked: record.maskLinked)
            } else if record.mask != nil {
                conversions.append(PSDConversion(layerName: record.name, message: "The layer mask couldn’t be converted to 8-bit grayscale and was skipped."))
            }
            layers.append(layer)
        }
        let idToIndex = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.element.id, $0.offset) })
        var baseForParent: [UUID?: UUID] = [:]
        for record in document.layers {
            guard let index = idToIndex[record.id] else { continue }
            if record.clipping {
                if let source = baseForParent[record.parentID],
                   let sourceLayer = layers.first(where: { $0.id == source }),
                   !sourceLayer.isGroup, sourceLayer.adjustment == nil {
                    layers[index].maskSourceID = source
                } else {
                    conversions.append(PSDConversion(layerName: record.name, message: "This clipping mask’s base isn’t supported, so clipping was skipped."))
                }
            } else if let layer = idToIndex[record.id].map({ layers[$0] }), !layer.isGroup, layer.adjustment == nil {
                baseForParent[record.parentID] = record.id
            } else {
                baseForParent[record.parentID] = nil
            }
        }
        try validate(layers, width: document.width, height: document.height)
        return PSDImport(width: document.width, height: document.height, resolution: document.resolution,
                         layers: layers, conversions: conversions)
    }

    /// The layers held to the rules a project is saved under. The reader already shapes a file to fit them
    /// (folder depth, names, budgets); this stops anything it missed from becoming a document that can't be saved.
    private static func validate(_ layers: [ImageLayer], width: Int, height: Int) throws {
        let records = layers.map { layer in
            ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible, transform: layer.transform,
                               imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID,
                               isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode,
                               maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled,
                               maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement,
                               maskLinked: layer.mask?.isLinked, shape: layer.shape?.style, effects: layer.effects)
        }
        do {
            try ProjectStore.validate(ProjectManifest(documentID: UUID(), width: width, height: height,
                                                      activeLayerID: nil, layers: records))
        } catch ProjectError.tooLarge {
            throw ImageImportError.tooLarge
        } catch {
            throw PSDError.unrepresentable
        }
    }

    private static func imported(_ image: CGImage, name: String) throws -> ImportedImage {
        ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
    }
}
