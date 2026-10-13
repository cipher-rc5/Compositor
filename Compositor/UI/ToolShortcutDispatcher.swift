import AppKit

/// The single-key shortcuts that work wherever the editor has keyboard focus: the tool keys (V, B, M…), the palette's
/// X and D, Tab for the tool's mode, the digits for opacity, and [ ] { } for the brush tip. The canvas and the Layers
/// panel both send their key presses through here, so a key can't mean one thing in one and nothing in the other.
/// Keys whose meaning depends on the focused view — arrows, Delete, Return, Escape, Space — stay with each view.
enum ToolShortcutDispatcher {
    /// Performs the shortcut for `event`, if it is one. False when it isn't, so the caller can pass the event on.
    @discardableResult
    static func perform(_ event: NSEvent, in session: EditorSession) -> Bool {
        perform(event.charactersIgnoringModifiers, modifiers: event.modifierFlags, isRepeat: event.isARepeat, in: session)
    }

    /// `characters` is what the key types ignoring modifiers other than Shift, as `NSEvent.charactersIgnoringModifiers`
    /// gives it; so Shift-[ arrives as "{". Command, Control and Option keep their menu meanings and are never taken.
    @discardableResult
    static func perform(_ characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false,
                        in session: EditorSession) -> Bool {
        guard modifiers.intersection([.command, .control, .option]).isEmpty, let characters else { return false }
        let shift = modifiers.contains(.shift)
        let key = characters.lowercased()
        switch key {
        case "\t" where !shift && session.textDraft == nil: session.cycleToolMode()
        case "x": session.swapPaletteColors()
        case "d": session.resetPaletteColors()
        case "b", "e":
            session.selectTool(.brush)
            session.brushMode = key == "e" ? .erase : .paint
        case "u":
            if shift, session.tool == .shape { session.toggleShapeKind() } else { session.selectTool(.shape) }
        // M, W and L choose their tool in whichever mode it was last set to; the mode is switched in the tool bar or
        // with Tab. Ignoring a repeat keeps holding the key from doing anything odd.
        case "m": if !isRepeat { session.pressMarqueeKey() }
        case "w": if !isRepeat { session.pressWandKey() }
        case "l": if !isRepeat { session.pressLassoKey() }
        case "[" where session.tool.isBrushTool: session.changeBrushSize(increase: false)
        case "]" where session.tool.isBrushTool: session.changeBrushSize(increase: true)
        case "{" where session.tool.isBrushTool: session.changeBrushHardness(increase: false)
        case "}" where session.tool.isBrushTool: session.changeBrushHardness(increase: true)
        default:
            if let digit = Int(key), (0...9).contains(digit), key.count == 1 {
                guard session.usesOpacityKeys else { return false }
                session.typeOpacityDigit(digit)
            } else if let tool = tool(for: key) {
                session.selectTool(tool)
            } else {
                return false
            }
        }
        return true
    }

    /// The tool a plain letter selects, for the letters that do nothing else.
    static func tool(for key: String) -> NavigationTool? {
        switch key {
        case "a": .idle
        case "v": .move
        case "h": .hand
        case "z": .zoom
        case "j": .spotHealing
        case "s": .cloneStamp
        case "t": .type
        case "g": .gradient
        case "i": .eyedropper
        case "r": .blur
        case "c": .crop
        default: nil
        }
    }
}
