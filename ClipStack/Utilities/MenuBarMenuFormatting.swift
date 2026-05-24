import AppKit
import SwiftData

enum MenuBarMenuFormatting {
    private static let thumbnailSize: CGFloat = 22

    static func leadingIcon(for entry: ClipboardEntry) -> NSImage? {
        let image = NSImage(systemSymbolName: entry.menuSymbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    static func makeMenuItem(for entry: ClipboardEntry) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = entry.id
        item.image = leadingIcon(for: entry)

        if entry.typedContentType == .image,
           let path = entry.imagePath,
           let thumbnail = NSImage(contentsOfFile: path) {
            item.attributedTitle = attributedImageTitle(for: entry, thumbnail: thumbnail)
        } else {
            item.attributedTitle = attributedTextTitle(for: entry)
        }

        return item
    }

    private static func attributedTextTitle(for entry: ClipboardEntry) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: "\(entry.menuPreview)\n\(entry.sourceSubtitle)"
        )
        applySubtitleStyle(to: attributed, subtitle: entry.sourceSubtitle)
        return attributed
    }

    private static func attributedImageTitle(for entry: ClipboardEntry, thumbnail: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = menuThumbnail(from: thumbnail)
        attachment.bounds = CGRect(x: 0, y: -5, width: thumbnailSize, height: thumbnailSize)

        let attributed = NSMutableAttributedString(string: "\(entry.menuPreview)\t")
        attributed.append(NSAttributedString(attachment: attachment))
        attributed.append(NSAttributedString(string: "\n\(entry.sourceSubtitle)"))
        applySubtitleStyle(to: attributed, subtitle: entry.sourceSubtitle)
        return attributed
    }

    private static func applySubtitleStyle(to attributed: NSMutableAttributedString, subtitle: String) {
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

    private static func menuThumbnail(from image: NSImage) -> NSImage {
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
