import Foundation
import Testing
@testable import Compositor

@MainActor
struct RecoveryTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorRecoveryTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A tab with an unsaved edit.
    private func dirtyTab(in workspace: ProjectWorkspace) -> ProjectTab {
        let tab = workspace.current
        tab.session.createDocument(width: 40, height: 30)
        tab.session.addBlankLayer()
        return tab
    }

    @Test func aLaunchThatEndsWithoutClosingLeavesItsSnapshotsForTheNext() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let id = UUID()
        let original = URL(fileURLWithPath: "/Users/someone/Art/Poster.comp")
        do {
            let crashed = try RecoveryStore(root: root)
            try await crashed.write(snapshot, info: RecoveryInfo(title: "Poster", originalURL: original, savedAt: .now), id: id)
            #expect(crashed.ids == [id])
            // Still running: a second copy of the app must neither offer nor delete its snapshots.
            let other = try RecoveryStore(root: root)
            #expect(other.abandonedEntries().isEmpty)
            other.discardAbandoned()
            #expect(crashed.ids == [id])
            other.close()
        } // Released without close(), as a crash leaves it.
        let next = try RecoveryStore(root: root)
        defer { next.close() }
        let entries = next.abandonedEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.info.title == "Poster")
        #expect(entry.info.originalURL == original)
        let loaded = try await next.load(entry)
        #expect(loaded.manifest.documentID == snapshot.manifest.documentID)
        #expect(loaded.manifest.layers.map(\.id) == snapshot.manifest.layers.map(\.id))
        next.discardAbandoned()
        #expect(next.abandonedEntries().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [next.folder.lastPathComponent])
    }

    @Test func aCleanCloseLeavesNothingToRecover() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        let store = try RecoveryStore(root: root)
        try await store.write(try #require(session.projectSnapshot()), info: RecoveryInfo(title: "A", savedAt: .now), id: UUID())
        store.close()
        let next = try RecoveryStore(root: root)
        defer { next.close() }
        #expect(next.abandonedEntries().isEmpty)
    }

    @Test func anUnfinishedSnapshotIsSkippedAndCleanedUp() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        // A launch that crashed mid-write: a project package, but no info written after it.
        let run = root.appending(path: UUID().uuidString)
        let entry = run.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: entry.appending(path: RecoveryStore.packageName), withIntermediateDirectories: true)
        // And stray files that aren't anyone's snapshots.
        try Data("x".utf8).write(to: root.appending(path: "notes.txt"))
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        #expect(store.abandonedEntries().isEmpty)
        store.discardAbandoned()
        #expect(!FileManager.default.fileExists(atPath: run.path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "notes.txt").path))
    }

    @Test func unitTestsGetNoRecoveryOfTheirOwn() {
        #expect(RecoveryStore.forThisLaunch(["XCTestConfigurationFilePath": "/tmp/x"]) == nil)
    }

    @Test func autosaveIsANoOpWhileEverythingIsSaved() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        let workspace = ProjectWorkspace()
        let autosaver = ProjectAutosaver(store: store, interval: .seconds(3600))
        autosaver.start(workspace)
        await autosaver.saveNow()
        #expect(store.ids.isEmpty)
        workspace.current.session.createDocument(width: 20, height: 20)
        workspace.current.session.history.markSaved()
        await autosaver.saveNow()
        #expect(store.ids.isEmpty)
    }

    @Test func autosaveSnapshotsChangesAndDropsThemOnceSaved() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        let workspace = ProjectWorkspace()
        let autosaver = ProjectAutosaver(store: store, interval: .seconds(3600))
        autosaver.start(workspace)
        let tab = dirtyTab(in: workspace)
        await autosaver.saveNow()
        #expect(store.ids == [tab.id])
        let info = store.folder.appending(path: tab.id.uuidString).appending(path: RecoveryStore.infoName)
        let firstWrite = try Data(contentsOf: info)

        // Nothing changed since: not rewritten.
        await autosaver.saveNow()
        #expect(try Data(contentsOf: info) == firstWrite)

        // Changed again: rewritten.
        tab.session.addBlankLayer()
        await autosaver.saveNow()
        #expect(try Data(contentsOf: info) != firstWrite)

        // Undone back to the saved state: nothing to recover.
        tab.session.history.markSaved()
        await autosaver.saveNow()
        #expect(store.ids.isEmpty)
    }

    @Test func savingThroughTheControllerDeletesTheSnapshot() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        let workspace = ProjectWorkspace()
        let autosaver = ProjectAutosaver(store: store, interval: .seconds(3600))
        autosaver.start(workspace)
        let tab = dirtyTab(in: workspace)
        await autosaver.saveNow()
        #expect(store.ids == [tab.id])
        tab.session.projectURL = root.appending(path: "Saved.comp")
        #expect(await tab.controller.save())
        #expect(store.ids.isEmpty)
    }

    @Test func closingATabOrQuittingDeletesSnapshots() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(root: root)
        let workspace = ProjectWorkspace()
        let autosaver = ProjectAutosaver(store: store, interval: .seconds(3600))
        autosaver.start(workspace)
        let first = dirtyTab(in: workspace)
        let second = workspace.addTab(reuseEmpty: false)
        second.session.createDocument(width: 10, height: 10)
        second.session.addBlankLayer()
        await autosaver.saveNow()
        #expect(store.ids == [first.id, second.id])
        workspace.removeTab(second.id)
        #expect(store.ids == [first.id])
        await autosaver.stop()
        #expect(!FileManager.default.fileExists(atPath: store.folder.path))
        // Stopped for good: a later pass writes nothing.
        await autosaver.saveNow()
        #expect(!FileManager.default.fileExists(atPath: store.folder.path))
        let next = try RecoveryStore(root: root)
        defer { next.close() }
        #expect(next.abandonedEntries().isEmpty)
    }

    @Test func restoredProjectsOpenAsUnsavedTabsThatRememberTheirFile() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Folder/Poster.comp")
        do {
            let crashed = try RecoveryStore(root: root)
            let workspace = ProjectWorkspace()
            let autosaver = ProjectAutosaver(store: crashed, interval: .seconds(3600))
            autosaver.start(workspace)
            let tab = dirtyTab(in: workspace)
            tab.session.projectURL = original
            let untitled = workspace.addTab(reuseEmpty: false)
            untitled.session.createDocument(width: 64, height: 48)
            untitled.session.addBlankLayer()
            await autosaver.saveNow()
            #expect(crashed.ids.count == 2)
        }
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        let entries = store.abandonedEntries()
        #expect(entries.count == 2)
        let workspace = ProjectWorkspace()
        let failed = try #require(await workspace.restore(entries, from: store))
        #expect(failed.isEmpty)
        // The empty launch tab gives way to the restored ones.
        #expect(workspace.tabs.count == 2)
        let poster = try #require(workspace.tabs.first { $0.title == "Poster" })
        #expect(poster.session.isModified)
        #expect(poster.session.projectURL == nil)
        #expect(poster.controller.recoveredURL == original)
        #expect(poster.controller.displayName == "Poster.comp")
        #expect(poster.session.document?.size == CGSize(width: 40, height: 30))
        let other = try #require(workspace.tabs.first { $0.title == "Untitled 2" })
        #expect(other.controller.recoveredURL == nil)
        #expect(other.session.document?.layers.count == 1)
        // Undoing never makes a restored project look saved.
        other.session.undo()
        #expect(other.session.isModified)
        #expect(workspace.tabs.allSatisfy { $0.controller.workspace === workspace })
    }

    @Test func aDamagedSnapshotIsReportedAndTheRestStillRestore() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = EditorSession()
        good.createDocument(width: 12, height: 12)
        do {
            let crashed = try RecoveryStore(root: root)
            try await crashed.write(try #require(good.projectSnapshot()), info: RecoveryInfo(title: "Good", savedAt: .now), id: UUID())
            let damaged = UUID()
            try await crashed.write(try #require(good.projectSnapshot()), info: RecoveryInfo(title: "Damaged", savedAt: .now), id: damaged)
            let manifest = crashed.folder.appending(path: damaged.uuidString).appending(path: RecoveryStore.packageName)
                .appending(path: "manifest.json")
            try Data("{".utf8).write(to: manifest)
        }
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        let workspace = ProjectWorkspace()
        let failed = try #require(await workspace.restore(store.abandonedEntries(), from: store))
        #expect(failed.map(\.info.title) == ["Damaged"])
        #expect(workspace.tabs.map(\.title) == ["Good"])
    }

    /// The snapshots a restore came from are the only copy of that work until this launch writes its own; deleting
    /// them first left a window in which a second crash lost everything.
    @Test func restoredWorkKeepsItsOldSnapshotUntilANewOneIsWritten() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = EditorSession()
        source.createDocument(width: 16, height: 16)
        source.addBlankLayer()
        do {
            let crashed = try RecoveryStore(root: root)
            try await crashed.write(try #require(source.projectSnapshot()), info: RecoveryInfo(title: "Poster", savedAt: .now),
                                    id: UUID())
        }
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        let workspace = ProjectWorkspace()
        let failed = try #require(await workspace.restore(store.abandonedEntries(), from: store))
        #expect(failed.isEmpty)
        let tab = workspace.current
        let autosaver = ProjectAutosaver(store: store, interval: .seconds(3600))
        autosaver.start(workspace)

        // A sheet open on the restored tab keeps the first pass from snapshotting it: the old copy has to stay.
        tab.session.showsNewDocument = true
        await autosaver.secureRestored()
        #expect(store.ids.isEmpty)
        #expect(store.abandonedEntries().count == 1)

        // The next pass that covers it lets the old copy go.
        tab.session.showsNewDocument = false
        await autosaver.saveNow()
        #expect(store.ids == [tab.id])
        #expect(store.abandonedEntries().isEmpty)
    }

    @Test func quittingCleanlyAfterARestoreDeletesTheOldSnapshots() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = EditorSession()
        source.createDocument(width: 16, height: 16)
        do {
            let crashed = try RecoveryStore(root: root)
            try await crashed.write(try #require(source.projectSnapshot()), info: RecoveryInfo(title: "A", savedAt: .now), id: UUID())
        }
        let store = try RecoveryStore(root: root)
        let workspace = ProjectWorkspace()
        _ = try #require(await workspace.restore(store.abandonedEntries(), from: store))
        let autosaver = ProjectAutosaver(store: store, interval: .seconds(3600))
        autosaver.start(workspace)
        workspace.current.session.showsNewDocument = true
        await autosaver.secureRestored()
        #expect(store.abandonedEntries().count == 1)
        await autosaver.stop()
        let next = try RecoveryStore(root: root)
        defer { next.close() }
        #expect(next.abandonedEntries().isEmpty)
    }

    @Test func restoreWaitsForAnEditInProgressThenGivesUp() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(root: root)
        defer { store.close() }
        let workspace = ProjectWorkspace()
        workspace.isManaging = true
        let task = Task { await workspace.restore([], from: store) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
    }
}
