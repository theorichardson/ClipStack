import CoreGraphics
import Foundation

struct CaptureRegion: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cocoaRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var displayDescription: String {
        "\(Int(width)) × \(Int(height)) at (\(Int(x)), \(Int(y)))"
    }

    func sourceRect(on displayFrame: CGRect) -> CGRect {
        let relativeX = cocoaRect.origin.x - displayFrame.origin.x
        let relativeYFromBottom = cocoaRect.origin.y - displayFrame.origin.y
        let relativeYFromTop = displayFrame.height - relativeYFromBottom - cocoaRect.height
        return CGRect(x: relativeX, y: relativeYFromTop, width: width, height: height)
    }
}

struct CapturePreset: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var region: CaptureRegion
    var createdAt: Date

    init(id: UUID = UUID(), name: String, region: CaptureRegion, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.region = region
        self.createdAt = createdAt
    }
}
