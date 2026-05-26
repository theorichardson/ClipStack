import Foundation

@MainActor
final class LastScreenshotRegionStore {
    static let shared = LastScreenshotRegionStore()

    private let storageKey = "lastScreenshotRegion"

    private init() {}

    var region: CaptureRegion? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(CaptureRegion.self, from: data)
        else { return nil }
        return decoded
    }

    func save(_ region: CaptureRegion) {
        guard let data = try? JSONEncoder().encode(region) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
