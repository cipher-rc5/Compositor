import SwiftUI

enum NavigationTool: String, CaseIterable {
    case move, marquee, lasso, wand, crop, brush, spotHealing, cloneStamp, blur, gradient, shape, type, eyedropper, hand, zoom
    /// No tool (A): nothing in the tool rail is selected and canvas clicks do nothing.
    case idle
    /// Tools that paint with the brush tip, sharing its size, hardness, opacity, and keys.
    var isBrushTool: Bool { self == .brush || self == .spotHealing || self == .cloneStamp || self == .blur }
    /// Tools that draw and edit selections, sharing modifiers, moving, and nudging.
    var isSelectionTool: Bool { self == .marquee || self == .lasso || self == .wand }
    var symbol: String {
        switch self {
        case .move: "arrow.up.left.and.arrow.down.right"
        case .marquee: "rectangle.dashed"
        case .lasso: "lasso"
        case .wand: "wand.and.stars"
        case .crop: "crop"
        case .brush: "paintbrush.pointed"
        case .spotHealing: "bandage"
        case .cloneStamp: "seal"
        case .blur: "drop"
        case .gradient: "square.bottomhalf.filled"
        case .shape: "square.on.circle"
        case .type: "textformat"
        case .eyedropper: "eyedropper"
        case .hand: "hand.draw"
        case .zoom: "magnifyingglass"
        case .idle: "cursorarrow"
        }
    }
    var label: String {
        switch self {
        case .move: "Move / Transform (V)"
        case .marquee: "Marquee (M)"
        case .lasso: "Lasso (L)"
        case .wand: "Magic (W) · Tab switches Wand and Object"
        case .crop: "Crop (C)"
        case .brush: "Brush (B) · Eraser (E)"
        case .spotHealing: "Spot Healing Brush (J)"
        case .cloneStamp: "Clone Stamp (S) · Option-click sets the source"
        case .blur: "Smear (R)"
        case .gradient: "Gradient (G)"
        case .shape: "Shape (U) · Shift-U switches Rectangle/Ellipse"
        case .type: "Type (T)"
        case .eyedropper: "Eyedropper (I)"
        case .hand: "Hand (H)"
        case .zoom: "Zoom (Z)"
        case .idle: "No Tool (A)"
        }
    }
}

/// Something in progress that the rest of the editor has to wait for or work around: a sheet, a stroke, an open
/// adjustment panel, a pending transform. `canStartProjectOperation`, `canUseHistory` and `canEditLayers` are all
/// derived from the set that is active, and each case says here, exhaustively, which of them it blocks — so a new
/// state can't be added to one gate and forgotten in the others.
enum EditorModal: CaseIterable, Hashable {
    /// A save, open, resize or other long operation (`isProjectBusy`).
    case busy
    case importing
    /// A sheet or alert over the window: New Canvas, the file importer, an import error, the Photoshop conversion
    /// sheet or the RAW develop sheet.
    case dialog
    case renamingLayer
    /// A brush, Smudge or Liquify stroke.
    case stroke
    case typing
    /// Expand, Contract or Feather's panel.
    case selectionAmount
    case levels
    case hueSaturation
    /// A Filter or Image adjustment panel, Camera Raw included.
    case filter
    /// An adjustment layer's settings being edited.
    case adjustmentLayer
    /// Selected pixels being dragged (Cmd-drag), not yet committed.
    case pixelMove
    case transform
    case crop
    /// A gradient drawn but not yet applied.
    case gradient

    /// Crop and transform don't hold project operations up: `ProjectController` cancels the one and commits the other
    /// before it starts. Nor does a pending gradient, which stays on the canvas, unapplied, like a crop box: holding
    /// Save up until it is applied would leave ⌘S dead after every gradient. Everything else is either modal or a
    /// preview the operation would read the document from under.
    var blocksProjectOperations: Bool {
        switch self {
        case .transform, .crop, .gradient: false
        case .busy, .importing, .dialog, .renamingLayer, .stroke, .typing, .selectionAmount, .levels, .hueSaturation,
             .filter, .adjustmentLayer, .pixelMove: true
        }
    }

    /// Undo and Redo. A pending crop or gradient doesn't block them: the first Undo cancels it, as in Photoshop.
    /// Adjustment panels do, since they hold an open history step and a preview of the layer as it is now.
    var blocksHistory: Bool {
        switch self {
        case .crop, .gradient: false
        case .busy, .importing, .dialog, .renamingLayer, .stroke, .typing, .selectionAmount, .levels, .hueSaturation,
             .filter, .adjustmentLayer, .pixelMove, .transform: true
        }
    }

    /// Adding, deleting, reordering or restyling layers. Every modal state blocks it: each holds a layer, or the
    /// whole document, that a layer edit could pull out from under it.
    var blocksLayerEdits: Bool {
        switch self {
        case .busy, .importing, .dialog, .renamingLayer, .stroke, .typing, .selectionAmount, .levels, .hueSaturation,
             .filter, .adjustmentLayer, .pixelMove, .transform, .crop, .gradient: true
        }
    }
}
