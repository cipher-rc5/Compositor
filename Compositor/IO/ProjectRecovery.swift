import Foundation
import Synchronization
import os

/// What a recovery snapshot remembers besides the project itself.
nonisolated struct RecoveryInfo: Codable, Sendable, Equatable {
    /// The tab's title when the snapshot was taken.
    var title: String
    /// Where the project was last saved, if it ever was.
    var originalURL: URL?
    var savedAt: Date
}

/// One snapshot left behind by an earlier launch.
nonisolated struct RecoveryEntry: Sendable {
    let folder: URL
    let info: RecoveryInfo
    var package: URL { folder.appending(path: RecoveryStore.packageName, directoryHint: .isDirectory) }
}

/// Unsaved projects, snapshotted so a crash or hang can't take them with it.
///
/// Each launch writes into a folder of its own and holds a lock on it for as long as it runs. A clean quit deletes the
/// folder; one whose lock nobody holds was left by a launch that ended without cleaning up, and is what the next
/// launch offers to restore. The lock, rather than "any folder", keeps a second copy of the app that's still running
/// from having its snapshots offered, or deleted, by this one.
nonisolated final class RecoveryStore: Sendable {
    static let log = Logger.compositor("Recovery")
    static let packageName = "Project.comp"
    static let infoName = "Info.json"
    static let lockName = ".lock"

    let root: URL
    /// This launch's snapshots, one folder per tab.
    let folder: URL
    /// The descriptor holding this launch's lock, or -1 once released.
    private let lock: Mutex<Int32>
    /// A writer of its own, so a Save never waits behind an autosave of a large document.
    private let projects = ProjectStore()

    init(root: URL) throws {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appending(path: Self.lockName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: folder]) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileLocking, userInfo: [NSURLErrorKey: folder])
        }
        self.root = root
        self.folder = folder
        lock = Mutex(descriptor)
    }

    deinit { releaseLock() }

    /// The store for this launch, in the app's Application Support folder (inside the sandbox container).
    /// None while unit tests run: they run inside the app, whose own launch mustn't offer or write recovery there.
    /// UI tests name a folder of their own, so they never meet the snapshots of the copy of the app in real use.
    static func forThisLaunch(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RecoveryStore? {
        guard environment["XCTestConfigurationFilePath"] == nil else { return nil }
        let name = environment["COMPOSITOR_RECOVERY_FOLDER"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Recovery"
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            return try RecoveryStore(root: support.appending(path: Bundle.main.bundleIdentifier ?? "Compositor")
                .appending(path: name, directoryHint: .isDirectory))
        } catch {
            log.error("Crash recovery is off: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: This launch

    func write(_ snapshot: ProjectSnapshot, info: RecoveryInfo, id: UUID) async throws {
        let entry = folder.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try await projects.save(snapshot, to: entry.appending(path: Self.packageName, directoryHint: .isDirectory))
        // Written last: a folder without it is a snapshot that never finished, and is skipped.
        try JSONEncoder().encode(info).write(to: entry.appending(path: Self.infoName), options: .atomic)
    }

    func discard(_ id: UUID) {
        Self.remove(folder.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    /// The ids this launch has snapshots for.
    var ids: Set<UUID> {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(contents.compactMap { UUID(uuidString: $0.lastPathComponent) })
    }

    /// A clean quit: nothing of this launch needs recovering.
    func close() {
        Self.remove(folder)
        releaseLock()
    }

    /// Nobody waits on a cleanup, so a failure is logged: left behind, a snapshot would be offered again next launch.
    /// One that's already gone is what was wanted.
    private static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            log.error("Couldn’t delete \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func releaseLock() {
        lock.withLock { descriptor in
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor) // Closing releases the lock.
            descriptor = -1
        }
    }

    // MARK: Earlier launches

    /// Complete snapshots left by launches that ended without cleaning up, oldest first.
    func abandonedEntries() -> [RecoveryEntry] {
        abandonedFolders().flatMap { run in
            let contents = (try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []
            return contents.compactMap { folder -> RecoveryEntry? in
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      let data = try? Data(contentsOf: folder.appending(path: Self.infoName)),
                      let info = try? JSONDecoder().decode(RecoveryInfo.self, from: data) else { return nil }
                let entry = RecoveryEntry(folder: folder, info: info)
                return FileManager.default.fileExists(atPath: entry.package.path) ? entry : nil
            }
        }
        .sorted { $0.info.savedAt < $1.info.savedAt }
    }

    func load(_ entry: RecoveryEntry) async throws -> ProjectSnapshot {
        try await projects.load(from: entry.package)
    }

    /// Deletes everything earlier launches left: once they've been restored or turned down, and unfinished snapshots.
    func discardAbandoned() {
        for run in abandonedFolders() { Self.remove(run) }
    }

    private func abandonedFolders() -> [URL] {
        let runs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return runs.filter { $0.standardizedFileURL != folder.standardizedFileURL && Self.isAbandoned($0) }
    }

    /// No running launch holds the folder's lock. Taking it is the test; it's let go straight away.
    private static func isAbandoned(_ run: URL) -> Bool {
        guard UUID(uuidString: run.lastPathComponent) != nil else { return false }
        let descriptor = open(run.appending(path: lockName).path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return true }
        defer { Darwin.close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

/// Every `interval`, snapshots each tab whose unsaved changes have moved on since its last snapshot, and deletes a
/// tab's snapshot once it's saved, reverted or closed. Taking a snapshot on the main actor only gathers references
/// to the document's immutable images; encoding and writing them happen on the store's own actor.
final class ProjectAutosaver {
    let store: RecoveryStore
    let interval: Duration
    private weak var workspace: ProjectWorkspace?
    /// The history revision each tab's snapshot on disk was taken at.
    private var written: [UUID: UUID] = [:]
    /// The tab whose snapshot is being written, and tabs closed or saved meanwhile, whose snapshot goes once it's done.
    private var writing: UUID?
    private var discardAfterWrite: Set<UUID> = []
    private var timer: Task<Void, Never>?
    private var pass: Task<Void, Never>?
    private var stopped = false
    /// Set once tabs are restored from an earlier launch's snapshots. Those snapshots are the only copy of that work
    /// until this launch has written its own, so they're deleted after the first pass that has, not before.
    private var discardsAbandonedWhenCovered = false

    init(store: RecoveryStore, interval: Duration = .seconds(30)) {
        self.store = store
        self.interval = interval
    }
    isolated deinit { timer?.cancel() }

    func start(_ workspace: ProjectWorkspace) {
        self.workspace = workspace
        workspace.autosaver = self
        timer = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.saveNow()
            }
        }
    }

    /// Snapshots tabs just restored from an earlier launch straight away, rather than an interval later, and deletes
    /// that launch's snapshots once every one is covered (or on a later pass, if a tab couldn't be written yet).
    func secureRestored() async {
        discardsAbandonedWhenCovered = true
        await saveNow()
    }

    /// One pass over the tabs. A call while a pass is running waits for that one.
    func saveNow() async {
        if let pass { return await pass.value }
        guard !stopped else { return }
        let task = Task { await saveChangedProjects() }
        pass = task
        await task.value
        pass = nil
    }

    /// Deletes a tab's snapshot: it was saved, closed, or its changes thrown away.
    func discard(_ id: UUID) {
        written[id] = nil
        if writing == id { discardAfterWrite.insert(id) } else { store.discard(id) }
    }

    /// A clean quit: lets a snapshot being written finish, then deletes them all.
    func stop() async {
        stopped = true
        timer?.cancel()
        timer = nil
        await pass?.value
        written = [:]
        // Quitting cleanly means every restored project was saved or deliberately discarded too.
        if discardsAbandonedWhenCovered { store.discardAbandoned() }
        store.close()
    }

    private func saveChangedProjects() async {
        guard let workspace else { return }
        let onDisk = store.ids
        for id in onDisk.subtracting(workspace.tabs.map(\.id)) { discard(id) }
        for tab in workspace.tabs where !stopped {
            // Closed while an earlier tab was being written: its snapshot was discarded with it, so don't write another.
            guard workspace.tabs.contains(where: { $0 === tab }) else { continue }
            let session = tab.session
            guard session.isModified, session.document != nil else {
                if written[tab.id] != nil || onDisk.contains(tab.id) { discard(tab.id) }
                continue
            }
            // Mid-gesture (a stroke, a dialog, a save) the document is between states; the next pass catches it.
            let revision = session.history.revision
            guard written[tab.id] != revision, session.canStartProjectOperation,
                  let snapshot = session.projectSnapshot() else { continue }
            let info = RecoveryInfo(title: tab.title, originalURL: session.projectURL ?? tab.controller.recoveredURL,
                                    savedAt: .now)
            writing = tab.id
            var succeeded = false
            do {
                try await store.write(snapshot, info: info, id: tab.id)
                succeeded = true
            } catch {
                RecoveryStore.log.error("Couldn’t snapshot \(info.title, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
            writing = nil
            if discardAfterWrite.remove(tab.id) != nil { store.discard(tab.id) }
            else if succeeded { written[tab.id] = revision }
        }
        if discardsAbandonedWhenCovered, !stopped, workspace.tabs.allSatisfy(isCovered) {
            discardsAbandonedWhenCovered = false
            store.discardAbandoned()
        }
    }

    /// Whether a crash now would lose nothing of the tab: it has no unsaved changes, or a snapshot of them.
    private func isCovered(_ tab: ProjectTab) -> Bool {
        let session = tab.session
        return !session.isModified || session.document == nil || written[tab.id] == session.history.revision
    }
}

extension ProjectWorkspace {
    /// Opens snapshots from a launch that crashed as unsaved tabs, each remembering where its project was saved
    /// before. Returns the ones that couldn't be read, or nil when another operation kept it from starting.
    func restore(_ entries: [RecoveryEntry], from store: RecoveryStore) async -> [RecoveryEntry]? {
        guard await waitUntilCanSwitch() else { return nil }
        isManaging = true
        defer { isManaging = false }
        var failed: [RecoveryEntry] = []
        for entry in entries {
            do {
                let snapshot = try await store.load(entry)
                let tab = ProjectTab(name: entry.info.title)
                tab.session.installRecoveredProject(snapshot)
                tab.controller.recoveredURL = entry.info.originalURL
                adopt(tab)
            } catch {
                RecoveryStore.log.error("Couldn’t restore \(entry.info.title, privacy: .private): \(error.localizedDescription, privacy: .public)")
                failed.append(entry)
            }
        }
        return failed
    }
}
