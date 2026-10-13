import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

/// The project lifecycle short of the save and open panels: saving to a known file, the unsaved-changes question's
/// three answers, and the error paths, which must never cost the document on screen.
@MainActor
struct ProjectControllerTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorControllerTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func edit(_ session: EditorSession) {
        if session.document == nil { session.createDocument(width: 32, height: 24) }
        session.addBlankLayer()
    }

    /// Answers every alert with one button, and keeps the alerts for checking.
    private final class Answers {
        var alerts: [NSAlert] = []
        let response: NSApplication.ModalResponse
        init(_ response: NSApplication.ModalResponse) { self.response = response }
        func respond(_ alert: NSAlert) -> NSApplication.ModalResponse { alerts.append(alert); return response }
    }

    @Test func savingWritesTheProjectAndMarksItSaved() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        let controller = ProjectController(session: session)
        edit(session)
        #expect(session.isModified)
        let url = root.appending(path: "Saved.comp")
        session.projectURL = url
        #expect(await controller.save())
        #expect(!session.isModified)
        #expect(!session.isProjectBusy)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.map(\.id) == session.document?.layers.map(\.id))

        // Further edits and a second save replace the file in place.
        edit(session)
        #expect(session.isModified)
        #expect(await controller.save())
        #expect(try await ProjectStore.shared.load(from: url).manifest.layers.count == 2)
    }

    @Test func savingWithNoDocumentDoesNothing() async {
        let controller = ProjectController(session: EditorSession())
        #expect(await !controller.save())
    }

    @Test func aFailedSaveIsReportedAndKeepsTheChanges() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        let controller = ProjectController(session: session)
        let answers = Answers(.alertFirstButtonReturn)
        controller.alertResponder = answers.respond
        edit(session)
        // A regular file where the package's folder would have to be.
        let blocker = root.appending(path: "blocker")
        try Data().write(to: blocker)
        session.projectURL = blocker.appending(path: "Project.comp")
        #expect(await !controller.save())
        #expect(session.isModified)
        #expect(!session.isProjectBusy)
        #expect(answers.alerts.map(\.messageText) == ["Couldn’t save the project"])
    }

    @Test func openingADamagedProjectKeepsTheDocumentOnScreen() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let damaged = root.appending(path: "Damaged.comp")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: false)
        try Data("{ not json".utf8).write(to: damaged.appending(path: "manifest.json"))
        let session = EditorSession()
        let controller = ProjectController(session: session)
        let answers = Answers(.alertFirstButtonReturn)
        controller.alertResponder = answers.respond
        edit(session)
        let document = session.document
        #expect(await !controller.open(damaged))
        #expect(session.document == document)
        #expect(session.isModified)
        #expect(session.projectURL == nil)
        #expect(answers.alerts.map(\.messageText) == ["Couldn’t open the project"])
    }

    @Test func openingAProjectInstallsItSaved() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = EditorSession()
        edit(source)
        let url = root.appending(path: "Round Trip.comp")
        try await ProjectStore.shared.save(try #require(source.projectSnapshot()), to: url)
        let workspace = ProjectWorkspace()
        #expect(await workspace.open(url))
        #expect(workspace.tabs.count == 1)
        let tab = workspace.current
        #expect(tab.title == "Round Trip")
        #expect(tab.session.projectURL == url)
        #expect(!tab.session.isModified)
        #expect(tab.session.document?.id == source.document?.id)
        // Opening it again goes to the tab already showing it.
        #expect(await workspace.open(url))
        #expect(workspace.tabs.count == 1)
    }

    @Test func cancellingTheUnsavedChangesQuestionKeepsTheTab() async throws {
        let workspace = ProjectWorkspace()
        let tab = workspace.current
        edit(tab.session)
        let answers = Answers(.alertSecondButtonReturn) // Cancel
        tab.controller.alertResponder = answers.respond
        await workspace.close(tab.id)
        #expect(workspace.tabs.first === tab)
        #expect(tab.session.isModified)
        #expect(answers.alerts.map(\.messageText) == ["Save changes to Untitled?"])
        #expect(!workspace.isManaging)
    }

    @Test func dontSaveClosesTheTabAndLosesTheChanges() async throws {
        let workspace = ProjectWorkspace()
        let kept = workspace.current
        edit(kept.session)
        let closing = workspace.addTab(reuseEmpty: false)
        edit(closing.session)
        closing.controller.alertResponder = Answers(.alertThirdButtonReturn).respond // Don't Save
        await workspace.close(closing.id)
        #expect(workspace.tabs.map(\.id) == [kept.id])
    }

    @Test func saveFromTheUnsavedChangesQuestionSavesThenCloses() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ProjectWorkspace()
        let tab = workspace.current
        edit(tab.session)
        let url = root.appending(path: "Before Closing.comp")
        tab.session.projectURL = url
        let answers = Answers(.alertFirstButtonReturn) // Save
        tab.controller.alertResponder = answers.respond
        await workspace.close(tab.id)
        #expect(answers.alerts.map(\.messageText) == ["Save changes to Before Closing.comp?"])
        #expect(workspace.tabs.count == 1 && workspace.current !== tab)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "manifest.json").path))
    }

    @Test func quitAsksAboutEveryUnsavedTabAndStopsAtCancel() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        edit(first.session)
        let second = workspace.addTab(reuseEmpty: false)
        edit(second.session)
        let clean = workspace.addTab(reuseEmpty: false)
        let dontSave = Answers(.alertThirdButtonReturn)
        let cancel = Answers(.alertSecondButtonReturn)
        for tab in [first, clean] { tab.controller.alertResponder = dontSave.respond }
        second.controller.alertResponder = cancel.respond
        // The tab on screen is asked about first.
        #expect(workspace.quitOrder.map(\.id) == [clean.id, first.id, second.id])
        #expect(await !workspace.confirmQuit())
        #expect(dontSave.alerts.count == 1) // The clean tab isn't asked about.
        #expect(cancel.alerts.count == 1)
        second.controller.alertResponder = dontSave.respond
        #expect(await workspace.confirmQuit())
        #expect(dontSave.alerts.count == 3)
    }

    @Test func aRecoveredProjectIsAskedAboutByItsOldName() async throws {
        let workspace = ProjectWorkspace()
        let tab = workspace.current
        edit(tab.session)
        tab.controller.recoveredURL = URL(fileURLWithPath: "/Users/someone/Poster.comp")
        let answers = Answers(.alertSecondButtonReturn)
        tab.controller.alertResponder = answers.respond
        await workspace.close(tab.id)
        #expect(answers.alerts.map(\.messageText) == ["Save changes to Poster.comp?"])
    }

    /// Import Images… is held back by whatever holds every other project operation back, not a list of its own that had
    /// missed Hue/Saturation and the filters.
    @Test func importImagesWaitsForAPanelPreviewingTheDocument() throws {
        let session = EditorSession()
        let controller = ProjectController(session: session)
        session.createDocument(width: 20, height: 20)
        session.insert(try LiveMaskTests().asset([255, 0, 0, 255]))
        session.beginHueSaturation()
        #expect(!controller.canStart)
        controller.importImages()
        #expect(!session.showsImporter)
        session.cancelHueSaturation()
        session.beginFilter(.curves)
        controller.importImages()
        #expect(!session.showsImporter)
        session.cancelFilter()
        #expect(controller.canStart)
        controller.importImages()
        #expect(session.showsImporter)
    }

    @Test func aDropWaitsForAnEditInProgressThenGivesUp() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        workspace.isManaging = true // Another project operation that never finishes.
        await workspace.receive([url], timeout: .milliseconds(100))
        workspace.isManaging = false
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
        #expect(workspace.current.session.importError?.contains(url.lastPathComponent) == true)
    }

    @Test func aCancelledDropReturnsQuietly() async throws {
        let workspace = ProjectWorkspace()
        workspace.isManaging = true
        let task = Task { await workspace.receive([URL(fileURLWithPath: "/tmp/never.png")]) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(workspace.current.session.importError == nil)
        #expect(workspace.current.session.document == nil)
    }

    @Test func theNewTabSlotGoesAwayWhenTheDragEnds() async throws {
        let workspace = ProjectWorkspace()
        workspace.dragDidEnter()
        #expect(workspace.isDragging)
        // No mouse button is down while tests run, so the drag is over by the first check.
        for _ in 0..<50 where workspace.isDragging { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!workspace.isDragging)
    }
}
