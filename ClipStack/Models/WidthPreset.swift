import Foundation

struct WidthPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var width: Double
    var createdAt: Date

    init(id: UUID = UUID(), name: String, width: Double, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.width = width
        self.createdAt = createdAt
    }
}
