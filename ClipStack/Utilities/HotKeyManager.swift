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
    static let applyPreset1 = Self("applyPreset1", default: .init(.one, modifiers: [.command, .shift]))
    static let applyPreset2 = Self("applyPreset2", default: .init(.two, modifiers: [.command, .shift]))
    static let applyPreset3 = Self("applyPreset3", default: .init(.three, modifiers: [.command, .shift]))
    static let applyPreset4 = Self("applyPreset4", default: .init(.four, modifiers: [.command, .shift]))
    static let applyPreset5 = Self("applyPreset5", default: .init(.five, modifiers: [.command, .shift]))
    static let applyPreset6 = Self("applyPreset6", default: .init(.six, modifiers: [.command, .shift]))
    static let applyPreset7 = Self("applyPreset7", default: .init(.seven, modifiers: [.command, .shift]))
    static let applyPreset8 = Self("applyPreset8", default: .init(.eight, modifiers: [.command, .shift]))
    static let applyPreset9 = Self("applyPreset9", default: .init(.nine, modifiers: [.command, .shift]))
}

@MainActor
enum HotKeyManager {
    static let applyPresetNames: [KeyboardShortcuts.Name] = [
        .applyPreset1, .applyPreset2, .applyPreset3, .applyPreset4, .applyPreset5,
        .applyPreset6, .applyPreset7, .applyPreset8, .applyPreset9,
    ]

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

        for (index, name) in applyPresetNames.enumerated() {
            KeyboardShortcuts.onKeyUp(for: name) {
                Task { @MainActor in
                    appDelegate.applyPreset(at: index)
                }
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
