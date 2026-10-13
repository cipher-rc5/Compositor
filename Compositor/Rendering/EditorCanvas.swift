import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.consumeFocusRequest(session.canvasFocusRequest)
        _ = session.showsTransformControls // observed here so ⌘H redraws the transform box at once
        _ = session.showsGrid
        _ = session.showsGuides
        _ = session.guideDrag
        _ = session.document?.guides
        view.synchronizeDisplay()
        view.window?.isDocumentEdited = session.isModified
    }
}

final class CanvasView: NSView {
    var inlineTextEditor: InlineTextEditor?
    var textBoxAnchor: CGPoint?
    var textBoxRect: CGRect?
    private var lastFocusRequest = 0
    func consumeFocusRequest(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            if self.session.textDraft == nil { window.makeFirstResponder(self) }
        }
    }
    let sampleRing = SampleRingOverlay()
    var samplingOriginal = PaletteColor.black
    let session: EditorSession
    var spaceHeld = false
    var panPhysicalKey: UInt16?
    var brushPointer: CGPoint?
    /// The layer being drawn into a surface for SeparableBlend, which draws it plainly and blends it afterwards.
    var normalBlendLayerID: UUID?
    let brushCursor = BrushCursorOverlay()
    var lastDragPoint: CGPoint?
    /// Where a middle-button pan last was (see otherMouseDown).
    var middlePanPoint: CGPoint?
    /// Where Shift was last pressed in the stroke in progress (or where the stroke started, if it was held then):
    /// the line the stroke is kept on while Shift stays down.
    var brushAxisAnchor: CGPoint?
    /// The axis that line runs along, chosen by which way the stroke first moves once Shift is down.
    var brushAxisHorizontal: Bool?
    /// Where the stroke last went, so pressing Shift mid-stroke locks from there rather than from its start.
    var brushLastPixel: CGPoint?
    var transformDrag: TransformDrag? {
        didSet { if transformDrag == nil { releaseDragCursor() } }
    }
    var dragCursor: NSCursor?
    weak var cursorLockWindow: NSWindow?
    var cropDrag: CropDrag? {
        didSet { if cropDrag == nil { releaseDragCursor() } }
    }
    var guideDragging = false {
        didSet { if !guideDragging { releaseDragCursor() } }
    }
    let transformOverlay: TransformOverlay
    private var displayedState: DisplayState?
    private var displayedTool: NavigationTool?
    private var displayedPicking = false
    private var displayedTargeting = false
    var optionHeld = false
    var palettePicking: Bool { session.tool == .eyedropper || (optionHeld && (session.tool == .brush || session.tool == .spotHealing || session.tool == .gradient) && session.brushStroke == nil && gradientDrag == nil) }
    var picking: Bool {
        palettePicking || session.colorPicker != nil || session.hueSampleMode != nil || session.levels?.sampleMode != nil
            || session.filterEdit?.samplesWhiteBalance == true || session.filterEdit?.samplesPointColor == true
            || session.filterEdit?.samplesDefringe == true
            || session.filterEdit?.drawingCameraRawGeometryGuide == true
    }
    /// View point where a targeted-adjustment drag began.
    var hueTargetStart: CGPoint?
    var samplingColor = false
    enum GradientHandle { case start, end }
    var gradientDrag: GradientHandle?
    private var antsTimer: Timer?
    var modifierMonitor: Any?
    var keyMonitor: Any?
    /// Document point where a selection-outline drag began.
    var selectionDragStart: CGPoint?
    /// Document point where a Cmd-drag of the selected pixels began.
    var pixelDragStart: CGPoint?
    var duplicatesTransformOnDrag = false
    /// Snapping for the crop drag in progress, built when it starts (the zoom can't change mid-drag).
    var cropSnap: CropSnap?
    /// How close, in screen points, a crop edge comes to a layer or canvas edge before it snaps.
    static let cropSnapDistance: CGFloat = 8
    /// Whether Shift squares the Marquee draft. False while a Shift held at the press (which chose Add)
    /// is still down; letting it go arms it, so pressing Shift again squares the shape.
    var marqueeConstrainArmed = true
    /// The Marquee draft's latest drag point, so a Shift change can reshape it without a mouse move.
    var marqueeDragPixel: CGPoint?
    /// While a Marquee is dragged against or past the canvas edge, pans the view toward the pointer.
    var marqueeAutoscroll: Timer?
    var marqueeAutoscrollPoint: CGPoint?
    private var displayedCropRect: CGRect?
    private var displayedTransformGeometry: TransformOverlayGeometry?
    private var hoverTrackingArea: NSTrackingArea?
    /// A Zoom tool press: dragging left or right zooms smoothly about where it began; a press that doesn't move
    /// zooms a step on release instead.
    var zoomDrag: (start: CGPoint, zoom: CGFloat, moved: Bool)?
    /// The effects surface for the layer being painted, made when the stroke starts and updated as it goes.
    var strokeSurface: LayerEffectsSurface?
    var cloneTipCache: (diameter: CGFloat, hardness: CGFloat, image: CGImage?)?
    var clonePreviewCache: (key: ClonePreviewKey, image: CGImage?)?
    /// Right-drag with a brush tool: left and right resize the brush from its size at the press, or with Shift
    /// change its hardness. The brush circle stays where the press was.
    var brushTipDrag: (start: CGPoint, diameter: CGFloat, hardness: CGFloat, hardnessShown: Bool)?

    private struct DisplayState: Equatable {
        struct Layer: Equatable {
            let id: UUID
            let transform: LayerTransform
            let imageID: ObjectIdentifier?
            let maskID: ObjectIdentifier?
            let maskSourceID: UUID?
            /// Moving a layer into or out of a masked folder changes how it is clipped.
            let parentID: UUID?
            let visible: Bool
            let opacity: Double
            let blendMode: LayerBlendMode
            let adjustment: LayerAdjustment?
            let effects: LayerEffects?
            /// Where the mask shows when placed apart from the layer.
            let maskPlacement: LayerTransform?
        }
        let brushRevision: Int
        let pixelGrid: Bool
        let documentID: UUID?
        let size: CGSize?
        let renderBounds: CGRect?
        let viewport: CanvasViewport
        let layers: [Layer]
        /// Folders have no pixels, so their masks are tracked apart from `layers`.
        struct FolderMask: Equatable {
            let id: UUID
            let maskID: ObjectIdentifier?
            let transform: LayerTransform
        }
        let folderMasks: [FolderMask]
    }

    @discardableResult
    func synchronizeDisplay() -> Bool {
        // The stroke is over: what its surface holds stands in until the layer's own effects have been rebuilt from
        // the pixels it left, so nothing blinks at the end of a stroke.
        if session.brushStroke == nil, let surface = strokeSurface {
            if let built = surface.image, let placement = surface.placement {
                session.effectsPreviews.seed(surface.layerID, image: built, placement: placement)
            }
            // A pass still running holds the stroke's latest paint; it takes the seed's place when it lands. The
            // closure keeps the surface alive until then.
            surface.whenSettled { [weak self] in
                guard let built = surface.image, let placement = surface.placement else { return }
                self?.session.effectsPreviews.refreshSeed(surface.layerID, image: built, placement: placement)
                self?.needsDisplay = true
            }
            strokeSurface = nil
        }
        synchronizeInlineText()
        if session.tool != .type, textBoxRect != nil { textBoxAnchor = nil; textBoxRect = nil; needsDisplay = true }
        // Image identity detects raster replacement without comparing pixel data.
        let document = session.document
        // Folders hold no pixels and so aren't listed below; their opacity reaches the canvas
        // through the layers inside them, which is what has to be watched for a change.
        let opacities = document?.effectiveOpacities ?? [:]
        // Worked out once here: it walks every layer's folders, so asking per layer cost O(layers²) on every event.
        let visible = document?.effectiveVisibleIDs ?? []
        let state = DisplayState(brushRevision: session.brushRevision, pixelGrid: session.showsPixelGrid, documentID: document?.id, size: document?.size, renderBounds: renderBounds, viewport: session.viewport,
            layers: (document.map { $0.layers.contains(where: { $0.maskSourceID != nil }) ? $0.layers : $0.renderLayers } ?? []).filter { $0.asset != nil || $0.adjustment != nil }.map {
                DisplayState.Layer(id: $0.id, transform: session.displayedTransform(for: $0),
                                   imageID: $0.asset.map { ObjectIdentifier($0.image) }, maskID: $0.mask?.enabledImage.map { ObjectIdentifier($0) }, maskSourceID: $0.maskSourceID, parentID: $0.parentID, visible: visible.contains($0.id), opacity: opacities[$0.id] ?? $0.opacity, blendMode: session.displayedBlendMode(for: $0), adjustment: $0.adjustment, effects: $0.effects,
                                   maskPlacement: session.displayedMaskPlacement(for: $0))
            },
            folderMasks: (document?.layers ?? []).filter { $0.isGroup && $0.mask != nil }.map {
                DisplayState.FolderMask(id: $0.id, maskID: $0.mask?.enabledImage.map { ObjectIdentifier($0) },
                                        transform: session.displayedTransform(for: $0))
            })
        var changed = false
        if displayedState != state {
            if let previous = displayedState, previous.documentID == state.documentID,
               previous.size == state.size, previous.viewport == state.viewport,
               previous.renderBounds == state.renderBounds, previous.layers == state.layers,
               previous.folderMasks == state.folderMasks,
               let stroke = session.brushStroke, let document,
               let dirty = stroke.dirtyDocumentRect {
                let origin = session.viewport.viewPoint(from: dirty.origin, documentSize: document.size)
                let scale = session.viewport.pointsPerPixel
                setNeedsDisplay(CGRect(origin: origin, size: CGSize(width: dirty.width * scale, height: dirty.height * scale)).insetBy(dx: -2, dy: -2))
            } else { needsDisplay = true }
            displayedState = state
            changed = true
        }
        if displayedTool != session.tool {
            displayedTool = session.tool
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if displayedPicking != picking || displayedTargeting != session.hueTargeting {
            displayedPicking = picking
            displayedTargeting = session.hueTargeting
            samplingColor = false
            sampleRing.isHidden = true
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            if picking, let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                Self.eyedropperCursor.set()
            }
        }
        if displayedCropRect != transformOverlay.cropViewRect {
            displayedCropRect = transformOverlay.cropViewRect
            window?.invalidateCursorRects(for: self)
        }
        if displayedTransformGeometry != transformOverlay.geometry {
            displayedTransformGeometry = transformOverlay.geometry
            window?.invalidateCursorRects(for: self)
        }
        updateBrushCursor()
        updateAntsTimer()
        // Observe selection only for the lightweight handles overlay.
        _ = session.activeLayerID
        _ = session.cropRect
        transformOverlay.needsDisplay = true
        redrawRulers()
        return changed
    }

    func redrawRulers() {
        func find(_ view: NSView) {
            if view is CanvasRulerNSView { view.needsDisplay = true }
            view.subviews.forEach(find)
        }
        window?.contentView.map(find)
    }

    init(session: EditorSession) {
        self.session = session
        transformOverlay = TransformOverlay(session: session)
        super.init(frame: .zero)
        session.refreshCanvasPreview = { [weak self] in
            self?.synchronizeDisplay()
            self?.displayIfNeeded()
        }
        addSubview(transformOverlay)
        addSubview(brushCursor)
        addSubview(sampleRing)
        // Each overlay draws into its own layer. Without one, redrawing a transparent overlay (every crop
        // or transform drag, marching-ants tick, or cursor move) makes AppKit redraw the canvas beneath —
        // the whole checkerboard and layer composite. All three get layers so they keep their stacking order.
        for overlay in [transformOverlay, brushCursor, sampleRing] as [NSView] { overlay.wantsLayer = true }
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Canvas")
        setAccessibilityIdentifier("editorCanvas")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        transformOverlay.frame = bounds
        brushCursor.frame = bounds
        syncGeometry()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncGeometry()
        // Off its window the canvas is never drawn, so the ants stop rather than tick for nothing; back on one,
        // they start again if there is still a selection.
        updateAntsTimer()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard window != nil else { return }
        optionHeld = NSEvent.modifierFlags.contains(.option)
        // A tab mounts a new canvas. Restore keyboard focus after SwiftUI finishes
        // installing it, without taking focus from a newly presented dialog.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.document != nil, let window = self.window,
                  window.attachedSheet == nil, !self.session.showsNewDocument,
                  !self.session.showsImporter, self.session.colorPicker == nil else { return }
            window.makeFirstResponder(self)
        }
        installEventMonitors()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncGeometry() }

    private func syncGeometry() {
        // Defer observable mutations until after SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let scale = self.convertToBacking(CGSize(width: 1, height: 1)).width
            guard self.session.viewport.viewSize != self.bounds.size ||
                    self.session.viewport.backingScale != scale else { return }
            self.session.viewport.resize(to: self.bounds.size, backingScale: scale,
                                         documentSize: self.session.document?.size)
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // On screen, a reduction or painted layer's pieces not made yet are built off the draw and redrawn when they
        // land (see CacheMissDeferral); an offscreen render, such as a snapshot, waits for them instead.
        let deferral = window?.isVisible == true ? CacheMissDeferral { [weak self] in
            Task { @MainActor in self?.needsDisplay = true }
        } : nil
        CacheMissDeferral.$current.withValue(deferral) { drawCanvas(dirtyRect) }
    }

    override func resetCursorRects() { addCanvasCursorRects() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        // Every tool hears the mouse leave, so its cursor never follows it out of the canvas;
        // only tools whose cursor depends on where the pointer is also track movement.
        // The picker panel stays key, so sampling must track while this window is not.
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, picking ? .activeAlways : .activeInKeyWindow, .inVisibleRect]
        if picking || session.tool == .move || session.tool.isBrushTool || session.tool.isSelectionTool {
            options.formUnion([.mouseMoved, .cursorUpdate])
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { handleMouseExited(with: event) }
    override func mouseMoved(with event: NSEvent) { handleMouseMoved(with: event) }
    override func cursorUpdate(with event: NSEvent) { handleCursorUpdate(with: event) }
    override func rightMouseDown(with event: NSEvent) { handleRightMouseDown(with: event) }
    override func rightMouseDragged(with event: NSEvent) { handleRightMouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { handleRightMouseUp(with: event) }
    override func mouseDown(with event: NSEvent) { handleMouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { handleMouseDragged(with: event) }
    override func otherMouseDown(with event: NSEvent) { handleOtherMouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { handleOtherMouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { handleOtherMouseUp(with: event) }
    override func mouseUp(with event: NSEvent) { handleMouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) { handleScrollWheel(with: event) }
    override func magnify(with event: NSEvent) { handleMagnify(with: event) }
    override func keyDown(with event: NSEvent) { handleKeyDown(with: event) }
    override func keyUp(with event: NSEvent) { handleKeyUp(with: event) }

    override func resignFirstResponder() -> Bool {
        if !session.isProjectBusy { session.cancelBrush() }
        brushPointer = nil
        updateBrushCursor()
        cropDrag = nil
        gradientDrag = nil
        session.cancelShape()
        if let kind = session.lassoDraft?.kind, kind != .polygonal { session.cancelLasso() }
        if selectionDragStart != nil { selectionDragStart = nil; session.endSelectionMove() }
        if pixelDragStart != nil { pixelDragStart = nil; session.cancelPixelMove() }
        if let drag = transformDrag {
            duplicatesTransformOnDrag = false
            session.previewTransform(drag.original)
            if session.transformEdit?.persistent == false { session.cancelTransform() }
            transformDrag = nil
        }
        spaceHeld = false
        lastDragPoint = nil
        return super.resignFirstResponder()
    }

    /// Marching ants animate only while a visible selection exists.
    private func updateAntsTimer() {
        let active = session.selection?.isEmpty == false && window != nil
        if active, antsTimer == nil {
            // Timer's closure is @Sendable, but this one is added to the main run loop below,
            // so it only ever fires on the main thread.
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.transformOverlay.antsPhase = (self.transformOverlay.antsPhase + 1).truncatingRemainder(dividingBy: 8)
                    self.transformOverlay.needsDisplay = true
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            antsTimer = timer
        } else if !active, let timer = antsTimer {
            timer.invalidate()
            antsTimer = nil
        }
    }

    var renderBounds: CGRect? {
        guard let document = session.document else { return nil }
        let original = CGRect(origin: .zero, size: document.size)
        return session.tool == .crop ? original.union(session.cropRect ?? original) : original
    }
}
