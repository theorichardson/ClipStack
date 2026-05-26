import AppKit
import CoreText
import ScreenCaptureKit

enum RegionSelectionIntent {
    case screenshot
    case record
}

enum RegionSelectionResult {
    case cancelled
    case screenshot(CaptureRegion)
    case record(CaptureRegion)
}

@MainActor
final class RegionSelectorController {
    static let shared = RegionSelectorController()

    private var windows: [NSWindow] = []
    private var selectionViews: [RegionSelectionView] = []
    private var globalSelectionRect: CGRect = .zero
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var completion: ((RegionSelectionResult) -> Void)?
    private var persistRegionOnDismiss = false
    private var isModalSuspended = false

    private init() {}

    func beginSelection(
        intent: RegionSelectionIntent = .screenshot,
        initialRegion: CaptureRegion? = nil,
        persistRegionOnDismiss: Bool = false,
        onSaveRegion: ((CaptureRegion, @escaping () -> Void) -> Void)? = nil,
        completion: @escaping (RegionSelectionResult) -> Void
    ) {
        guard windows.isEmpty else { return }

        self.completion = completion
        self.persistRegionOnDismiss = persistRegionOnDismiss

        let activeScreen: NSScreen?
        if let initialRegion {
            globalSelectionRect = Self.clampInitialRegion(initialRegion.cocoaRect)
            activeScreen = ScreenCoordinates.screen(
                containingCocoaPoint: CGPoint(x: globalSelectionRect.midX, y: globalSelectionRect.midY)
            )
                ?? NSScreen.main
                ?? NSScreen.screens.first
        } else {
            let cursor = NSEvent.mouseLocation
            activeScreen = ScreenCoordinates.screen(containingCocoaPoint: cursor)
                ?? NSScreen.main
                ?? NSScreen.screens.first
            let activeFrame = activeScreen?.frame ?? ScreenCoordinates.desktopBounds

            let initialWidth = min(900, activeFrame.width * 0.5)
            let initialHeight = min(560, activeFrame.height * 0.5)
            globalSelectionRect = CGRect(
                x: activeFrame.midX - initialWidth / 2,
                y: activeFrame.midY - initialHeight / 2,
                width: initialWidth,
                height: initialHeight
            )
        }

        var keyWindow: NSWindow?

        for screen in NSScreen.screens {
            let window = KeyableBorderlessWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = RegionSelectionView(
                intent: intent,
                screenFrame: screen.frame,
                getGlobalSelection: { [weak self] in self?.globalSelectionRect ?? .zero },
                setGlobalSelection: { [weak self] rect in
                    self?.globalSelectionRect = rect
                },
                onSelectionChanged: { [weak self] in
                    self?.selectionViews.forEach { $0.refreshSelection() }
                },
                onSaveRegion: { [weak self] region, done in
                    guard let self, let onSaveRegion else { done(); return }
                    guard !self.windows.isEmpty else {
                        done()
                        return
                    }
                    self.isModalSuspended = true
                    onSaveRegion(region) { [weak self] in
                        self?.isModalSuspended = false
                        done()
                        self?.restoreInteraction()
                    }
                },
                onComplete: { [weak self] result in
                    self?.finish(with: result)
                }
            )
            window.contentView = view
            window.ignoresMouseEvents = false
            window.orderFrontRegardless()
            selectionViews.append(view)
            windows.append(window)

            if screen == activeScreen {
                keyWindow = window
            }
        }

        let excludedOverlayIDs = Set(windows.compactMap { overlay in
            let number = overlay.windowNumber
            return number > 0 ? CGWindowID(number) : nil
        })

        NSApp.activate(ignoringOtherApps: true)
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
        installKeyMonitors()

        Task {
            let snapWindows = (try? await ScreenCaptureService.shared.availableWindows()) ?? []
            selectionViews.forEach { $0.setSnapWindows(snapWindows, excluding: excludedOverlayIDs) }
        }
    }

    func cancel() {
        finish(with: .cancelled)
    }

    private func restoreInteraction() {
        guard !windows.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)

        let focusPoint = CGPoint(x: globalSelectionRect.midX, y: globalSelectionRect.midY)
        let activeScreen = ScreenCoordinates.screen(containingCocoaPoint: focusPoint)
            ?? NSScreen.main

        for window in windows {
            window.orderFrontRegardless()
        }

        if let activeScreen,
           let keyWindow = windows.first(where: { $0.screen == activeScreen }) {
            keyWindow.makeKeyAndOrderFront(nil)
            keyWindow.makeFirstResponder(keyWindow.contentView)
        } else if let keyWindow = windows.first {
            keyWindow.makeKeyAndOrderFront(nil)
            keyWindow.makeFirstResponder(keyWindow.contentView)
        }

        selectionViews.forEach { $0.refreshSelection() }
    }

    private func installKeyMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self, !self.isModalSuspended else { return }
                self.finish(with: .cancelled)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if self.isModalSuspended {
                    return event
                }
                self.finish(with: .cancelled)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitors() {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func finish(with result: RegionSelectionResult) {
        isModalSuspended = false

        if persistRegionOnDismiss {
            let current = globalSelectionRect
            if current.width >= 20, current.height >= 20 {
                LastScreenshotRegionStore.shared.save(CaptureRegion(rect: current))
            }
        }
        persistRegionOnDismiss = false

        removeKeyMonitors()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        selectionViews.removeAll()
        let callback = completion
        completion = nil
        callback?(result)
    }

    private static func clampInitialRegion(_ rect: CGRect) -> CGRect {
        let desktop = ScreenCoordinates.desktopBounds
        let minSize: CGFloat = 20
        var r = rect
        r.size.width = max(minSize, min(r.width, desktop.width))
        r.size.height = max(minSize, min(r.height, desktop.height))
        r.origin.x = max(desktop.minX, min(r.origin.x, desktop.maxX - r.width))
        r.origin.y = max(desktop.minY, min(r.origin.y, desktop.maxY - r.height))
        return r
    }
}

private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class RegionBadgeLabelView: NSView {
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

private enum DragMode {
    case move
    case resize(edges: WindowSnapEdges)
    case none
}

private final class RegionSelectionView: NSView {
    private let intent: RegionSelectionIntent
    private let screenFrame: CGRect
    private let getGlobalSelection: () -> CGRect
    private let setGlobalSelection: (CGRect) -> Void
    private let onSelectionChanged: () -> Void
    private let onSaveRegion: (CaptureRegion, @escaping () -> Void) -> Void
    private let onComplete: (RegionSelectionResult) -> Void

    private var snapWindows: [SCWindow] = []
    private var excludedOverlayIDs: Set<CGWindowID> = []
    private var snapModifierHeld = false
    private var isSaving = false
    private let handleSize: CGFloat = 10
    private let edgeHitSlop: CGFloat = 6
    private let minSize: CGFloat = 20

    private var dragMode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var dragStartGlobalRect: CGRect = .zero

    private var selectionRect: CGRect {
        ScreenCoordinates.localRect(forGlobalCocoa: getGlobalSelection(), on: screenFrame)
    }

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

    private let badgeLabel = RegionBadgeLabelView()

    private let presetPopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .inline
        popup.isBordered = false
        popup.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        popup.toolTip = "Move selection to a saved region"
        if let cell = popup.cell as? NSPopUpButtonCell {
            cell.backgroundColor = .clear
            cell.isBordered = false
        }
        return popup
    }()

    private var badgeConfigured = false
    private var presetObserver: NSObjectProtocol?

    deinit {
        if let presetObserver {
            NotificationCenter.default.removeObserver(presetObserver)
        }
    }

    init(
        intent: RegionSelectionIntent,
        screenFrame: CGRect,
        getGlobalSelection: @escaping () -> CGRect,
        setGlobalSelection: @escaping (CGRect) -> Void,
        onSelectionChanged: @escaping () -> Void,
        onSaveRegion: @escaping (CaptureRegion, @escaping () -> Void) -> Void,
        onComplete: @escaping (RegionSelectionResult) -> Void
    ) {
        self.intent = intent
        self.screenFrame = screenFrame
        self.getGlobalSelection = getGlobalSelection
        self.setGlobalSelection = setGlobalSelection
        self.onSelectionChanged = onSelectionChanged
        self.onSaveRegion = onSaveRegion
        self.onComplete = onComplete
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    func setSnapWindows(_ windows: [SCWindow], excluding excludedIDs: Set<CGWindowID>) {
        snapWindows = windows
        excludedOverlayIDs = excludedIDs
        refreshSelection()
    }

    func refreshSelection() {
        resetCursorRects()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        resetCursorRects()
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard selectionRect.width > 0 else { return }
        addCursorRect(selectionRect, cursor: .openHand)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onComplete(.cancelled)
        case 36, 76:
            confirmSelection(as: intent == .record ? .record : .screenshot)
        case 15 where intent == .screenshot:
            confirmSelection(as: .record)
        case 1:
            requestSaveRegion()
        default:
            super.keyDown(with: event)
        }
    }

    private func currentRegion() -> CaptureRegion? {
        let global = getGlobalSelection()
        guard global.width >= minSize, global.height >= minSize else { return nil }
        return CaptureRegion(rect: global)
    }

    private func requestSaveRegion() {
        guard !isSaving, let region = currentRegion() else { return }
        isSaving = true
        // Defer out of keyDown before presenting a modal alert; runModal from
        // inside keyDown leaves keyboard focus broken afterward.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.window != nil else {
                self.isSaving = false
                return
            }
            self.onSaveRegion(region) { [weak self] in
                self?.isSaving = false
                self?.needsDisplay = true
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let held = WindowSnapHelper.isSnapModifierHeld(event.modifierFlags)
        guard held != snapModifierHeld else { return }
        snapModifierHeld = held
        needsDisplay = true
    }

    private func confirmSelection(as action: RegionSelectionConfirmAction) {
        guard let region = currentRegion() else {
            onComplete(.cancelled)
            return
        }
        switch action {
        case .screenshot:
            onComplete(.screenshot(region))
        case .record:
            onComplete(.record(region))
        }
    }

    private enum RegionSelectionConfirmAction {
        case screenshot
        case record
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragStartGlobalRect = getGlobalSelection()

        let edges = edgesForResize(at: point)
        if !edges.isEmpty {
            dragMode = .resize(edges: edges)
        } else if selectionRect.insetBy(dx: -edgeHitSlop, dy: -edgeHitSlop).contains(point) {
            dragMode = .move
            NSCursor.closedHand.set()
        } else {
            dragMode = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y

        switch dragMode {
        case .none:
            return
        case .move:
            var global = dragStartGlobalRect
            global.origin.x += dx
            global.origin.y += dy
            global = applySnapIfNeeded(to: global, cursorLocal: point, resizeEdges: nil)
            setGlobalSelection(clampGlobal(global))
            onSelectionChanged()
        case .resize(let edges):
            var global = dragStartGlobalRect
            if edges.contains(.left) {
                let newX = min(dragStartGlobalRect.maxX - minSize, dragStartGlobalRect.origin.x + dx)
                global.size.width = dragStartGlobalRect.maxX - newX
                global.origin.x = newX
            }
            if edges.contains(.right) {
                global.size.width = max(minSize, dragStartGlobalRect.width + dx)
            }
            if edges.contains(.bottom) {
                let newY = min(dragStartGlobalRect.maxY - minSize, dragStartGlobalRect.origin.y + dy)
                global.size.height = dragStartGlobalRect.maxY - newY
                global.origin.y = newY
            }
            if edges.contains(.top) {
                global.size.height = max(minSize, dragStartGlobalRect.height + dy)
            }
            global = applySnapIfNeeded(to: global, cursorLocal: point, resizeEdges: edges)
            setGlobalSelection(clampGlobal(global))
            onSelectionChanged()
        }

        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = dragMode { NSCursor.openHand.set() }
        dragMode = .none
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor(for: point).set()
    }

    private func cursor(for point: CGPoint) -> NSCursor {
        let edges = edgesForResize(at: point)
        if edges.contains([.left, .top]) || edges.contains([.right, .bottom]) {
            return resizeDiagonalCursor()
        }
        if edges.contains([.right, .top]) || edges.contains([.left, .bottom]) {
            return resizeDiagonalCursor()
        }
        if edges.contains(.left) || edges.contains(.right) {
            return .resizeLeftRight
        }
        if edges.contains(.top) || edges.contains(.bottom) {
            return .resizeUpDown
        }
        if selectionRect.contains(point) {
            return .openHand
        }
        return .arrow
    }

    private func resizeDiagonalCursor() -> NSCursor {
        .crosshair
    }

    private func edgesForResize(at point: CGPoint) -> WindowSnapEdges {
        let r = selectionRect
        guard r.insetBy(dx: -edgeHitSlop, dy: -edgeHitSlop).contains(point) else { return [] }
        var edges: WindowSnapEdges = []
        if abs(point.x - r.minX) <= edgeHitSlop { edges.insert(.left) }
        if abs(point.x - r.maxX) <= edgeHitSlop { edges.insert(.right) }
        if abs(point.y - r.minY) <= edgeHitSlop { edges.insert(.bottom) }
        if abs(point.y - r.maxY) <= edgeHitSlop { edges.insert(.top) }
        return edges
    }

    private func applySnapIfNeeded(
        to globalRect: CGRect,
        cursorLocal: CGPoint,
        resizeEdges: WindowSnapEdges?
    ) -> CGRect {
        guard WindowSnapHelper.isSnapModifierHeld(NSEvent.modifierFlags), !snapWindows.isEmpty else {
            return globalRect
        }

        var local = ScreenCoordinates.localRect(forGlobalCocoa: globalRect, on: screenFrame)

        if resizeEdges == nil,
           let snappedLocal = WindowSnapHelper.snapToWindowUnderCursor(
               cursorLocal: cursorLocal,
               screenFrame: screenFrame,
               windows: snapWindows,
               excluding: excludedOverlayIDs,
               minSize: minSize
           ) {
            local = snappedLocal
        } else if let resizeEdges, !resizeEdges.isEmpty {
            let windowFrames = WindowSnapHelper.windowLocalFrames(from: snapWindows, on: screenFrame)
            local = WindowSnapHelper.snapResizeEdges(
                of: local,
                to: windowFrames,
                activeEdges: resizeEdges,
                minSize: minSize,
                bounds: bounds
            )
        } else {
            return globalRect
        }

        return CGRect(
            x: screenFrame.origin.x + local.origin.x,
            y: screenFrame.origin.y + local.origin.y,
            width: local.width,
            height: local.height
        )
    }

    private func clampGlobal(_ rect: CGRect) -> CGRect {
        let desktop = ScreenCoordinates.desktopBounds
        var r = rect
        r.size.width = max(minSize, r.width)
        r.size.height = max(minSize, r.height)
        r.origin.x = max(desktop.minX, min(r.origin.x, desktop.maxX - r.width))
        r.origin.y = max(desktop.minY, min(r.origin.y, desktop.maxY - r.height))
        return r
    }

    private func visibleSelectionRect() -> CGRect {
        selectionRect.intersection(bounds)
    }

    private func shouldShowBadge() -> Bool {
        let global = getGlobalSelection()
        let anchor = CGPoint(x: global.midX, y: global.maxY)
        return screenFrame.contains(anchor)
    }

    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = visibleSelectionRect()

        let dimPath = NSBezierPath(rect: bounds)
        if !visible.isNull, visible.width > 0, visible.height > 0 {
            dimPath.appendRect(visible)
        }
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dimPath.fill()

        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        let snapActive = snapModifierHeld || WindowSnapHelper.isSnapModifierHeld(NSEvent.modifierFlags)
        let strokeColor: NSColor = snapActive ? .systemOrange : .systemBlue
        strokeColor.setStroke()
        let path = NSBezierPath(rect: visible)
        path.lineWidth = snapActive ? 2 : 1
        path.stroke()

        drawHandles(strokeColor: strokeColor, in: visible)
        if shouldShowBadge() {
            updateBadge()
        } else {
            badgeEffectView.isHidden = true
        }
    }

    private func configureBadgeIfNeeded() {
        guard !badgeConfigured else { return }
        badgeConfigured = true
        addSubview(badgeEffectView)
        badgeEffectView.addSubview(badgeLabel)
        badgeEffectView.addSubview(presetPopup)
        presetPopup.target = self
        presetPopup.action = #selector(presetPopupChanged(_:))
        refreshPresetPopup()
        presetObserver = NotificationCenter.default.addObserver(
            forName: .capturePresetsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPresetPopup()
            self?.needsDisplay = true
        }
    }

    private func refreshPresetPopup() {
        presetPopup.removeAllItems()
        presetPopup.addItem(withTitle: "Choose region")

        let presets = CapturePresetStore.shared.presets
        if presets.isEmpty {
            let item = NSMenuItem(title: "No saved regions yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            presetPopup.menu?.addItem(item)
            presetPopup.isEnabled = false
        } else {
            presetPopup.isEnabled = true
            for preset in presets {
                let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
                item.representedObject = preset.id
                presetPopup.menu?.addItem(item)
            }
        }

        presetPopup.selectItem(at: 0)
    }

    @objc private func presetPopupChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0,
              let id = sender.selectedItem?.representedObject as? UUID,
              let preset = CapturePresetStore.shared.presets.first(where: { $0.id == id })
        else { return }

        setGlobalSelection(clampGlobal(preset.region.cocoaRect))
        onSelectionChanged()
        sender.selectItem(at: 0)
        needsDisplay = true
    }

    private func updateBadge() {
        let rect = selectionRect
        guard rect.width > 0, rect.height > 0 else {
            badgeEffectView.isHidden = true
            return
        }

        configureBadgeIfNeeded()
        badgeEffectView.isHidden = false

        let snapActive = snapModifierHeld || WindowSnapHelper.isSnapModifierHeld(NSEvent.modifierFlags)
        let global = getGlobalSelection()
        let attributed = badgeAttributedString(
            snapActive: snapActive,
            width: Int(global.width),
            height: Int(global.height)
        )
        badgeLabel.attributedText = attributed

        let padding = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        let spacing: CGFloat = 8
        let textSize = badgeLabel.fittingSize()
        presetPopup.sizeToFit()
        let popupSize = presetPopup.frame.size
        let popupWidth = popupSize.width
        let popupHeight = max(18, popupSize.height)
        let contentHeight = max(textSize.height, popupHeight)
        let bgSize = CGSize(
            width: padding.left + textSize.width + spacing + popupWidth + padding.right,
            height: contentHeight + padding.top + padding.bottom
        )

        let aboveY = selectionRect.maxY + 8
        let belowY = selectionRect.minY - bgSize.height - 8
        let originY: CGFloat = aboveY + bgSize.height <= bounds.maxY ? aboveY : max(belowY, 8)
        let originX = max(8, min(selectionRect.minX, bounds.maxX - bgSize.width - 8))
        let bgRect = CGRect(origin: CGPoint(x: originX, y: originY), size: bgSize)

        badgeEffectView.frame = bgRect
        badgeLabel.frame = CGRect(
            x: padding.left,
            y: padding.bottom + (contentHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        presetPopup.frame = CGRect(
            x: padding.left + textSize.width + spacing,
            y: padding.bottom + (contentHeight - popupHeight) / 2,
            width: popupWidth,
            height: popupHeight
        )
        badgeLabel.needsDisplay = true
    }

    private func badgeAttributedString(snapActive: Bool, width: Int, height: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let sizeText = "\(width) × \(height)"
        result.append(NSAttributedString(string: sizeText, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))

        if snapActive {
            result.append(NSAttributedString(string: "  Snapping", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]))
        } else if !snapWindows.isEmpty {
            result.append(NSAttributedString(string: "  Hold ⇧ to snap", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
        }

        result.append(NSAttributedString(
            string: intent == .screenshot
                ? "  ↩ Capture · R Record · S Save Region · Esc Cancel"
                : "  ↩ Record · S Save Region · Esc Cancel",
            attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))

        return result
    }

    private func drawHandles(strokeColor: NSColor, in visible: CGRect) {
        let r = selectionRect
        let s = handleSize
        let half = s / 2
        let points: [CGPoint] = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.midX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.midY),
            CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.maxX, y: r.maxY),
        ]
        for p in points {
            let rect = CGRect(x: p.x - half, y: p.y - half, width: s, height: s)
            guard visible.insetBy(dx: -half, dy: -half).intersects(rect) else { continue }
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            strokeColor.setStroke()
            let stroke = NSBezierPath(ovalIn: rect)
            stroke.lineWidth = 1
            stroke.stroke()
        }
    }

    private func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        max(lower, min(upper, v))
    }
}
