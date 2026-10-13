import AppKit
import SwiftUI
import os

/// Intercepts only close approval and forwards SwiftUI's other window callbacks.
struct ProjectWindowBridge: NSViewRepresentable {
    let controller: ProjectController
    func makeNSView(context: Context) -> ProjectWindowView { ProjectWindowView(controller: controller) }
    func updateNSView(_ view: ProjectWindowView, context: Context) {
        view.update(controller)
        view.window?.representedURL = controller.session.projectURL
        view.window?.isDocumentEdited = controller.session.isModified
        view.window?.titleVisibility = .hidden
    }
}

final class ProjectWindowView: NSView {
    var controller: ProjectController
    private let proxy = ProjectWindowDelegate()
    init(controller: ProjectController) {
        self.controller = controller
        super.init(frame: .zero)
        proxy.controller = controller
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ controller: ProjectController) {
        self.controller = controller
        proxy.controller = controller
        controller.window = window
        controller.workspace?.window = window
        if let window { installDelegate(in: window) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.controller.window = window
            self.controller.workspace?.window = window
            self.installDelegate(in: window)
        }
    }

    /// The unsaved-changes question on close rests on the proxy staying the window's delegate, and SwiftUI owns the
    /// window. Checked on every update, so if SwiftUI ever installs a delegate of its own the proxy goes back in
    /// front of it (forwarding to it) instead of the window closing unasked.
    private func installDelegate(in window: NSWindow) {
        guard window.delegate !== proxy else { return }
        if installedIn === window {
            Self.log.fault("The window’s delegate was replaced; reinstalling the close confirmation in front of it")
        }
        proxy.previous = window.delegate
        window.delegate = proxy
        installedIn = window
    }
    private weak var installedIn: NSWindow?
    private static let log = Logger.compositor("Window")
}

private final class ProjectWindowDelegate: NSObject, NSWindowDelegate {
    // Read from the nonisolated forwarding overrides below, which AppKit only calls on
    // the main thread; `NSWindowDelegate` isn't Sendable, so the compiler can't see that.
    nonisolated(unsafe) weak var previous: NSWindowDelegate?
    weak var controller: ProjectController?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller else { return true }
        Task {
            if let workspace = controller.workspace { await workspace.closeWindow(sender) }
            else { await controller.close(sender) }
        }
        return false
    }
    // NSObject declares these nonisolated, and the Objective-C runtime calls them while
    // forwarding a message, so they have to stay nonisolated to match. Both only read
    // `previous`, which the runtime touches on the main thread here.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
    }
}
