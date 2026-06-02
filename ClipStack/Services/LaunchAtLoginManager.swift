import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginManager {
    private static let enabledKey = "launchAtLoginEnabled"

    /// User preference for opening ClipStack at login. Defaults to enabled.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            applyPreference(newValue)
        }
    }

    /// Ensures the login item matches the stored preference.
    static func syncWithPreference() {
        applyPreference(isEnabled)
    }

    private static func applyPreference(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClipStack: failed to update login item: \(error.localizedDescription)")
        }
    }
}
