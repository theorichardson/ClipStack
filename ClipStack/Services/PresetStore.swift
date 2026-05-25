import Foundation

extension Notification.Name {
    static let widthPresetsDidChange = Notification.Name("widthPresetsDidChange")
}

@MainActor
final class PresetStore {
    static let shared = PresetStore()

    private let storageKey = "widthPresets"
    private(set) var presets: [WidthPreset] = []

    private init() {
        load()
    }

    func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([WidthPreset].self, from: data)
        else {
            presets = []
            return
        }

        presets = decoded.sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ preset: WidthPreset) {
        presets.append(preset)
        persist()
    }

    func update(_ preset: WidthPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func preset(at index: Int) -> WidthPreset? {
        guard presets.indices.contains(index) else { return nil }
        return presets[index]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: .widthPresetsDidChange, object: nil)
    }
}
