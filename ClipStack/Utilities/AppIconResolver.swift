import AppKit

/// Resolves and caches application icons by bundle identifier so we can show
/// them as badges next to clipboard entries without hitting Launch Services on
/// every render pass.
@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]
    private static var negativeCache: Set<String> = []

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }

        if let cached = cache[bundleID] { return cached }
        if negativeCache.contains(bundleID) { return nil }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            negativeCache.insert(bundleID)
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
