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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }

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

private struct GeneralSettingsPane: View {
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Open ClipStack at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLoginManager.isEnabled = enabled
                    }
            } footer: {
                Text("ClipStack starts automatically when you log in to your Mac. You can also manage this under System Settings → General → Login Items.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager.isEnabled
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
