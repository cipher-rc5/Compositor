import AppKit

extension CanvasView {
    func installEventMonitors() {
        // Modifier changes reach only the first responder; watch them app-wide so the
        // lasso badge updates even while another control has keyboard focus.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            self.optionHeld = event.modifierFlags.contains(.option)
            // A Marquee drag reshapes as Shift goes down or up, without waiting for the mouse to move.
            if let pixel = self.marqueeDragPixel, let kind = self.session.lassoDraft?.kind, kind == .rectangle || kind == .ellipse {
                self.dragMarqueeDraft(to: pixel, flags: event.modifierFlags)
            }
            // So does a crop drag as Option (symmetry) or Control (no snapping) changes.
            if let drag = self.cropDrag, self.session.tool == .crop, let document = self.session.document, let window = self.window {
                self.dragCrop(drag, to: self.convert(window.mouseLocationOutsideOfEventStream, from: nil),
                              flags: event.modifierFlags, documentSize: document.size)
            }
            self.synchronizeDisplay()
            self.updateBrushCursor()
            // Only while the pointer is over the canvas: rebuilding its cursor rects with the pointer somewhere
            // else (the Layers panel, holding Option for a clipping mask) takes that view's cursor away.
            if let window = self.window, self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                self.window?.invalidateCursorRects(for: self)
            }
            self.session.updateHeldSelectionKeys(shift: event.modifierFlags.contains(.shift),
                                                 option: event.modifierFlags.contains(.option))
            if self.session.tool.isSelectionTool { self.refreshLassoCursor(event.modifierFlags) }
            if self.session.tool == .move, let window = self.window {
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.visibleRect.contains(point) { self.updateTransformCursor(at: point, flags: event.modifierFlags) }
            }
            return event
        }
        // Window-wide keys that work wherever focus sits — the canvas, the Layers panel, a header
        // control, the tool rail — except while typing in a text field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let originalEvent = event
            guard let event = ShortcutSettings.shared.canvasEvent(event) else { return originalEvent }
            guard let self, let window = self.window, event.window === window, !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers else { return originalEvent }
            // Shift-+ / Shift-− step the active layer's blend mode, in every tool.
            if event.modifierFlags.contains(.shift), key == "+" || key == "_" || event.keyCode == 24 || event.keyCode == 27 {
                self.session.cycleBlendMode(forward: key == "+" || event.keyCode == 24)
                return nil
            }
            // Brush size ([ ]) and hardness (Shift-[ ]); with focus on the canvas its own keyDown handles them.
            guard (self.session.tool.isBrushTool), self.session.levels == nil, window.firstResponder !== self,
                  ["[", "]", "{", "}"].contains(key) else { return originalEvent }
            if key == "[" || key == "]" { self.session.changeBrushSize(increase: key == "]") }
            else { self.session.changeBrushHardness(increase: key == "}") }
            return nil
        }
    }
    func handleKeyDown(with event: NSEvent) {
        let physicalKey = event.keyCode
        guard let event = ShortcutSettings.shared.canvasEvent(event) else { return }
        if event.keyCode == 53, textBoxAnchor != nil { textBoxAnchor = nil; textBoxRect = nil; needsDisplay = true; return }
        if event.keyCode == 53, session.textDraft != nil { session.cancelText(); return }
        // A drag session swallows the flagsChanged that says Option was let go, which left the canvas thinking it
        // was still held — and with it the Eyedropper standing in for the Brush. Every key press re-reads it.
        optionHeld = event.modifierFlags.contains(.option)
        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift {
            if session.canContentAwareFill { session.beginFilter(.contentAwareFill) }
            return
        }
        if let edit = session.levels {
            if event.keyCode == 53 { session.cancelLevels(); return }
            if [36, 76].contains(event.keyCode) { Task { await session.commitLevels() }; return }
            if event.charactersIgnoringModifiers?.lowercased() == "p", event.modifierFlags.contains(.option) {
                session.updateLevels(edit.settings, preview: !edit.preview); return
            }
            if event.keyCode != 49 { super.keyDown(with: event); return }
        }
        if session.brushStroke != nil || session.warpStroke != nil {
            if event.keyCode == 53 && !session.isProjectBusy { session.cancelBrush(); synchronizeDisplay() }
            return
        }
        if session.lassoDraft != nil, [53, 36, 76, 51, 117].contains(event.keyCode) {
            if event.keyCode == 53 { session.cancelLasso() }
            else if [36, 76].contains(event.keyCode) { session.finishLasso() }
            else { session.removeLastLassoPoint() }
            synchronizeDisplay()
            refreshLassoCursor()
        } else if session.shapeDraft != nil, event.keyCode == 53 {
            session.cancelShape()
            synchronizeDisplay()
        } else if session.gradientEdit != nil, event.keyCode == 53 {
            gradientDrag = nil
            session.cancelGradient()
        } else if session.gradientEdit != nil, [36, 76].contains(event.keyCode) {
            gradientDrag = nil
            Task { await session.commitGradient() }
        } else if session.tool == .crop, event.keyCode == 53 {
            cropDrag = nil
            session.cancelCrop()
        } else if session.tool == .crop, [36, 76].contains(event.keyCode) {
            cropDrag = nil
            Task { await session.commitCrop() }
        } else if event.keyCode == 53, session.guideDrag != nil {
            session.cancelGuideDrag()
            guideDragging = false
        } else if event.keyCode == 53, session.transformEdit != nil {
            transformDrag = nil
            session.cancelTransform()
        } else if [36, 76].contains(event.keyCode), session.transformEdit != nil {
            transformDrag = nil
            Task { await session.applyTransform() }
        } else if session.selection?.isEmpty == false, session.lassoDraft == nil, [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.contains(.command), event.modifierFlags.intersection([.control, .option]).isEmpty {
            // Cmd-arrow moves the selected pixels in any tool; Shift for 10 px.
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            Task { await session.nudgePixels(dx: dx, dy: dy); synchronizeDisplay() }
        } else if session.tool.isSelectionTool, session.lassoDraft == nil, session.selection?.isEmpty == false,
                  [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session.nudgeSelection(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                   dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if session.tool == .move, [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session.nudgeLayer(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                               dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            session.deleteKeyPressed()
        } else if event.keyCode == 49 {
            panPhysicalKey = physicalKey
            spaceHeld = true
            updateBrushCursor()
            window?.invalidateCursorRects(for: self)
        } else if ToolShortcutDispatcher.perform(event, in: session) {
            // Tool keys, Tab, the opacity digits and [ ] { } — shared with the Layers panel. The tool or its mode
            // may have changed under the pointer, so its cursor is worked out again.
            refreshLassoCursor()
            updateBrushCursor()
        } else { super.keyDown(with: event) }
    }
    func handleKeyUp(with event: NSEvent) {
        if event.keyCode == panPhysicalKey || (panPhysicalKey == nil && event.keyCode == 49) {
            panPhysicalKey = nil
            spaceHeld = false
            updateBrushCursor()
            window?.invalidateCursorRects(for: self)
        } else { super.keyUp(with: event) }
    }
}
