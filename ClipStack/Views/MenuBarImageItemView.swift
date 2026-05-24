import AppKit

final class MenuBarImageItemView: NSView {
    static func rowHeight(for entry: ClipboardEntry) -> CGFloat {
        34
    }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let customTitleField = NSTextField(labelWithString: "")
    private let metadataSuffixField = NSTextField(labelWithString: "")
    private let sourceSubtitleField = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()
    private var showsCustomTitle = false

    init(entry: ClipboardEntry, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight(for: entry)))
        configure(entry: entry)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard enclosingMenuItem?.isHighlighted == true else { return }

        let highlightRect = bounds.insetBy(dx: 5, dy: 2)
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6)
        NSColor.selectedContentBackgroundColor.setFill()
        path.fill()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        updateColorsForHighlight()
    }

    private func configure(entry: ClipboardEntry) {
        iconView.image = MenuBarMenuFormatting.leadingIcon(for: entry)
        iconView.imageScaling = .scaleProportionallyDown

        configureLabel(titleField, value: entry.menuPreview, font: .menuFont(ofSize: 0))
        configureLabel(
            customTitleField,
            value: entry.customTitle ?? "",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
            color: .secondaryLabelColor
        )
        configureLabel(
            metadataSuffixField,
            value: " · \(entry.sourceSubtitle)",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
            color: .secondaryLabelColor
        )
        configureLabel(
            sourceSubtitleField,
            value: entry.sourceSubtitle,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
            color: .secondaryLabelColor
        )

        showsCustomTitle = entry.hasCustomTitle
        customTitleField.isHidden = !showsCustomTitle
        metadataSuffixField.isHidden = !showsCustomTitle
        sourceSubtitleField.isHidden = showsCustomTitle

        if let path = entry.imagePath, let image = NSImage(contentsOfFile: path) {
            thumbnailView.image = MenuBarMenuFormatting.thumbnailImage(from: image)
        }
        thumbnailView.imageScaling = .scaleProportionallyDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 5
        thumbnailView.layer?.masksToBounds = true

        for view in [iconView, titleField, customTitleField, metadataSuffixField, sourceSubtitleField, thumbnailView] {
            addSubview(view)
        }
    }

    private func configureLabel(
        _ field: NSTextField,
        value: String,
        font: NSFont,
        color: NSColor = .labelColor
    ) {
        field.stringValue = value
        field.font = font
        field.textColor = color
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.truncatesLastVisibleLine = true
    }

    private func setupLayout() {
        for view in [iconView, titleField, customTitleField, metadataSuffixField, sourceSubtitleField, thumbnailView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        customTitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        customTitleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metadataSuffixField.setContentCompressionResistancePriority(.required, for: .horizontal)
        metadataSuffixField.setContentHuggingPriority(.required, for: .horizontal)
        sourceSubtitleField.setContentCompressionResistancePriority(.required, for: .horizontal)
        sourceSubtitleField.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 22),
            thumbnailView.heightAnchor.constraint(equalToConstant: 22),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: thumbnailView.leadingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            customTitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            customTitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: -2),

            metadataSuffixField.leadingAnchor.constraint(equalTo: customTitleField.trailingAnchor),
            metadataSuffixField.trailingAnchor.constraint(lessThanOrEqualTo: thumbnailView.leadingAnchor, constant: -8),
            metadataSuffixField.centerYAnchor.constraint(equalTo: customTitleField.centerYAnchor),

            sourceSubtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            sourceSubtitleField.trailingAnchor.constraint(lessThanOrEqualTo: thumbnailView.leadingAnchor, constant: -8),
            sourceSubtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: -2),
        ])
    }

    private func updateColorsForHighlight() {
        let highlighted = enclosingMenuItem?.isHighlighted == true
        titleField.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        customTitleField.textColor = highlighted
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.65)
            : .secondaryLabelColor
        metadataSuffixField.textColor = highlighted
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.65)
            : .secondaryLabelColor
        sourceSubtitleField.textColor = highlighted
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.65)
            : .secondaryLabelColor
        iconView.contentTintColor = highlighted ? .selectedMenuItemTextColor : .labelColor
    }
}
