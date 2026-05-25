import Foundation
import SwiftData

enum ClipboardContentType: String, Codable, CaseIterable {
    case text
    case url
    case image
    case rtf
    case file
    case unknown
}

enum ClipboardSource: String, Codable {
    case local
    case universal
}

@Model
final class ClipboardEntry {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var contentType: String
    var textContent: String?
    var imagePath: String?
    var preview: String
    var customTitle: String?
    var source: String
    var sourceAppName: String?
    var sourceAppBundleID: String?
    var searchableText: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        contentType: ClipboardContentType,
        textContent: String? = nil,
        imagePath: String? = nil,
        preview: String,
        customTitle: String? = nil,
        source: ClipboardSource,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        searchableText: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.contentType = contentType.rawValue
        self.textContent = textContent
        self.imagePath = imagePath
        self.preview = preview
        self.customTitle = customTitle
        self.source = source.rawValue
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.searchableText = searchableText
    }

    var typedContentType: ClipboardContentType {
        ClipboardContentType(rawValue: contentType) ?? .unknown
    }

    var typedSource: ClipboardSource {
        ClipboardSource(rawValue: source) ?? .local
    }

    var displaySourceApp: String {
        if let sourceAppName, !sourceAppName.isEmpty {
            return sourceAppName
        }
        if typedSource == .universal {
            return "iPhone"
        }
        return "Unknown"
    }

    var sourceSubtitle: String {
        "\(displaySourceApp) · \(createdAt.clipMenuTimestamp)"
    }

    var hasCustomTitle: Bool {
        guard let customTitle else { return false }
        return !customTitle.isEmpty
    }

    var listPreviewLineLimit: Int {
        2
    }

    var menuSymbolName: String {
        if typedSource == .universal {
            return "iphone"
        }

        switch typedContentType {
        case .url:
            return "link"
        case .image:
            return "photo"
        case .file:
            return "doc"
        default:
            return "text.alignleft"
        }
    }

    var menuPreview: String {
        let singleLine = preview.replacingOccurrences(of: "\n", with: " ")
        let maxLength = 48
        guard singleLine.count > maxLength else { return singleLine }
        return String(singleLine.prefix(maxLength - 1)) + "…"
    }
}
