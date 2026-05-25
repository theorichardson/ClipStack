import AppKit
import ApplicationServices

enum WindowResizerError: LocalizedError {
    case accessibilityNotGranted
    case noFrontmostWindow
    case cannotReadSize
    case cannotApplyWidth

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "ClipStack needs Accessibility access to read and resize other app windows."
        case .noFrontmostWindow:
            "No resizable frontmost window was found."
        case .cannotReadSize:
            "Could not read the frontmost window size."
        case .cannotApplyWidth:
            "The frontmost window could not be resized. Some apps block width changes."
        }
    }
}

enum WindowResizer {
    static var isAccessibilityTrusted: Bool {
        PermissionManager.hasAccessibilityAccess
    }

    static func requestAccessibilityAccess() {
        PermissionManager.requestAccessibilityAccess()
    }

    static func frontmostWindowWidth(targetPID: pid_t? = nil) throws -> Double {
        let window = try frontmostWindow(targetPID: targetPID)
        return try windowSize(for: window).width
    }

    static func applyWidth(_ width: Double, targetPID: pid_t? = nil) throws {
        let window = try frontmostWindow(targetPID: targetPID)
        var size = try windowSize(for: window)
        size.width = width
        try setWindowSize(size, for: window)
    }

    private static func frontmostWindow(targetPID: pid_t?) throws -> AXUIElement {
        guard isAccessibilityTrusted else {
            throw WindowResizerError.accessibilityNotGranted
        }

        let resolvedPID: pid_t
        if let targetPID, targetPID > 0 {
            resolvedPID = targetPID
        } else {
            // Fall back to the system's current frontmost app, but ignore
            // ClipStack itself — when invoked from the popover/menu we have
            // typically just activated, so `frontmostApplication` would
            // point at us instead of the user's actual target window.
            guard let app = bestExternalFrontmostApplication() else {
                throw WindowResizerError.noFrontmostWindow
            }
            resolvedPID = app.processIdentifier
        }

        let appElement = AXUIElementCreateApplication(resolvedPID)

        if let focused = copyAttribute(kAXFocusedWindowAttribute, from: appElement) as AXUIElement? {
            return focused
        }

        if let main = copyAttribute(kAXMainWindowAttribute, from: appElement) as AXUIElement? {
            return main
        }

        if let windows = copyAttribute(kAXWindowsAttribute, from: appElement) as [AXUIElement]?,
           let first = windows.first {
            return first
        }

        throw WindowResizerError.noFrontmostWindow
    }

    /// Returns the frontmost running application that is *not* ClipStack.
    /// macOS reports the active app at the time of call, which is us as
    /// soon as we present any UI (popover, alert, etc.), so we need to
    /// look past ourselves.
    private static func bestExternalFrontmostApplication() -> NSRunningApplication? {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ourPID {
            return front
        }
        return NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != ourPID
                && app.activationPolicy == .regular
                && !app.isTerminated
                && app.isActive
        }
    }

    private static func windowSize(for window: AXUIElement) throws -> CGSize {
        guard let size = copyAttribute(kAXSizeAttribute, from: window) as CGSize? else {
            throw WindowResizerError.cannotReadSize
        }
        return size
    }

    private static func setWindowSize(_ size: CGSize, for window: AXUIElement) throws {
        var mutableSize = size
        guard
            let value = AXValueCreate(.cgSize, &mutableSize),
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
        else {
            throw WindowResizerError.cannotApplyWidth
        }
    }

    private static func copyAttribute<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }

        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement) as? T
        }

        if T.self == [AXUIElement].self, let array = value as? [AXUIElement] {
            return array as? T
        }

        if T.self == CGSize.self, CFGetTypeID(value) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(value as! AXValue, .cgSize, &size) {
                return size as? T
            }
        }

        return nil
    }
}
