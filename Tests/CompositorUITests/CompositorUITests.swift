import XCTest

@MainActor extension XCUIApplication {
    /// The app, with crash recovery kept to a folder of the test's own: snapshots of the copy in real use are never
    /// offered to (or deleted by) a test, and a test's are never offered to it.
    static func compositor(recoveryFolder: String = "UITest-\(UUID().uuidString)", autosaveSeconds: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["COMPOSITOR_RECOVERY_FOLDER"] = recoveryFolder
        if let autosaveSeconds { app.launchEnvironment["COMPOSITOR_AUTOSAVE_SECONDS"] = String(autosaveSeconds) }
        return app
    }

    /// Fills in the new-canvas form an empty tab shows, and creates the canvas.
    func createCanvas(width: Int, height: Int) {
        for (field, value) in [("widthInput", width), ("heightInput", height)] {
            let input = textFields[field]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.click()
            input.typeKey("a", modifierFlags: .command)
            input.typeText(String(value))
        }
        buttons["createCanvas"].click()
    }
}

final class CompositorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCreateCanvasAndNavigation() throws {
        let app = XCUIApplication.compositor()
        app.launch()
        let width = app.textFields["widthInput"]
        XCTAssertTrue(width.waitForExistence(timeout: 5))
        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("0")
        XCTAssertFalse(app.buttons["createCanvas"].isEnabled)
        app.createCanvas(width: 1200, height: 800)
        XCTAssertEqual(app.staticTexts["canvasDimensions"].value as? String, "1,200 × 800 px")
        app.buttons["actualPixels"].click()
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "100%")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "125%")
        app.buttons["fitCanvas"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editor foundation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // ⌘N opens a new, empty tab; the first keeps its canvas.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.buttons["createCanvas"].waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.staticTexts["canvasDimensions"].value as? String, "1,200 × 800 px")
    }

    /// Launch to an editor ready for input. XCTest's launch, idle and accessibility overhead is included, so the
    /// ceiling is generous: it catches launch becoming noticeably slow, not small drift.
    @MainActor
    func testLaunchPerformance() throws {
        let app = XCUIApplication.compositor()
        var samples: [Double] = []
        for _ in 0..<5 {
            app.terminate()
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            XCTAssertTrue(app.buttons["createCanvas"].waitForExistence(timeout: 10))
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let median = samples.sorted()[samples.count / 2]
        let report = XCTAttachment(string: "Launch to ready, seconds: \(samples); median \(median)")
        report.lifetime = .keepAlways
        add(report)
        XCTAssertLessThan(median, 4, "Launch to a ready editor took \(median) s (samples \(samples))")
    }
}
