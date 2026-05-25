import AppKit
import KeyboardShortcuts
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

struct SettingsView: View {
    var body: some View {
        TabView {
            ClipStackSettingsPane()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }

            WidthSettingsPane()
                .tabItem { Label("Window Width", systemImage: "square.resize") }

            CaptureSettingsPane()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
        }
        .frame(width: 520, height: 420)
        .padding()
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct ClipStackSettingsPane: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open ClipStack:", name: .openClipStack)
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Opens the keyboard picker from anywhere. Use the menu bar icon for capture and width tools.")
            }

            Section("About Universal Clipboard") {
                Text("ClipStack monitors your Mac pasteboard, which includes items synced from iPhone and iPad via Universal Clipboard. Make sure Handoff is enabled on all devices and you're signed into the same Apple ID.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WidthSettingsPane: View {
    var body: some View {
        Form {
            Section("Save & Apply") {
                KeyboardShortcuts.Recorder("Save Frontmost Width:", name: .saveWidth)
            }

            Section {
                ForEach(Array(HotKeyManager.applyPresetNames.enumerated()), id: \.offset) { index, name in
                    KeyboardShortcuts.Recorder("Apply Preset \(index + 1):", name: name)
                }
            } header: {
                Text("Apply Width Presets")
            } footer: {
                Text("Width preset slots map to the order shown in the menu bar.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptureSettingsPane: View {
    var body: some View {
        Form {
            Section("Screenshot") {
                KeyboardShortcuts.Recorder("Screenshot Region:", name: .screenshotRegion)
                KeyboardShortcuts.Recorder("Screenshot Window:", name: .captureWindow)
            }

            Section("Recording") {
                KeyboardShortcuts.Recorder("Record Region:", name: .recordRegion)
                KeyboardShortcuts.Recorder("Record Window:", name: .recordWindow)
                KeyboardShortcuts.Recorder("Stop Recording:", name: .stopRecording)
            }
        }
        .formStyle(.grouped)
    }
}
