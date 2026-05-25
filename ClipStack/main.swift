import AppKit

@MainActor
enum AppLaunch {
    static func run() {
        if terminateIfAnotherInstanceIsRunning() {
            return
        }

        let app = NSApplication.shared
        app.delegate = AppDelegate()
        app.run()
    }

    private static func terminateIfAnotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }

        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        guard let existing = otherInstances.first else { return false }

        existing.activate(options: [])
        return true
    }
}

AppLaunch.run()
