import Foundation
import Testing
@testable import Compositor

@MainActor
struct ShortcutOverrideTests {
    private let brush = "Canvas & Layers:Brush tool"
    private let eraser = "Canvas & Layers:Eraser"
    private let zoom = "Canvas & Layers:Zoom tool"

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @Test func savedOverridesLoadAsTheyWere() throws {
        let saved = [brush: ShortcutChord("k"), eraser: ShortcutChord("e", 2)]
        try #require(ShortcutSettings.problem(in: saved) == nil)
        #expect(ShortcutSettings.overrides(from: try JSONEncoder().encode(saved)) == saved)
    }

    @Test func oneBadEntryDoesNotCostTheOthers() throws {
        try #require(ShortcutSettings.problem(in: [brush: ShortcutChord("k")]) == nil)
        let data = try json([
            brush: ["key": "k", "modifiers": 0],
            // Clashes with the Brush override, which sorts first and so is the one kept.
            eraser: ["key": "k", "modifiers": 0],
            zoom: ["key": 5], // Damaged.
            "Menus:A Command Since Removed": ["key": "y", "modifiers": 1],
        ])
        #expect(ShortcutSettings.overrides(from: data) == [brush: ShortcutChord("k")])
    }

    /// ⌥⌘H is the app menu's Hide Others; it was listed as "Hide Compositor", so remapping it seemed to move Hide.
    @Test func optionCommandHIsHideOthers() throws {
        let definition = try #require(ShortcutDefinition.all.first { $0.original == ShortcutChord("h", 3) && $0.isMenu })
        #expect(definition.title == "Hide Others")
        #expect(!ShortcutDefinition.all.contains { $0.title == "Hide Compositor" })
        // ⌘H stays with the Move tool's transform controls.
        #expect(ShortcutDefinition.all.first { $0.original == ShortcutChord("h", 1) && $0.isMenu }?.title == "Show Transform Controls")
        // An override saved under the old name carries over.
        let saved = try json(["Menus:Hide Compositor": ["key": "h", "modifiers": 7]])
        #expect(ShortcutSettings.overrides(from: saved) == ["Menus:Hide Others": ShortcutChord("h", 7)])
    }

    /// Dialogs share Apply and Cancel, so a plain key there would fire while typing in their fields.
    @Test func applyAndCancelNeedAModifierUnlessOnReturnOrEsc() {
        for id in ["Canvas & Layers:Apply current canvas operation", "Canvas & Layers:Cancel current canvas operation"] {
            #expect(ShortcutSettings.problem(in: [id: ShortcutChord("k")]) != nil, "\(id)")
            #expect(ShortcutSettings.problem(in: [id: ShortcutChord("k", 8)]) != nil, "Shift still types: \(id)")
            #expect(ShortcutSettings.problem(in: [id: ShortcutChord("k", 1)]) == nil, "\(id)")
            #expect(ShortcutSettings.problem(in: [id: ShortcutChord("k", 4)]) == nil, "\(id)")
        }
        // Swapped onto each other's keys is still fine.
        #expect(ShortcutSettings.problem(in: ["Canvas & Layers:Apply current canvas operation": ShortcutChord("\u{1b}"),
                                              "Canvas & Layers:Cancel current canvas operation": ShortcutChord("\r")]) == nil)
        #expect(ShortcutSettings.problem(in: [:]) == nil)
    }

    @Test func anUnreadableFileFallsBackToTheDefaults() throws {
        #expect(ShortcutSettings.overrides(from: Data("not json".utf8)).isEmpty)
        #expect(ShortcutSettings.overrides(from: try json(["a", "b"])).isEmpty)
    }
}
