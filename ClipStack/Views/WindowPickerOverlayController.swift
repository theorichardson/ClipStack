import AppKit
import ScreenCaptureKit

/// Interactive "click to pick a window" overlay, modeled on macOS's
/// screenshot picker (⌘⇧4 then Space). Covers every screen with a
/// transparent layer that highlights the on-screen window under the
/// cursor; clicking selects it, Esc cancels.
@MainActor
final class WindowPickerOverlayController {
    static let shared = WindowPickerOverlayController()

    enum Result {
        case cancelled
        case capture(SCWindow)
        case record(SCWindow)
    }

    private var overlays: [Overlay] = []
    private var highlightWindow: WindowPickerHighlightWindow?
    private var availableWindows: [SCWindow] = []
    private var ownOverlayIDs: Set<CGWindowID> = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var highlightedWindow: SCWindow?
    private var completion: ((Result) -> Void)?

    private init() {}

    func cancel() {
        finish(with: .cancelled)
    }

    func pickWindow(completion: @escaping (Result) -> Void) {
        guard overlays.isEmpty else { return }

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
                self.finish(with: .cancelled)
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
                    self?.confirmCapture()
                },
                onConfirmCapture: { [weak self] in
                    self?.confirmCapture()
                },
                onConfirmRecord: { [weak self] in
                    self?.confirmRecord()
                },
                onCancel: { [weak self] in
                    self?.finish(with: .cancelled)
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

        ownOverlayIDs = overlayWindowIDs()

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
                self?.finish(with: .cancelled)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                self.finish(with: .cancelled)
                return nil
            case 36, 76:
                self.confirmCapture()
                return nil
            case 15:
                self.confirmRecord()
                return nil
            default:
                return event
            }
        }
    }

    /// Called from each overlay on mouseMoved. `globalPoint` is in Cocoa
    /// global screen coordinates.
    fileprivate func handleHover(globalPoint: CGPoint) {
        let quartzPoint = ScreenCoordinates.cocoaToQuartz(globalPoint)
        let topWindow = topmostWindow(at: quartzPoint)
        highlightedWindow = topWindow
        updateHighlight(for: topWindow)

        for overlay in overlays {
            guard let topWindow else {
                overlay.view.setBadge(rect: nil, label: nil)
                continue
            }

            let cocoaFrame = ScreenCoordinates.quartzToCocoa(topWindow.frame)
            let localRect = ScreenCoordinates.localRect(
                forGlobalCocoa: cocoaFrame,
                on: overlay.window.frame
            )
            let visible = localRect.intersection(overlay.view.bounds)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else {
                overlay.view.setBadge(rect: nil, label: nil)
                continue
            }

            overlay.view.setBadge(rect: localRect, label: badgeAttributedString(for: topWindow))
        }
    }

    /// Positions a borderless highlight window directly above the hovered
    /// target in the compositor's z-order so foreground windows cover it.
    private func updateHighlight(for window: SCWindow?) {
        guard let window else {
            highlightWindow?.orderOut(nil)
            return
        }

        let cocoaFrame = ScreenCoordinates.quartzToCocoa(window.frame)
        guard cocoaFrame.width > 0, cocoaFrame.height > 0 else {
            highlightWindow?.orderOut(nil)
            return
        }

        if highlightWindow == nil {
            let contentRect = NSRect(origin: .zero, size: cocoaFrame.size)
            let highlight = WindowPickerHighlightWindow(
                contentRect: contentRect,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            highlight.isOpaque = false
            highlight.backgroundColor = .clear
            highlight.level = .normal
            highlight.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            highlight.ignoresMouseEvents = true
            highlight.hasShadow = false
            highlight.contentView = WindowPickerHighlightView(frame: contentRect)
            highlightWindow = highlight
        }

        highlightWindow?.setFrame(cocoaFrame, display: true)
        if let contentView = highlightWindow?.contentView {
            contentView.frame = NSRect(origin: .zero, size: cocoaFrame.size)
            contentView.needsDisplay = true
        }
        highlightWindow?.order(.above, relativeTo: Int(window.windowID))
        ownOverlayIDs = overlayWindowIDs()
    }

    private func overlayWindowIDs() -> Set<CGWindowID> {
        var ids = Set(overlays.compactMap { overlay -> CGWindowID? in
            let number = overlay.window.windowNumber
            return number > 0 ? CGWindowID(number) : nil
        })
        if let highlightWindow, highlightWindow.windowNumber > 0 {
            ids.insert(CGWindowID(highlightWindow.windowNumber))
        }
        return ids
    }

    private func confirmCapture() {
        guard let highlightedWindow else { return }
        finish(with: .capture(highlightedWindow))
    }

    private func confirmRecord() {
        guard let highlightedWindow else { return }
        finish(with: .record(highlightedWindow))
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

    private func badgeAttributedString(for window: SCWindow) -> NSAttributedString {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let result = NSMutableAttributedString()

        let primary = title.isEmpty ? app : "\(app) — \(title)"
        result.append(NSAttributedString(string: primary, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        result.append(NSAttributedString(string: "  ↩ Capture · R Record · Esc Cancel", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        return result
    }

    private func finish(with result: Result) {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        for overlay in overlays { overlay.window.orderOut(nil) }
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
        overlays.removeAll()
        ownOverlayIDs.removeAll()
        availableWindows.removeAll()
        highlightedWindow = nil
        NSCursor.arrow.set()

        let callback = completion
        completion = nil
        callback?(result)
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

private final class WindowPickerHighlightWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowPickerHighlightView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: bounds).fill()

        NSColor.systemBlue.setStroke()
        let stroke = NSBezierPath(rect: bounds)
        stroke.lineWidth = 3
        stroke.stroke()
    }
}

private final class WindowPickerOverlayView: NSView {
    private let onHover: (CGPoint) -> Void
    private let onClick: () -> Void
    private let onConfirmCapture: () -> Void
    private let onConfirmRecord: () -> Void
    private let onCancel: () -> Void

    private var badgeRect: CGRect?
    private var badgeLabelText: NSAttributedString?
    private var trackingArea: NSTrackingArea?

    private let badgeHost = CaptureSelectionBadgeHost()
    private var badgeConfigured = false

    init(
        screenFrame: CGRect,
        onHover: @escaping (CGPoint) -> Void,
        onClick: @escaping () -> Void,
        onConfirmCapture: @escaping () -> Void,
        onConfirmRecord: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onHover = onHover
        self.onClick = onClick
        self.onConfirmCapture = onConfirmCapture
        self.onConfirmRecord = onConfirmRecord
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
        switch event.keyCode {
        case 53:
            onCancel()
        case 36, 76:
            onConfirmCapture()
        case 15:
            onConfirmRecord()
        default:
            super.keyDown(with: event)
        }
    }

    func setBadge(rect: CGRect?, label: NSAttributedString?) {
        badgeRect = rect
        badgeLabelText = label
        updateBadge()
    }

    private func configureBadgeIfNeeded() {
        guard !badgeConfigured else { return }
        badgeConfigured = true
        badgeHost.attach(to: self)
    }

    private func updateBadge() {
        guard let rect = badgeRect, let label = badgeLabelText else {
            badgeHost.hide()
            return
        }

        configureBadgeIfNeeded()
        badgeHost.update(anchorRect: rect, in: bounds, label: label)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Very faint dim so users know they're in picker mode without
        // obscuring the windows beneath.
        NSColor.black.withAlphaComponent(0.06).setFill()
        bounds.fill()
    }
}
