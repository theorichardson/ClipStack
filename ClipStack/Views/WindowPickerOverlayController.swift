import AppKit
import CoreText
import ScreenCaptureKit

/// Interactive "click to pick a window" overlay, modeled on macOS's
/// screenshot picker (⌘⇧4 then Space). Covers every screen with a
/// transparent layer that highlights the on-screen window under the
/// cursor; clicking selects it, Esc cancels.
@MainActor
final class WindowPickerOverlayController {
    static let shared = WindowPickerOverlayController()

    enum Mode {
        case capture
        case record

        fileprivate var actionLabel: String {
            switch self {
            case .capture: "Click to capture"
            case .record: "Click to record"
            }
        }
    }

    private var overlays: [Overlay] = []
    private var availableWindows: [SCWindow] = []
    private var ownOverlayIDs: Set<CGWindowID> = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var mode: Mode = .record
    private var completion: ((SCWindow?) -> Void)?

    private init() {}

    func cancel() {
        finish(with: nil)
    }

    func pickWindow(mode: Mode = .record, completion: @escaping (SCWindow?) -> Void) {
        guard overlays.isEmpty else { return }

        self.mode = mode
        self.completion = completion

        Task {
            do {
                let windows = try await ScreenCaptureService.shared.availableWindows()
                guard !windows.isEmpty else {
                    throw ScreenCaptureError.noWindowsAvailable
                }
                self.start(with: windows)
            } catch {
                self.presentError(error)
                self.finish(with: nil)
            }
        }
    }

    private func start(with windows: [SCWindow]) {
        availableWindows = windows

        for screen in NSScreen.screens {
            let view = WindowPickerOverlayView(
                screenFrame: screen.frame,
                onHover: { [weak self] point in
                    self?.handleHover(globalPoint: point)
                },
                onClick: { [weak self] in
                    self?.handleClick()
                },
                onCancel: { [weak self] in
                    self?.finish(with: nil)
                }
            )

            let window = KeyableOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.hasShadow = false
            window.contentView = view

            overlays.append(Overlay(window: window, view: view))
        }

        ownOverlayIDs = Set(overlays.compactMap { overlay in
            let n = overlay.window.windowNumber
            return n > 0 ? CGWindowID(n) : nil
        })

        for overlay in overlays {
            overlay.window.orderFrontRegardless()
        }

        NSCursor.crosshair.set()
        NSApp.activate(ignoringOtherApps: true)

        let cursor = NSEvent.mouseLocation
        let activeOverlay = overlays.first(where: { $0.window.screen?.frame.contains(cursor) ?? false })
            ?? overlays.first
        activeOverlay?.window.makeKeyAndOrderFront(nil)
        if let activeOverlay {
            activeOverlay.window.makeFirstResponder(activeOverlay.view)
        }

        installKeyMonitors()
        // Prime the highlight using the current mouse position.
        handleHover(globalPoint: NSEvent.mouseLocation)
    }

    private func installKeyMonitors() {
        // LSUIElement menu-bar apps never become the active app, so a local
        // key monitor alone is unreliable. Mirror RegionSelectorController's
        // key-window path, and add a global monitor as backup (same pattern
        // as StatusBarPopoverController's outside-click dismissal).
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                self?.finish(with: nil)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.finish(with: nil)
                return nil
            }
            return event
        }
    }

    /// Called from each overlay on mouseMoved. `globalPoint` is in Cocoa
    /// global screen coordinates.
    fileprivate func handleHover(globalPoint: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height
        // Convert Cocoa (origin bottom-left of primary) → Quartz (origin
        // top-left of primary) for CGWindowList lookups.
        let quartzPoint = CGPoint(x: globalPoint.x, y: primaryHeight - globalPoint.y)

        let topWindow = topmostWindow(at: quartzPoint)

        for overlay in overlays {
            if let topWindow {
                let cocoaFrame = cocoaFrame(forQuartzFrame: topWindow.frame, primaryHeight: primaryHeight)
                let windowOrigin = overlay.window.frame.origin
                let localRect = CGRect(
                    x: cocoaFrame.origin.x - windowOrigin.x,
                    y: cocoaFrame.origin.y - windowOrigin.y,
                    width: cocoaFrame.width,
                    height: cocoaFrame.height
                )
                overlay.view.setHighlight(rect: localRect, label: badgeAttributedString(for: topWindow))
            } else {
                overlay.view.setHighlight(rect: nil, label: nil)
            }
        }
    }

    private func handleClick() {
        guard let primary = NSScreen.screens.first else { finish(with: nil); return }
        let primaryHeight = primary.frame.height
        let cocoa = NSEvent.mouseLocation
        let quartz = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)

        guard let chosen = topmostWindow(at: quartz) else {
            // Click missed any pickable window — keep picking.
            return
        }
        finish(with: chosen)
    }

    private func topmostWindow(at quartzPoint: CGPoint) -> SCWindow? {
        // Use CGWindowListCopyWindowInfo because it returns windows in
        // front-to-back z order; SCShareableContent does too but we need
        // to filter out our own overlays and non-pickable layers, and the
        // CG list lets us match by windowID quickly.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let byID: [CGWindowID: SCWindow] = Dictionary(uniqueKeysWithValues: availableWindows.map { (CGWindowID($0.windowID), $0) })

        for info in raw {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let number = info[kCGWindowNumber as String] as? Int
            else { continue }

            let id = CGWindowID(number)
            if ownOverlayIDs.contains(id) { continue }

            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            guard bounds.contains(quartzPoint) else { continue }

            if let sc = byID[id] { return sc }
            // Skipping windows that aren't shareable (probably belong to
            // processes the user hasn't granted ScreenRecording access to
            // for the specific window) — keep walking back.
        }
        return nil
    }

    private func cocoaFrame(forQuartzFrame frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private func badgeAttributedString(for window: SCWindow) -> NSAttributedString {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let result = NSMutableAttributedString()

        let primary = title.isEmpty ? app : "\(app) — \(title)"
        result.append(NSAttributedString(string: primary, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        result.append(NSAttributedString(string: "  \(mode.actionLabel) · Esc Cancel", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        return result
    }

    private func finish(with window: SCWindow?) {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        for overlay in overlays { overlay.window.orderOut(nil) }
        overlays.removeAll()
        ownOverlayIDs.removeAll()
        availableWindows.removeAll()
        NSCursor.arrow.set()

        let callback = completion
        completion = nil
        callback?(window)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClipStack Couldn't List Windows"
        alert.informativeText = error.localizedDescription
        if let recovery = (error as? LocalizedError)?.recoverySuggestion {
            alert.informativeText += "\n\n\(recovery)"
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Overlay window + view

private struct Overlay {
    let window: KeyableOverlayWindow
    let view: WindowPickerOverlayView
}

private final class KeyableOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class WindowPickerBadgeLabelView: NSView {
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

private final class WindowPickerOverlayView: NSView {
    private let onHover: (CGPoint) -> Void
    private let onClick: () -> Void
    private let onCancel: () -> Void

    private var highlightRect: CGRect?
    private var highlightLabel: NSAttributedString?
    private var trackingArea: NSTrackingArea?

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

    private let badgeLabel = WindowPickerBadgeLabelView()
    private var badgeConfigured = false

    init(
        screenFrame: CGRect,
        onHover: @escaping (CGPoint) -> Void,
        onClick: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onHover = onHover
        self.onClick = onClick
        self.onCancel = onCancel
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        onHover(NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        onHover(NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    func setHighlight(rect: CGRect?, label: NSAttributedString?) {
        highlightRect = rect
        highlightLabel = label
        needsDisplay = true
        updateBadge()
    }

    private func configureBadgeIfNeeded() {
        guard !badgeConfigured else { return }
        badgeConfigured = true
        addSubview(badgeEffectView)
        badgeEffectView.addSubview(badgeLabel)
    }

    private func updateBadge() {
        guard let rect = highlightRect, let label = highlightLabel else {
            badgeEffectView.isHidden = true
            return
        }

        configureBadgeIfNeeded()
        badgeEffectView.isHidden = false
        badgeLabel.attributedText = label

        let padding = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        let textSize = badgeLabel.fittingSize()
        let bgSize = CGSize(
            width: textSize.width + padding.left + padding.right,
            height: textSize.height + padding.top + padding.bottom
        )

        let aboveY = rect.maxY + 8
        let belowY = rect.minY - bgSize.height - 8
        let originY: CGFloat = aboveY + bgSize.height <= bounds.maxY ? aboveY : max(belowY, 8)
        let originX = max(8, min(rect.minX, bounds.maxX - bgSize.width - 8))
        let bgRect = CGRect(origin: CGPoint(x: originX, y: originY), size: bgSize)

        badgeEffectView.frame = bgRect
        badgeLabel.frame = CGRect(
            x: padding.left,
            y: padding.bottom,
            width: textSize.width,
            height: textSize.height
        )
        badgeLabel.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Very faint dim so users know they're in picker mode without
        // obscuring the windows beneath.
        NSColor.black.withAlphaComponent(0.06).setFill()
        bounds.fill()

        guard let rect = highlightRect else { return }
        // Intersect with bounds so we only draw the portion on this screen.
        let visible = rect.intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: visible).fill()

        NSColor.systemBlue.setStroke()
        let stroke = NSBezierPath(rect: visible)
        stroke.lineWidth = 3
        stroke.stroke()
    }
}
