import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func open() {
        if let window {
            present(window)
            return
        }

        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.setFrameSize(hostingView.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.frame.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipStack Settings"
        window.contentView = hostingView
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func restoreAccessoryPolicyIfNeeded() {
        let hasVisibleWindows = NSApp.windows.contains { window in
            window.isVisible && !window.isSheet
        }
        guard !hasVisibleWindows else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.restoreAccessoryPolicyIfNeeded()
        }
    }
}
