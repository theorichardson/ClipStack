import AppKit

/// A compact, horizontally-arranged popover with the primary ClipStack
/// controls. Shown when the user left-clicks the status bar icon. Right-click
/// still opens the full NSMenu.
@MainActor
final class StatusBarPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private weak var appDelegate: AppDelegate?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var restoreFocusOnClose = true
    private weak var activePopupMenu: NSMenu?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func close(restoreFocus: Bool = true) {
        restoreFocusOnClose = restoreFocus
        let menusWereOpen = activePopupMenu != nil || hasVisibleMenuWindows
        dismissActiveMenusImmediately()
        activePopupMenu = nil

        let previousAnimates = popover.animates
        if menusWereOpen {
            popover.animates = false
        }
        popover.close()
        popover.animates = previousAnimates
    }

    private var hasVisibleMenuWindows: Bool {
        NSApp.windows.contains { isMenuTrackingWindow($0) && $0.isVisible }
    }

    private func dismissActiveMenusImmediately() {
        activePopupMenu?.cancelTrackingWithoutAnimation()
        for window in NSApp.windows where isMenuTrackingWindow(window) {
            window.orderOut(nil)
        }
    }

    func show(from button: NSStatusBarButton) {
        popover.contentViewController = makeContentViewController()
        // Capture the user's actual target app BEFORE we activate ClipStack.
        // Once we activate, NSWorkspace.frontmostApplication points at us,
        // and any subsequent window-resize call would target a ClipStack
        // window (e.g. the popover) instead of Chrome/etc.
        appDelegate?.captureTargetApplicationPID()
        // Activate so the popover's window opens in its *active* appearance
        // — without this, an LSUIElement menu-bar app renders the popover
        // dimmed until the user clicks inside it.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installOutsideClickMonitor()
    }

    // MARK: - Outside-click dismissal
    //
    // `LSUIElement` menu-bar apps never become the active app, so an
    // `NSPopover.transient` does not reliably auto-dismiss on outside clicks
    // (it relies on resignKey events that never fire). Install global and
    // local event monitors while the popover is shown to close it manually
    // on any mouse-down outside its content view.

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            self.handleOutsideClick(for: event)
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            self.handleOutsideClick(for: event)
            return event
        }
    }

    /// Outside-click monitors can fire on the main thread while `menu.popUp` is
    /// in its event loop — never `DispatchQueue.main.sync` here or libdispatch
    /// traps with "queue already owned by current thread".
    private func handleOutsideClick(for event: NSEvent) {
        if Thread.isMainThread {
            guard shouldDismissPopover(for: event) else { return }
            close()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.shouldDismissPopover(for: event) else { return }
                self.close()
            }
        }
    }

    private func shouldDismissPopover(for event: NSEvent) -> Bool {
        guard popover.isShown else { return false }
        guard let popoverWindow = popover.contentViewController?.view.window else { return true }

        let screenPoint = NSEvent.mouseLocation
        if popoverWindow.frame.contains(screenPoint) { return false }
        if isPointerOverMenu(at: screenPoint) { return false }

        if let eventWindow = event.window {
            if eventWindow === popoverWindow { return false }
            if isMenuTrackingWindow(eventWindow) { return false }
        }

        return true
    }

    private func isPointerOverMenu(at screenPoint: NSPoint) -> Bool {
        NSApp.windows.contains { window in
            isMenuTrackingWindow(window) && window.frame.contains(screenPoint)
        }
    }

    private func isMenuTrackingWindow(_ window: NSWindow) -> Bool {
        window.level == .popUpMenu
    }

    private func removeOutsideClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.removeOutsideClickMonitor()
            if self.restoreFocusOnClose {
                self.appDelegate?.restoreCapturedTargetApplicationFocus()
            }
            self.restoreFocusOnClose = true
            self.appDelegate?.clearCapturedTargetApplicationPID()
        }
    }

    private func makeContentViewController() -> NSViewController {
        let vc = NSViewController()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let isRecording = ScreenCaptureService.shared.isRecording

        if isRecording {
            let stop = makeCell(
                symbol: "stop.circle.fill",
                label: "Stop",
                tooltip: "Stop Recording (⌘⇧.)",
                action: #selector(handleStop(_:))
            )
            stop.tintColor = .systemRed
            stack.addArrangedSubview(stop)
            stack.addArrangedSubview(makeDivider())
        }

        stack.addArrangedSubview(makeCell(
            symbol: CaptureActionSymbol.screenshotRegion,
            label: "Region",
            tooltip: "Screenshot Region (⌘⇧⌥R)",
            action: #selector(handleRegion(_:))
        ))
        stack.addArrangedSubview(makeCell(
            symbol: CaptureActionSymbol.screenshotWindow,
            label: "Window",
            tooltip: "Screenshot Window (⌘⇧⌥C)",
            action: #selector(handleWindow(_:))
        ))

        stack.addArrangedSubview(makeDivider())

        stack.addArrangedSubview(makeCell(
            symbol: "square.resize.down",
            label: "Width",
            tooltip: "Width Presets",
            action: #selector(handleWidthPresets(_:))
        ))
        stack.addArrangedSubview(makeDivider())

        stack.addArrangedSubview(makeCell(
            symbol: "ellipsis",
            label: "More",
            tooltip: "More",
            action: #selector(handleMore(_:))
        ))

        let container = NSView()
        container.addSubview(stack)
        let padding: CGFloat = 4
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
        ])
        vc.view = container
        return vc
    }

    private func makeCell(symbol: String, label: String, tooltip: String, action: Selector) -> IconBarCell {
        IconBarCell(symbol: symbol, label: label, tooltip: tooltip, target: self, action: action)
    }

    private func makeDivider() -> NSView {
        let v = DividerView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return v
    }

    @objc private func handleStop(_ sender: Any?) {
        close(restoreFocus: false)
        appDelegate?.stopActiveRecordingFromUI()
    }

    @objc private func handleRegion(_ sender: Any?) {
        close(restoreFocus: false)
        appDelegate?.beginRegionSelection()
    }

    @objc private func handleWindow(_ sender: Any?) {
        close(restoreFocus: false)
        appDelegate?.beginWindowSelection()
    }

    @objc private func handleWidthPresets(_ sender: Any?) {
        guard let view = sender as? NSView, let menu = appDelegate?.buildWidthPresetsMenu() else { return }
        present(menu: menu, from: view)
    }

    @objc private func handleMore(_ sender: Any?) {
        guard let view = sender as? NSView, let menu = appDelegate?.buildMoreMenu() else { return }
        present(menu: menu, from: view)
    }

    private func present(menu: NSMenu, from view: NSView) {
        // In AppKit's default (non-flipped) coordinate space, y=0 is the
        // bottom of the view. NSMenu.popUp places its top-left at the given
        // point, so anchoring slightly below the bottom of the cell makes
        // the submenu drop *down* from the popover instead of opening up
        // and covering it.
        let isFlipped = view.isFlipped
        let yBelow: CGFloat = isFlipped ? view.bounds.height + 4 : -4
        let origin = NSPoint(x: 0, y: yBelow)
        activePopupMenu = menu
        defer { activePopupMenu = nil }
        menu.popUp(positioning: nil, at: origin, in: view)
    }
}

/// A Control-Center-style cell: SF Symbol icon on top, short caption label
/// underneath, subtle rounded hover/press highlight covering the whole cell.
final class IconBarCell: NSControl {
    /// Nested inside the popover content padding so the hover pill tracks the
    /// popover shell's corner curvature (outer radius − inset).
    private static let cornerRadius: CGFloat = 16

    private let iconView = NSImageView()
    private let labelView = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isPressed = false
    private var isHovering = false

    var tintColor: NSColor = .labelColor {
        didSet { iconView.contentTintColor = tintColor }
    }

    init(symbol: String, label: String, tooltip: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.toolTip = tooltip
        self.focusRingType = .none

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor

        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = tintColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        labelView.stringValue = label
        labelView.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        labelView.textColor = .secondaryLabelColor
        labelView.alignment = .center
        labelView.lineBreakMode = .byTruncatingTail
        labelView.maximumNumberOfLines = 1
        labelView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            heightAnchor.constraint(equalToConstant: 56),

            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            labelView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            labelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            labelView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        isHovering = true
        updateBackground()

        // Track until mouseUp so we get a chance to fire the action.
        var keepTracking = true
        while keepTracking {
            guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            switch next.type {
            case .leftMouseUp:
                keepTracking = false
                isPressed = false
                let inside = bounds.contains(convert(next.locationInWindow, from: nil))
                isHovering = inside
                updateBackground()
                if inside, let action {
                    NSApp.sendAction(action, to: target, from: self)
                }
            default:
                break
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highlight = isDark ? NSColor.white : NSColor.black

        if isPressed {
            layer?.backgroundColor = highlight.withAlphaComponent(isDark ? 0.18 : 0.12).cgColor
        } else if isHovering {
            layer?.backgroundColor = highlight.withAlphaComponent(isDark ? 0.08 : 0.06).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// 1pt vertical divider that tracks the current effective appearance so it
/// remains visible in both light and dark mode. Setting `cgColor` once bakes
/// in the resolved color, so we re-resolve `NSColor.separatorColor` whenever
/// the appearance changes.
private final class DividerView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateLayer() {
        super.updateLayer()
        // labelColor is dark in light mode and light in dark mode, so a low
        // alpha gives a divider that's clearly visible against the popover
        // background in both appearances.
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
