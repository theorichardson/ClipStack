import AppKit
import CoreText

/// Shared HUD pill used by region and window capture selectors.
@MainActor
final class CaptureSelectionBadgeHost {
    private static let padding = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
    private static let trailingSpacing: CGFloat = 8
    private static let edgeInset: CGFloat = 8

    private let badgeEffectView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        return view
    }()

    private let badgeLabel = CaptureSelectionBadgeLabelView()
    private weak var parentView: NSView?
    private weak var trailingView: NSView?
    private var isConfigured = false

    func attach(to parent: NSView, trailing: NSView? = nil) {
        guard !isConfigured else { return }
        isConfigured = true
        parentView = parent
        trailingView = trailing

        parent.addSubview(badgeEffectView)
        badgeEffectView.addSubview(badgeLabel)
        if let trailing {
            badgeEffectView.addSubview(trailing)
        }
    }

    func update(anchorRect: CGRect, in containerBounds: CGRect, label: NSAttributedString) {
        guard anchorRect.width > 0, anchorRect.height > 0 else {
            hide()
            return
        }

        badgeEffectView.isHidden = false
        badgeLabel.attributedText = label

        let padding = Self.padding
        let textSize = badgeLabel.fittingSize()

        var trailingWidth: CGFloat = 0
        var trailingHeight: CGFloat = 0
        if let trailing = trailingView {
            (trailing as? NSControl)?.sizeToFit()
            let popupSize = trailing.frame.size
            trailingWidth = popupSize.width
            trailingHeight = max(18, popupSize.height)
        }

        let contentHeight = max(textSize.height, trailingHeight)
        let bgSize = CGSize(
            width: padding.left + textSize.width
                + (trailingWidth > 0 ? Self.trailingSpacing + trailingWidth : 0)
                + padding.right,
            height: contentHeight + padding.top + padding.bottom
        )

        let aboveY = anchorRect.maxY + Self.edgeInset
        let belowY = anchorRect.minY - bgSize.height - Self.edgeInset
        let originY: CGFloat = aboveY + bgSize.height <= containerBounds.maxY
            ? aboveY
            : max(belowY, Self.edgeInset)
        let originX = max(
            Self.edgeInset,
            min(anchorRect.minX, containerBounds.maxX - bgSize.width - Self.edgeInset)
        )
        let bgRect = CGRect(origin: CGPoint(x: originX, y: originY), size: bgSize)

        badgeEffectView.frame = bgRect
        badgeLabel.frame = CGRect(
            x: padding.left,
            y: padding.bottom + (contentHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        if let trailing = trailingView, trailingWidth > 0 {
            trailing.frame = CGRect(
                x: padding.left + textSize.width + Self.trailingSpacing,
                y: padding.bottom + (contentHeight - trailingHeight) / 2,
                width: trailingWidth,
                height: trailingHeight
            )
        }

        badgeLabel.needsDisplay = true
    }

    func hide() {
        badgeEffectView.isHidden = true
    }
}

private final class CaptureSelectionBadgeLabelView: NSView {
    var attributedText = NSAttributedString()

    override var isFlipped: Bool { true }

    func fittingSize() -> CGSize {
        Self.fittingSize(for: attributedText)
    }

    static func fittingSize(for attributed: NSAttributedString) -> CGSize {
        guard attributed.length > 0 else { return .zero }
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return CGSize(width: ceil(width), height: ceil(ascent + descent))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard attributedText.length > 0 else { return }
        let rect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        attributedText.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
