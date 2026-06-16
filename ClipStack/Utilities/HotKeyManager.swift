import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    // ClipStack
    static let openClipStack = Self("openClipStack", default: .init(.x, modifiers: [.command, .shift]))

    // Width / capture (formerly WidthSync)
    static let saveWidth = Self("saveWidth", default: .init(.s, modifiers: [.command, .shift]))
    static let screenshotRegion = Self("screenshotRegion", default: .init(.r, modifiers: [.command, .shift, .option]))
    static let recordRegion = Self("recordRegion", default: .init(.t, modifiers: [.command, .shift, .option]))
    static let captureWindow = Self("captureWindow", default: .init(.c, modifiers: [.command, .shift, .option]))
    static let recordWindow = Self("recordWindow", default: .init(.w, modifiers: [.command, .shift, .option]))
    static let stopRecording = Self("stopRecording", default: .init(.period, modifiers: [.command, .shift]))
}

@MainActor
enum HotKeyManager {
    static func register(appDelegate: AppDelegate) {
        migrateLegacyClipStackShortcutIfNeeded()

        KeyboardShortcuts.onKeyUp(for: .openClipStack) {
            Task { @MainActor in
                PanelController.shared.toggle()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .saveWidth) {
            Task { @MainActor in
                appDelegate.saveFrontmostWidthFromShortcut()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .screenshotRegion) {
            Task { @MainActor in
                appDelegate.beginRegionScreenshot()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .recordRegion) {
            Task { @MainActor in
                appDelegate.beginRegionRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .captureWindow) {
            Task { @MainActor in
                appDelegate.beginWindowCapture()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .recordWindow) {
            Task { @MainActor in
                appDelegate.beginWindowRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .stopRecording) {
            Task { @MainActor in
                appDelegate.stopRecordingFromShortcut()
            }
        }
    }

    /// Earlier ClipStack builds shipped with ⌘⇧V. KeyboardShortcuts persists
    /// the user's choice in UserDefaults, so changing the code default doesn't
    /// affect existing installs. Migrate that one specific legacy default.
    private static func migrateLegacyClipStackShortcutIfNeeded() {
        let legacy = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
        guard KeyboardShortcuts.getShortcut(for: .openClipStack) == legacy else { return }
        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .shift]), for: .openClipStack)
    }
}
