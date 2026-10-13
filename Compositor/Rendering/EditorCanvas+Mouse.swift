import AppKit

extension CanvasView {
    func handleMouseExited(with event: NSEvent) {
        session.filterEdit?.cameraRawReadout = nil
        brushPointer = nil
        updateBrushCursor()
        // Tools set their cursor directly while over the canvas, so put the arrow back on the
        // way out. A drag keeps its cursor until mouse-up.
        if NSEvent.pressedMouseButtons == 0 { NSCursor.arrow.set() }
    }
    func handleMouseMoved(with event: NSEvent) {
        if session.filterEdit?.kind == .cameraRaw, let document = session.document {
            let point = convert(event.locationInWindow, from: nil)
            session.updateCameraRawReadout(at: session.viewport.documentPoint(from: point, documentSize: document.size))
        }
        optionHeld = event.modifierFlags.contains(.option)
        if picking { Self.eyedropperCursor.set(); return }
        if session.tool.isSelectionTool {
            // Keys may have changed while the app was in the background.
            session.updateHeldSelectionKeys(shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
            lassoCursor(flags: event.modifierFlags, at: convert(event.locationInWindow, from: nil)).set()
            if session.lassoDraft?.kind == .polygonal, let document = session.document {
                session.moveLassoCursor(to: session.viewport.documentPoint(from: convert(event.locationInWindow, from: nil), documentSize: document.size))
                synchronizeDisplay()
            }
            return
        }
        brushPointer = convert(event.locationInWindow, from: nil)
        updateBrushCursor()
        if session.tool == .move { updateTransformCursor(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags) }
        else { super.mouseMoved(with: event) }
    }
    func handleMouseDown(with event: NSEvent) {
        session.effectSelection = nil
        optionHeld = event.modifierFlags.contains(.option)
        window?.makeFirstResponder(self)
        guard session.document != nil, !session.isProjectBusy, !session.isImporting else { return }
        let point = convert(event.locationInWindow, from: nil)
        if session.filterEdit?.samplesWhiteBalance == true, !spaceHeld, let document = session.document {
            session.sampleCameraRawWhiteBalance(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("filterPanel"))
            return
        }
        if session.filterEdit?.samplesPointColor == true, !spaceHeld, let document = session.document {
            session.sampleCameraRawPointColor(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("filterPanel"))
            return
        }
        if session.filterEdit?.samplesDefringe == true, !spaceHeld, let document = session.document {
            session.sampleCameraRawDefringe(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("filterPanel"))
            return
        }
        if session.filterEdit?.drawingCameraRawGeometryGuide == true, !spaceHeld, let document = session.document {
            session.beginCameraRawGeometryGuide(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if (session.filterEdit?.targetsCameraRawCurve == true || session.filterEdit?.targetsCameraRawMixer == true),
           !spaceHeld, let document = session.document {
            session.beginCameraRawDrag(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if session.levels?.sampleMode != nil, !spaceHeld, let document = session.document {
            session.sampleLevels(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("levelsPanel"))
            return
        }
        if session.levels != nil, !spaceHeld, session.tool != .hand, session.tool != .zoom { return }
        if picking, !spaceHeld {
            if session.colorPicker != nil || (palettePicking && session.hueSampleMode == nil) {
                samplingOriginal = session.colorPicker?.color ?? session.foregroundColor
                samplingColor = true
                sampleColor(at: point)
            } else if let document = session.document {
                session.sampleHueRange(at: session.viewport.documentPoint(from: point, documentSize: document.size))
                FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("adjustmentPanel"))
            }
            return
        }
        if session.hueTargeting, !spaceHeld, let document = session.document {
            if session.beginHueTargeting(at: session.viewport.documentPoint(from: point, documentSize: document.size)) {
                hueTargetStart = point
                NSCursor.resizeLeftRight.set()
            }
            return
        }
        if spaceHeld || session.tool == .hand {
            lastDragPoint = point
            NSCursor.closedHand.set()
        } else if session.tool.isBrushTool, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            // Option-click with Clone Stamp sets where it copies from (with the other brushes it samples a color).
            if session.tool == .cloneStamp, event.modifierFlags.contains(.option) {
                session.setCloneSource(pixel)
                updateBrushCursor()
                window?.invalidateCursorRects(for: self)
                return
            }
            brushPointer = point
            // Shift paints a straight line on from where the last stroke ended, as in Photoshop.
            if event.modifierFlags.contains(.shift), let from = session.shiftLineStart() {
                session.beginBrush(at: from)
                session.continueBrush(at: pixel)
            } else {
                session.beginBrush(at: pixel)
            }
            // Drag events don't wait on the GPU; each one's paint is drawn when it lands (see BrushCoverageQueue).
            session.brushStroke?.deliversCoverageLater = true
            session.brushStroke?.onCoverage = { [weak self] in
                self?.session.brushRevision += 1
                self?.synchronizeDisplay()
            }
            brushAxisAnchor = event.modifierFlags.contains(.shift) ? pixel : nil
            brushAxisHorizontal = nil
            brushLastPixel = pixel
            synchronizeDisplay()
        } else if session.tool.isSelectionTool {
            lassoMouseDown(at: point, event: event)
            refreshLassoCursor()
        } else if session.tool == .gradient {
            beginGradientDrag(at: point)
        } else if session.tool == .type {
            beginTextGesture(at: point, event: event)
        } else if session.tool == .shape, let document = session.document {
            session.beginShape(at: session.viewport.documentPoint(from: point, documentSize: document.size))
        } else if session.tool == .crop {
            beginCropDrag(at: point)
        } else if session.tool == .move {
            if beginGuideDrag(at: point) { return }
            beginTransformDrag(at: point, modifiers: event.modifierFlags)
        } else if session.tool == .zoom {
            zoomDrag = (point, session.viewport.zoom, false)
        }
    }
    func handleMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if session.filterEdit?.drawingCameraRawGeometryGuide == true, session.filterEdit?.cameraRawGuideDraft != nil,
           let document = session.document {
            session.continueCameraRawGeometryGuide(to: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if session.filterEdit?.cameraRawDrag != nil, let document = session.document {
            session.dragCameraRaw(to: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if textBoxAnchor != nil { dragTextGesture(to: point); return }
        if var drag = zoomDrag {
            let dx = point.x - drag.start.x
            if abs(dx) >= 3 { drag.moved = true; zoomDrag = drag }
            // Right zooms in, left out: doubling for every 100 points dragged.
            if drag.moved { session.zoom(to: drag.zoom * pow(2, dx / 100), anchor: drag.start) }
            return
        }
        if samplingColor { sampleColor(at: point); return }
        if let start = hueTargetStart {
            session.dragHueTargeting(byViewDelta: point.x - start.x,
                                     adjustsHue: event.modifierFlags.contains(.command))
            NSCursor.resizeLeftRight.set()
            return
        }
        if let start = pixelDragStart, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            session.movePixels(by: CGSize(width: pixel.x - start.x, height: pixel.y - start.y))
            pixelDragCursor(duplicate: session.pixelMove?.duplicate == true).set()
            synchronizeDisplay()
            return
        }
        if selectionDragStart != nil {
            dragSelection(to: point, flags: event.modifierFlags)
            updateMarqueeAutoscroll(at: point)
            Self.moveSelectionCursor.set()
            synchronizeDisplay()
            return
        }
        if session.tool.isSelectionTool, lastDragPoint == nil, let draft = session.lassoDraft, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            switch draft.kind {
            case .freehand: session.extendLasso(to: pixel)
            case .polygonal: session.moveLassoCursor(to: pixel)
            case .rectangle, .ellipse:
                dragMarqueeDraft(to: pixel, flags: event.modifierFlags)
                updateMarqueeAutoscroll(at: point)
            }
            synchronizeDisplay()
            return
        }
        if session.shapeDraft != nil, lastDragPoint == nil, let document = session.document {
            // Unlike the Marquee, Option has no other job here, so it draws from the center as in Photoshop.
            session.dragShape(to: session.viewport.documentPoint(from: point, documentSize: document.size),
                              square: event.modifierFlags.contains(.shift), fromCenter: event.modifierFlags.contains(.option))
            synchronizeDisplay()
            return
        }
        if let handle = gradientDrag, let edit = session.gradientEdit, let document = session.document {
            var pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            if event.modifierFlags.contains(.shift) {
                pixel = Self.snapped(pixel, around: handle == .start ? edit.end : edit.start)
            }
            session.moveGradient(start: handle == .start ? pixel : nil, end: handle == .end ? pixel : nil)
            synchronizeDisplay()
            return
        }
        brushPointer = point
        updateBrushCursor()
        if session.brushStroke != nil || session.warpStroke != nil, !session.isProjectBusy, let document = session.document {
            var pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            // Shift keeps the stroke straight, horizontal or vertical, from wherever it was pressed; letting go carries
            // on freehand. The axis is settled by the first few pixels of movement, so it doesn't flip mid-line.
            if event.modifierFlags.contains(.shift) {
                let anchor = brushAxisAnchor ?? brushLastPixel ?? pixel
                if brushAxisAnchor == nil { brushAxisAnchor = anchor; brushAxisHorizontal = nil }
                if brushAxisHorizontal == nil, hypot(pixel.x - anchor.x, pixel.y - anchor.y) >= 3 {
                    brushAxisHorizontal = abs(pixel.x - anchor.x) >= abs(pixel.y - anchor.y)
                }
                if let horizontal = brushAxisHorizontal {
                    pixel = horizontal ? CGPoint(x: pixel.x, y: anchor.y) : CGPoint(x: anchor.x, y: pixel.y)
                } else {
                    pixel = anchor
                }
            } else {
                brushAxisAnchor = nil
                brushAxisHorizontal = nil
            }
            brushLastPixel = pixel
            session.continueBrush(at: pixel)
            synchronizeDisplay()
            return
        }
        if guideDragging, let drag = session.guideDrag, let document = session.document {
            dragCursor?.set()
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            session.moveGuideDrag(to: Double(drag.axis == .vertical ? pixel.x : pixel.y))
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        if let drag = cropDrag, session.tool == .crop, !session.isProjectBusy, let document = session.document {
            dragCursor?.set()
            dragCrop(drag, to: point, flags: event.modifierFlags, documentSize: document.size)
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        if let drag = transformDrag, let document = session.document {
            dragCursor?.set()
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            if duplicatesTransformOnDrag {
                duplicatesTransformOnDrag = false
                session.beginDuplicateTransform()
            }
            if let corners = drag.corners(to: pixel, shift: event.modifierFlags.contains(.shift)) {
                session.previewCorners(corners)
                needsDisplay = true
            } else {
                // Dragging, scaling and rotating land on whole pixels and whole degrees; typed values stay exact.
                var draft = drag.updated(to: pixel, lockRatio: session.locksTransformRatio,
                                         shift: event.modifierFlags.contains(.shift),
                                         option: event.modifierFlags.contains(.option)).rounded()
                // Moving snaps to the canvas and the other layers; resizing and rotating are left alone, and
                // Control drags freely.
                if case .move = drag.mode, !event.modifierFlags.contains(.control) {
                    let moving = session.transformEdit?.group.map { Set($0.originals.keys) }
                        ?? Set([session.transformEdit?.layerID].compactMap { $0 })
                    draft = session.snappedMove(draft, moving: moving,
                                                tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001))
                }
                session.previewTransform(draft)
            }
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        guard let last = lastDragPoint else { return }
        session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        lastDragPoint = point
        redrawRulers()
    }
    /// The middle button pans from any tool, without reaching for Space or the Hand tool. It keeps
    /// its own drag point so it can't disturb whatever the left button is in the middle of.
    private func panPoint(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    func handleOtherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, session.document != nil else { super.otherMouseDown(with: event); return }
        middlePanPoint = panPoint(of: event)
        if session.tool.isBrushTool { updateBrushCursor() }
        NSCursor.closedHand.set()
    }
    func handleOtherMouseDragged(with event: NSEvent) {
        guard let last = middlePanPoint else { super.otherMouseDragged(with: event); return }
        let point = panPoint(of: event)
        session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        middlePanPoint = point
        redrawRulers()
    }
    func handleOtherMouseUp(with event: NSEvent) {
        guard middlePanPoint != nil else { super.otherMouseUp(with: event); return }
        middlePanPoint = nil
        // The closed hand was set directly, so put the tool's own cursor back rather than waiting
        // for the next move.
        refreshLassoCursor(event.modifierFlags)
        if session.tool.isBrushTool { updateBrushCursor() }
        window?.invalidateCursorRects(for: self)
    }
    func handleMouseUp(with event: NSEvent) {
        if session.filterEdit?.cameraRawGuideDraft != nil {
            session.commitCameraRawGeometryGuide()
        }
        session.filterEdit?.cameraRawDrag = nil
        if textBoxAnchor != nil { finishTextGesture(); return }
        stopMarqueeAutoscroll()
        if let drag = zoomDrag {
            zoomDrag = nil
            if !drag.moved {
                session.zoom(to: session.viewport.zoom * (event.modifierFlags.contains(.option) ? 0.5 : 2), anchor: drag.start)
            }
            return
        }
        session.snapGuides = ([], [])
        if guideDragging {
            session.finishGuideDrag(delete: isOverRuler(convert(event.locationInWindow, from: nil)))
            guideDragging = false
        }
        if samplingColor {
            samplingColor = false
            sampleRing.isHidden = true
            if session.colorPicker != nil { ColorPickerPanelController.refocus() }
            return
        }
        if session.brushStroke != nil || session.warpStroke != nil, !session.isProjectBusy {
            if let document = session.document {
                session.continueBrush(at: session.viewport.documentPoint(from: convert(event.locationInWindow, from: nil), documentSize: document.size))
            }
            session.finishBrushImmediately()
            synchronizeDisplay()
        }
        if gradientDrag != nil {
            gradientDrag = nil
            session.endGradientDrag()
        }
        if session.shapeDraft != nil {
            session.finishShape()
            synchronizeDisplay()
        }
        if hueTargetStart != nil {
            hueTargetStart = nil
            session.endHueTargeting()
        }
        if pixelDragStart != nil {
            pixelDragStart = nil
            Task { await session.finishPixelMove(); synchronizeDisplay(); refreshLassoCursor() }
        }
        if let start = selectionDragStart {
            selectionDragStart = nil
            let moved = session.selectionMoveOrigin != session.selection
            session.endSelectionMove()
            if !moved, session.tool == .wand, session.wandMode == .object {
                Task { await session.selectObject(at: start, mode: .replace); synchronizeDisplay(); refreshLassoCursor() }
            } else if !moved, session.tool == .wand {
                // The wand's click inside the selection selects afresh from that pixel.
                Task { await session.magicWand(at: start, mode: .replace); synchronizeDisplay(); refreshLassoCursor() }
            } else if !moved {
                // A click without a drag deselects, as anywhere else with the lasso.
                session.deselect()
            }
            synchronizeDisplay()
            refreshLassoCursor()
        }
        if session.tool.isSelectionTool, let kind = session.lassoDraft?.kind, kind != .polygonal {
            session.finishLasso()
            synchronizeDisplay()
            refreshLassoCursor()
        }
        cropDrag = nil
        if transformDrag != nil {
            duplicatesTransformOnDrag = false
            transformDrag = nil
            if session.transformEdit?.persistent == false { session.commitTransform() }
        }
        lastDragPoint = nil
        // Leaving mid-drag keeps the drag's cursor, so a drag released outside the canvas (over
        // the Layers panel, say) must put the arrow back itself.
        if !visibleRect.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
        window?.invalidateCursorRects(for: self)
    }
    func handleScrollWheel(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        guard session.document != nil else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            session.zoom(to: session.viewport.zoom * exp(-event.scrollingDeltaY * 0.015),
                         anchor: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            session.viewport.translate(by: CGSize(width: event.scrollingDeltaX * multiplier,
                                                  height: event.scrollingDeltaY * multiplier))
            redrawRulers()
        }
    }
    func handleMagnify(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        session.zoom(to: session.viewport.zoom * (1 + event.magnification),
                     anchor: convert(event.locationInWindow, from: nil))
    }

    /// Grabs an existing endpoint, or starts a new line at the pointer.
    private func beginGradientDrag(at point: CGPoint) {
        guard let document = session.document else { return }
        if let geometry = transformOverlay.gradientLine {
            if hypot(point.x - geometry.end.x, point.y - geometry.end.y) <= 10 { gradientDrag = .end; return }
            if hypot(point.x - geometry.start.x, point.y - geometry.start.y) <= 10 { gradientDrag = .start; return }
        }
        session.beginGradient(at: session.viewport.documentPoint(from: point, documentSize: document.size))
        gradientDrag = session.gradientEdit == nil ? nil : .end
        synchronizeDisplay()
    }

    /// Shift constrains the line to 45° steps, as in Photoshop.
    private static func snapped(_ point: CGPoint, around anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    private func sampleColor(at point: CGPoint) {
        guard let document = session.document else { return }
        Self.eyedropperCursor.set()
        let documentPoint = session.viewport.documentPoint(from: point, documentSize: document.size)
        if session.colorPicker != nil { session.sampleIntoColorPicker(at: documentPoint) }
        else if session.canEditPalette, let color = session.sampleCompositeColor(at: documentPoint) {
            session.foregroundColor = color
        }
        sampleRing.frame = CGRect(x: point.x - 58, y: point.y - 58, width: 116, height: 116)
        sampleRing.original = samplingOriginal
        sampleRing.sampled = session.colorPicker?.color ?? session.foregroundColor
        sampleRing.isHidden = !session.showsSampleRing
        sampleRing.needsDisplay = true
    }
}
