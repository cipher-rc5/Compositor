import AppKit
import Sparkle

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = ProjectWorkspace()
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    /// Checks the update feed and installs new versions (Sparkle). Started only after launch: its first-run prompt,
    /// shown during launch, kept the editor window from ever opening.
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    // Finder Open With and Dock drops, including files delivered during launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Reopening a window that's already showing makes SwiftUI rebuild it, so the app blinks out and back:
        // only a closed editor is reopened.
        if !application.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) {
            showEditor?()
        }
        application.activate()
        Task { await workspace.receive(urls) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Slider knobs snap to a click on the track instead of gliding there.
        SliderSnap.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [updater] in updater.startUpdater() }
        startCrashRecovery()
    }

    /// Offers back what a launch that crashed left unsaved, then starts snapshotting this launch's unsaved work.
    private func startCrashRecovery() {
        guard let store = RecoveryStore.forThisLaunch() else { return }
        let seconds = ProcessInfo.processInfo.environment["COMPOSITOR_AUTOSAVE_SECONDS"].flatMap(Double.init) ?? 30
        let autosaver = ProjectAutosaver(store: store, interval: .seconds(max(1, seconds)))
        Task {
            let abandoned = store.abandonedEntries()
            guard !abandoned.isEmpty else {
                store.discardAbandoned() // Unfinished snapshots too, which list as nothing.
                autosaver.start(workspace)
                return
            }
            // Give the window a moment to come up, so the question is asked on it as a sheet.
            try? await Task.sleep(for: .milliseconds(500))
            guard await askToRestore(abandoned) else {
                store.discardAbandoned()
                autosaver.start(workspace)
                return
            }
            // Couldn't start: keep the snapshots, to ask again next launch rather than lose them.
            let failed = await workspace.restore(abandoned, from: store)
            autosaver.start(workspace)
            guard let failed else { return }
            // Snapshotted now, not an interval from now: the old snapshots are deleted only once these are written, so
            // a second crash in between still has a copy to offer.
            await autosaver.secureRestored()
            if !failed.isEmpty { await reportUnrestored(failed) }
        }
    }

    private func askToRestore(_ entries: [RecoveryEntry]) async -> Bool {
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Restore your unsaved project?" : "Restore \(entries.count) unsaved projects?"
        let names = ListFormatter.localizedString(byJoining: entries.map(\.info.title))
        alert.informativeText = "Compositor quit unexpectedly with unsaved changes to \(names). "
            + "Restored projects open as unsaved tabs. If you discard them, the changes are lost."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        let response = if let window = workspace.window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        return response == .alertFirstButtonReturn
    }

    private func reportUnrestored(_ entries: [RecoveryEntry]) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some projects couldn’t be restored"
        alert.informativeText = "The recovered copies of \(ListFormatter.localizedString(byJoining: entries.map(\.info.title))) are damaged."
        alert.addButton(withTitle: "OK")
        if let window = workspace.window { _ = await alert.beginSheetModal(for: window) } else { _ = alert.runModal() }
    }

    /// Leaving the app is a good moment to snapshot: it's when people go off and the Mac sleeps, or worse.
    func applicationWillResignActive(_ notification: Notification) {
        Task { await workspace.autosaver?.saveNow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace.canSwitch else { return .terminateCancel }
        Task {
            let quit = await workspace.confirmQuit()
            // Every project was saved or deliberately discarded: there's nothing to recover.
            if quit { await workspace.autosaver?.stop() }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}
