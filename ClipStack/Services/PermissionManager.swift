import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

enum PermissionKind: String, CaseIterable {
    case accessibility
    case screenCapture

    var title: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .screenCapture:
            "Screen Recording"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            "Resize other app windows"
        case .screenCapture:
            "Capture screenshots and recordings"
        }
    }
}

enum ScreenCapturePermissionState: Equatable {
    case granted
    case denied
    /// User has approved the permission in System Settings (or via the
    /// system prompt) since this process launched, but ScreenCaptureKit will
    /// keep returning failures for the lifetime of this process. The app
    /// must be relaunched for the new TCC grant to take effect.
    case needsRelaunch
}

enum PermissionManager {
    private static var cachedScreenCaptureState: ScreenCapturePermissionState = .denied
    /// The result of `CGPreflightScreenCaptureAccess()` at process launch.
    /// macOS only updates this value on launch for the current process.
    /// If it was `false` at launch and becomes `true` later (because the
    /// user granted permission), we know SCK will still fail until relaunch.
    private static let launchTimePreflight: Bool = CGPreflightScreenCaptureAccess()

    static var executablePath: String {
        Bundle.main.bundleURL.path
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    static var hasAllPermissions: Bool {
        missingPermissions.isEmpty
    }

    static var missingPermissions: [PermissionKind] {
        PermissionKind.allCases.filter { !isGranted($0) }
    }

    // MARK: - Accessibility

    static var hasAccessibilityAccess: Bool {
        if AXIsProcessTrusted() { return true }
        return canUseAccessibilityAPI()
    }

    static func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func canUseAccessibilityAPI() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        return result == .success
    }

    // MARK: - Screen Recording

    static var screenCapturePermissionState: ScreenCapturePermissionState {
        cachedScreenCaptureState
    }

    static var hasScreenCaptureAccess: Bool {
        cachedScreenCaptureState == .granted
    }

    static var screenCaptureNeedsRelaunch: Bool {
        cachedScreenCaptureState == .needsRelaunch
    }

    @MainActor
    @discardableResult
    static func probeScreenCaptureAccess() async -> Bool {
        // `CGPreflightScreenCaptureAccess()` is the only source of truth for
        // whether THIS PROCESS can actually use ScreenCaptureKit. Its value
        // is latched at process launch; if it was false then, SCK will fail
        // for the entire lifetime of this process, even after the user
        // toggles the permission on in System Settings.
        let preflight = CGPreflightScreenCaptureAccess()

        if preflight {
            cachedScreenCaptureState = .granted
            return true
        }

        // Preflight is false. If the user has since granted the permission
        // (via the system prompt or System Settings), SCShareableContent will
        // succeed even though preflight has not been refreshed — that's the
        // signal that a relaunch is required.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedScreenCaptureState = launchTimePreflight ? .granted : .needsRelaunch
            return cachedScreenCaptureState == .granted
        } catch {
            cachedScreenCaptureState = .denied
            return false
        }
    }

    @MainActor
    static func registerScreenCaptureAccess() async -> Bool {
        if await probeScreenCaptureAccess() { return true }
        // `CGRequestScreenCaptureAccess()` triggers the system prompt the
        // first time the app uses screen recording. It returns immediately
        // (it does NOT wait for the user to respond) and reports the cached
        // preflight value, so we can't use its return value as truth. We
        // just kick the prompt and return what we have; the UI will refresh
        // when the app becomes active again.
        _ = CGRequestScreenCaptureAccess()
        return false
    }

    @MainActor
    static func markScreenCaptureAccessGranted() {
        // Don't downgrade `needsRelaunch` to `granted` just because an XPC
        // call happened to succeed — the user still needs to relaunch.
        if cachedScreenCaptureState == .denied {
            cachedScreenCaptureState = launchTimePreflight ? .granted : .needsRelaunch
        }
    }

    // MARK: - Unified flow

    static func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility:
            hasAccessibilityAccess
        case .screenCapture:
            // `needsRelaunch` is treated as not-yet-granted for the purposes
            // of "is the app ready to use?" The UI shows a distinct message
            // so the user knows they need to quit & relaunch, not re-grant.
            hasScreenCaptureAccess
        }
    }

    @MainActor
    static func refreshPermissionStatus() async {
        _ = await probeScreenCaptureAccess()
    }

    @MainActor
    static func requestAllPermissions() async {
        if !hasAccessibilityAccess {
            requestAccessibilityAccess()
            try? await Task.sleep(for: .milliseconds(800))
        }

        if screenCapturePermissionState != .granted {
            _ = await registerScreenCaptureAccess()
        }
    }

    @MainActor
    static func openSettings(for kind: PermissionKind) {
        let pane: String
        switch kind {
        case .accessibility:
            pane = "Privacy_Accessibility"
        case .screenCapture:
            pane = "Privacy_ScreenCapture"
        }

        let urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            return
        }

        let legacyURLString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: legacyURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openSettingsForMissingPermissions() {
        guard let kind = missingPermissions.first else { return }
        openSettings(for: kind)
    }

    static func statusSummary(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            isGranted(kind) ? "Allowed" : "Not Allowed"
        case .screenCapture:
            switch screenCapturePermissionState {
            case .granted:
                "Allowed"
            case .denied:
                "Not Allowed"
            case .needsRelaunch:
                "Granted — Relaunch Required"
            }
        }
    }

    /// Quit and relaunch the running app. Required after the user grants
    /// Screen Recording while the app is running, because TCC latches the
    /// per-process value at launch.
    @MainActor
    static func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
        } catch {
            NSWorkspace.shared.open(bundleURL)
        }
        // Give launch a moment to register before exit so the new instance
        // doesn't see the old one as still running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}
