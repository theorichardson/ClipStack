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
            (inlineMetadata(for: entry) as NSString).size(withAttributes: [.font: subtitleFont]).width
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
        item.attributedTitle = attributedTextTitle(for: entry, menuItemWidth: menuItemWidth)
        return item
    }

    private static func attributedTextTitle(for entry: ClipboardEntry, menuItemWidth: CGFloat) -> NSAttributedString {
        let metadata = inlineMetadata(for: entry, maxTextWidth: textAreaWidth(for: menuItemWidth))
        let body = [entry.menuPreview, metadata].joined(separator: "\n")
        let attributed = NSMutableAttributedString(string: body)
        applySubtitleStyle(to: attributed, subtitle: metadata)
        return attributed
    }

    private static func inlineMetadata(for entry: ClipboardEntry, maxTextWidth: CGFloat? = nil) -> String {
        let suffix = entry.sourceSubtitle
        guard entry.hasCustomTitle, let customTitle = entry.customTitle else { return suffix }

        let separator = " · "
        let suffixPart = separator + suffix
        let full = customTitle + suffixPart

        guard let maxTextWidth else { return full }

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        let fullWidth = (full as NSString).size(withAttributes: [.font: font]).width
        if fullWidth <= maxTextWidth { return full }

        let suffixWidth = (suffixPart as NSString).size(withAttributes: [.font: font]).width
        let availablePrefixWidth = max(maxTextWidth - suffixWidth, 0)
        let truncatedTitle = truncateTail(customTitle, toWidth: availablePrefixWidth, font: font)
        return truncatedTitle + suffixPart
    }

    private static func truncateTail(_ string: String, toWidth maxWidth: CGFloat, font: NSFont) -> String {
        guard !string.isEmpty else { return "" }
        guard (string as NSString).size(withAttributes: [.font: font]).width > maxWidth else { return string }

        var result = string
        while result.count > 1,
              (result as NSString).size(withAttributes: [.font: font]).width > maxWidth {
            result = String(result.dropLast())
        }

        guard result.count < string.count else { return result }

        while result.count > 1,
              ((result + "…") as NSString).size(withAttributes: [.font: font]).width > maxWidth {
            result = String(result.dropLast())
        }

        return result + "…"
    }

    private static func textAreaWidth(for menuItemWidth: CGFloat) -> CGFloat {
        menuItemWidth - 18 - 8 - 18 - 8 - thumbnailSize - 14
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
