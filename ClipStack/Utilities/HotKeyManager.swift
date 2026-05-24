import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let openClipStack = Self("openClipStack", default: .init(.x, modifiers: [.command, .shift]))
}

@MainActor
enum HotKeyManager {
    static func register() {
        migrateLegacyShortcutIfNeeded()

        KeyboardShortcuts.onKeyUp(for: .openClipStack) {
            PanelController.shared.toggle()
        }
    }

    /// KeyboardShortcuts persists the user's shortcut in UserDefaults, so changing
    /// the code default does not update an existing install still on ⌘⇧V.
    private static func migrateLegacyShortcutIfNeeded() {
        let legacy = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
        guard KeyboardShortcuts.getShortcut(for: .openClipStack) == legacy else { return }
        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .shift]), for: .openClipStack)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open ClipStack:", name: .openClipStack)
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Opens a keyboard picker from anywhere. Click the menu bar icon for the native clip menu.")
            }

            Section("About Universal Clipboard") {
                Text("ClipStack monitors your Mac pasteboard, which includes items synced from iPhone and iPad via Universal Clipboard. Make sure Handoff is enabled on all devices and you're signed into the same Apple ID.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 280)
        .padding()
    }
}
