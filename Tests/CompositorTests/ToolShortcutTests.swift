import AppKit
import Testing
@testable import Compositor

/// The single-key shortcuts mean the same thing with the canvas focused as with the Layers panel focused.
@MainActor
struct ToolShortcutTests {
    private func event(_ text: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                      isARepeat: false, keyCode: keyCode))
    }

    private func session() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 200, emptyLayer: true)
        return session
    }

    @Test func everyToolLetterSelectsItsTool() {
        let expected: [String: NavigationTool] = [
            "a": .idle, "v": .move, "h": .hand, "z": .zoom, "b": .brush, "e": .brush, "j": .spotHealing,
            "s": .cloneStamp, "t": .type, "g": .gradient, "u": .shape, "i": .eyedropper, "m": .marquee,
            "w": .wand, "l": .lasso, "r": .blur, "c": .crop
        ]
        for (key, tool) in expected {
            let session = session()
            session.selectTool(.move)
            #expect(ToolShortcutDispatcher.perform(key, modifiers: [], in: session), "\(key)")
            #expect(session.tool == tool, "\(key) chose \(session.tool)")
        }
        // Every tool but the idle one has a key: none is reachable only from the rail.
        let reachable = Set(expected.values)
        #expect(Set(NavigationTool.allCases).subtracting(reachable).isEmpty)
    }

    @Test func modifiedKeysAreLeftToTheMenus() {
        let session = session()
        session.selectTool(.move)
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(!ToolShortcutDispatcher.perform("b", modifiers: modifier, in: session))
        }
        #expect(session.tool == .move)
        #expect(!ToolShortcutDispatcher.perform("q", modifiers: [], in: session))
    }

    @Test func bracketsResizeAndHardenOnlyBrushTools() {
        let session = session()
        session.selectTool(.brush)
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 0.5
        #expect(ToolShortcutDispatcher.perform("]", modifiers: [], in: session))
        #expect(session.brushSettings.diameter == 48)
        #expect(ToolShortcutDispatcher.perform("[", modifiers: [], in: session))
        #expect(session.brushSettings.diameter == 40)
        #expect(ToolShortcutDispatcher.perform("}", modifiers: .shift, in: session))
        #expect(session.brushSettings.hardness == 0.75)
        #expect(ToolShortcutDispatcher.perform("{", modifiers: .shift, in: session))
        #expect(session.brushSettings.hardness == 0.5)
        session.selectTool(.move)
        #expect(!ToolShortcutDispatcher.perform("[", modifiers: [], in: session))
    }

    @Test func digitsSetOpacityOnlyWhereTheyMeanIt() {
        let session = session()
        session.selectTool(.hand)
        #expect(!ToolShortcutDispatcher.perform("5", modifiers: [], in: session))
        session.selectTool(.brush)
        #expect(ToolShortcutDispatcher.perform("5", modifiers: [], in: session))
        #expect(abs(session.brushSettings.opacity - 0.5) < 0.001)
    }

    @Test func shiftUCyclesTheShapeOnlyWithTheShapeTool() {
        let session = session()
        session.selectTool(.shape)
        let kind = session.shapeKind
        #expect(ToolShortcutDispatcher.perform("U", modifiers: .shift, in: session))
        #expect(session.shapeKind != kind)
        session.selectTool(.move)
        #expect(ToolShortcutDispatcher.perform("U", modifiers: .shift, in: session))
        #expect(session.tool == .shape)
    }

    /// The bug this guards: with the Layers panel focused, [ ] { } did nothing, though the shortcut list
    /// advertises them everywhere. Each key goes to both views and must leave both sessions alike.
    @Test func theLayersPanelAndTheCanvasAgree() throws {
        let keys: [(text: String, code: UInt16, modifiers: NSEvent.ModifierFlags)] = [
            ("b", 11, []), ("]", 30, []), ("]", 30, []), ("{", 33, .shift), ("7", 26, []), ("\t", 48, []),
            ("e", 14, []), ("[", 33, []), ("x", 7, []), ("u", 32, []), ("U", 32, .shift), ("m", 46, []),
            ("\t", 48, []), ("s", 1, []), ("}", 30, .shift), ("v", 9, [])
        ]
        let canvasSession = session(), listSession = session()
        let canvas = CanvasView(session: canvasSession)
        let table = LayerTableView()
        table.session = listSession
        for key in keys {
            canvas.keyDown(with: try event(key.text, keyCode: key.code, modifiers: key.modifiers))
            table.keyDown(with: try event(key.text, keyCode: key.code, modifiers: key.modifiers))
            let label = "after \(key.text.debugDescription)"
            #expect(canvasSession.tool == listSession.tool, "\(label)")
            #expect(canvasSession.brushMode == listSession.brushMode, "\(label)")
            #expect(canvasSession.brushSettings.diameter == listSession.brushSettings.diameter, "\(label)")
            #expect(canvasSession.brushSettings.hardness == listSession.brushSettings.hardness, "\(label)")
            #expect(canvasSession.brushSettings.opacity == listSession.brushSettings.opacity, "\(label)")
            #expect(canvasSession.shapeKind == listSession.shapeKind, "\(label)")
            #expect(canvasSession.marqueeKind == listSession.marqueeKind, "\(label)")
            #expect(canvasSession.foregroundColor == listSession.foregroundColor, "\(label)")
        }
        // And the keys did something: the brush was resized and hardened through the Layers panel.
        #expect(listSession.brushSettings.diameter != BrushSettings().diameter)
    }
}
