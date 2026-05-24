import AppKit
import SwiftData

enum MenuBarMenuFormatting {
    private static let thumbnailSize: CGFloat = 22
    private static let minimumMenuItemWidth: CGFloat = 240

    static func preferredMenuItemWidth(for entries: [ClipboardEntry]) -> CGFloat {
        let titleFont = NSFont.menuFont(ofSize: 0)
        let subtitleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)

        let maxTitleWidth = entries.map {
            ($0.menuPreview as NSString).size(withAttributes: [.font: titleFont]).width
        }.max() ?? 0

        let maxMetadataWidth = entries.map { entry in
            let lines = metadataLines(for: entry)
            return lines.map {
                ($0 as NSString).size(withAttributes: [.font: subtitleFont]).width
            }.max() ?? 0
        }.max() ?? 0

        let textWidth = max(maxTitleWidth, maxMetadataWidth)
        return max(18 + 18 + 8 + textWidth + 8 + thumbnailSize + 14, minimumMenuItemWidth)
    }

    static func leadingIcon(for entry: ClipboardEntry) -> NSImage? {
        let image = NSImage(systemSymbolName: entry.menuSymbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    static func makeMenuItem(for entry: ClipboardEntry, menuItemWidth: CGFloat) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = entry.id

        if entry.typedContentType == .image, entry.imagePath != nil {
            item.view = MenuBarImageItemView(entry: entry, width: menuItemWidth)
            return item
        }

        item.image = leadingIcon(for: entry)
        item.attributedTitle = attributedTextTitle(for: entry)
        return item
    }

    private static func attributedTextTitle(for entry: ClipboardEntry) -> NSAttributedString {
        let metadataLines = metadataLines(for: entry)
        let body = ([entry.menuPreview] + metadataLines).joined(separator: "\n")
        let attributed = NSMutableAttributedString(string: body)
        let metadata = metadataLines.joined(separator: "\n")
        applySubtitleStyle(to: attributed, subtitle: metadata)
        return attributed
    }

    private static func metadataLines(for entry: ClipboardEntry) -> [String] {
        var lines: [String] = []
        if entry.hasCustomTitle, let customTitle = entry.customTitle {
            lines.append(customTitle)
        }
        lines.append(entry.sourceSubtitle)
        return lines
    }

    private static func metadataText(for entry: ClipboardEntry) -> String {
        metadataLines(for: entry).joined(separator: "\n")
    }

    private static func applySubtitleStyle(to attributed: NSMutableAttributedString, subtitle: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        let subtitleRange = (attributed.string as NSString).range(of: subtitle)
        guard subtitleRange.location != NSNotFound else { return }

        attributed.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1),
                .foregroundColor: NSColor.secondaryLabelColor,
            ],
            range: subtitleRange
        )
    }

    static func thumbnailImage(from image: NSImage) -> NSImage {
        let targetSize = NSSize(width: thumbnailSize, height: thumbnailSize)
        let thumbnail = NSImage(size: targetSize)

        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            thumbnail.unlockFocus()
            return thumbnail
        }

        let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let scaledSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = NSPoint(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2
        )

        image.draw(
            in: NSRect(origin: origin, size: scaledSize),
            from: NSRect(origin: .zero, size: imageSize),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()

        return thumbnail
    }
}
