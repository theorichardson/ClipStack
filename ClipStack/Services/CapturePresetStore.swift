import Foundation

extension Notification.Name {
    static let capturePresetsDidChange = Notification.Name("capturePresetsDidChange")
}

@MainActor
final class CapturePresetStore {
    static let shared = CapturePresetStore()

    private let storageKey = "capturePresets"
    private(set) var presets: [CapturePreset] = []

    private init() {
        load()
    }

    func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([CapturePreset].self, from: data)
        else {
            presets = []
            return
        }

        presets = decoded.sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ preset: CapturePreset) {
        presets.append(preset)
        persist()
    }

    func update(_ preset: CapturePreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func preset(at index: Int) -> CapturePreset? {
        guard presets.indices.contains(index) else { return nil }
        return presets[index]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: .capturePresetsDidChange, object: nil)
    }
}
