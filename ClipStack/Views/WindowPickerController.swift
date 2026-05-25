import AppKit
import ScreenCaptureKit

@MainActor
final class WindowPickerController {
    static let shared = WindowPickerController()

    private init() {}

    struct Selection {
        let window: SCWindow
        let suggestedName: String
    }

    /// Presents a modal picker listing on-screen windows. Calls `completion`
    /// with the user's selection, or `nil` if they cancelled.
    func pickWindow(prompt: String = "Choose a window to record:", completion: @escaping (Selection?) -> Void) {
        Task {
            do {
                let windows = try await ScreenCaptureService.shared.availableWindows()
                guard !windows.isEmpty else {
                    throw ScreenCaptureError.noWindowsAvailable
                }
                let selection = self.runPicker(windows: windows, prompt: prompt)
                completion(selection)
            } catch {
                self.presentError(error)
                completion(nil)
            }
        }
    }

    private func runPicker(windows: [SCWindow], prompt: String) -> Selection? {
        let alert = NSAlert()
        alert.messageText = "Record a Window"
        alert.informativeText = prompt
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        for window in windows {
            let item = NSMenuItem(title: Self.displayTitle(for: window), action: nil, keyEquivalent: "")
            item.representedObject = window
            popup.menu?.addItem(item)
        }
        alert.accessoryView = popup

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard
            let selectedItem = popup.selectedItem,
            let window = selectedItem.representedObject as? SCWindow
        else { return nil }
        return Selection(window: window, suggestedName: Self.suggestedName(for: window))
    }

    static func displayTitle(for window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let size = "\(Int(window.frame.width))×\(Int(window.frame.height))"
        if title.isEmpty {
            return "\(app) — (untitled) — \(size)"
        }
        return "\(app) — \(title) — \(size)"
    }

    static func suggestedName(for window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Window"
        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return app
        }
        return "\(app) - \(title)"
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClipStack Couldn't List Windows"
        alert.informativeText = error.localizedDescription
        if let recovery = (error as? LocalizedError)?.recoverySuggestion {
            alert.informativeText += "\n\n\(recovery)"
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
