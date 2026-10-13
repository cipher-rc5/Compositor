import XCTest

/// A project's whole life through the real app: created, saved, closed, opened again and exported, and brought back
/// after a crash.
final class ProjectLifecycleUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appending(path: "CompositorUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func testSaveCloseReopenAndExport() throws {
        let app = XCUIApplication.compositor()
        app.launch()
        app.createCanvas(width: 640, height: 480)
        app.buttons["addBlankLayer"].click()

        app.typeKey("s", modifierFlags: .command)
        choose(name: "Round Trip", in: app)
        let project = folder.appending(path: "Round Trip.comp")
        XCTAssertTrue(waitForFile(project.appending(path: "manifest.json")), "Save didn't write \(project.path)")

        // Saved, so it closes without asking, back to an empty tab.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["createCanvas"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["canvasDimensions"].exists)

        app.typeKey("o", modifierFlags: .command)
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        goToFolder(project.path, in: app)
        app.typeKey(.return, modifierFlags: [])
        let dimensions = app.staticTexts["canvasDimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 10))
        XCTAssertEqual(dimensions.value as? String, "640 × 480 px")

        app.typeKey("e", modifierFlags: [.command, .shift])
        choose(name: "Exported", in: app)
        XCTAssertTrue(waitForFile(folder.appending(path: "Exported.png")), "Export PNG wrote nothing")
    }

    /// Unsaved work survives the app being killed: the next launch offers it back, and it returns unsaved.
    @MainActor
    func testUnsavedWorkIsRestoredAfterACrash() throws {
        let recovery = "UITest-\(UUID().uuidString)"
        let app = XCUIApplication.compositor(recoveryFolder: recovery, autosaveSeconds: 1)
        app.launch()
        app.createCanvas(width: 320, height: 200)
        app.buttons["addBlankLayer"].click()
        // Killed only once a snapshot is on disk, rather than after a guess at how long that takes.
        XCTAssertTrue(wait("a recovery snapshot", until: { Self.snapshotExists(in: recovery) }),
                      "No snapshot appeared in \(Self.recoveryRoot(recovery).path)")

        // Killed, not quit: nothing gets the chance to save or clean up, as in a crash.
        app.terminate()
        app.launch()
        let restore = app.buttons["Restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "No offer to restore the unsaved canvas")
        restore.click()
        let dimensions = app.staticTexts["canvasDimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 10))
        XCTAssertEqual(dimensions.value as? String, "320 × 200 px")

        // Quitting without saving leaves nothing to offer the launch after.
        app.typeKey("q", modifierFlags: .command)
        let dontSave = app.buttons["Don’t Save"]
        XCTAssertTrue(dontSave.waitForExistence(timeout: 5))
        dontSave.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.buttons["createCanvas"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Restore"].waitForExistence(timeout: 2))
    }

    /// Fills in the save panel on screen: the name, then the test's folder, then saves.
    @MainActor
    private func choose(name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        // The name field has focus, its current name selected.
        app.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        goToFolder(folder.path, in: app)
        app.typeKey(.return, modifierFlags: [])
    }

    /// The panels' Go to Folder sheet, which takes a typed path. Its field is the one text field it adds to the panel,
    /// so the field count says when it has opened (ready for typing) and closed again (the folder is shown).
    @MainActor
    private func goToFolder(_ path: String, in app: XCUIApplication) {
        let types = [XCUIElement.ElementType.textField, .comboBox, .searchField].map(\.rawValue)
        let fields = app.descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@", types))
        let before = fields.count
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait(for: NSPredicate(format: "count > %d", before), on: fields), "Go to Folder didn't open")
        app.typeText(path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(wait(for: NSPredicate(format: "count <= %d", before), on: fields), "Go to Folder didn't close")
    }

    private func wait(for predicate: NSPredicate, on object: Any, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: object)], timeout: timeout) == .completed
    }

    /// Waits on a condition outside the app's interface, such as a file, checked by XCTest's own polling.
    private func wait(_ description: String, timeout: TimeInterval = 10, until condition: @escaping @Sendable () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = description
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        wait(url.lastPathComponent, timeout: timeout) { FileManager.default.fileExists(atPath: url.path) }
    }

    /// The app is sandboxed, so a test's recovery folder lives in its container's Application Support. The runner
    /// isn't sandboxed and is signed by the same team when run from Xcode, so it may read it; with ad hoc signing
    /// macOS can ask once for access to another app's data.
    nonisolated private static func recoveryRoot(_ recovery: String) -> URL {
        let bundle = "com.wonderassembly.compositor"
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(bundle)/Data/Library/Application Support/\(bundle)/\(recovery)",
                       directoryHint: .isDirectory)
    }

    /// A finished snapshot: `Info.json` is written last, after the project package.
    nonisolated private static func snapshotExists(in recovery: String) -> Bool {
        let files = FileManager.default.enumerator(at: recoveryRoot(recovery), includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent == "Info.json" { return true }
        }
        return false
    }
}
