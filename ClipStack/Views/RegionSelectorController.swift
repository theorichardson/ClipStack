import AppKit
import CoreText
import ScreenCaptureKit

@MainActor
final class RegionSelectorController {
    static let shared = RegionSelectorController()

    private var windows: [NSWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?

    private init() {}

    func beginSelection(
        onSaveRegion: ((CaptureRegion, @escaping () -> Void) -> Void)? = nil,
        completion: @escaping (CaptureRegion?) -> Void
    ) {
        guard windows.isEmpty else { return }

        self.completion = completion

        let cursor = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        var selectionView: RegionSelectionView?

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

            if screen == activeScreen {
                let view = RegionSelectionView(
                    onSaveRegion: { [weak window] region, done in
                        guard let onSaveRegion else { done(); return }
                        onSaveRegion(region) { [weak window] in
                            done()
                            window?.makeKeyAndOrderFront(nil)
                        }
                    },
                    onComplete: { [weak self] region in
                        self?.finish(with: region)
                    }
                )
                window.contentView = view
                window.ignoresMouseEvents = false
                window.makeKeyAndOrderFront(nil)
                selectionView = view
            } else {
                let view = DimView()
                window.contentView = view
                window.ignoresMouseEvents = true
                window.orderFrontRegardless()
            }
            windows.append(window)
        }

        let excludedOverlayIDs = Set(windows.compactMap { overlay in
            let number = overlay.windowNumber
            return number > 0 ? CGWindowID(number) : nil
        })

        NSApp.activate(ignoringOtherApps: true)

        Task {
            let snapWindows = (try? await ScreenCaptureService.shared.availableWindows()) ?? []
            selectionView?.setSnapWindows(snapWindows, excluding: excludedOverlayIDs)
        }
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with region: CaptureRegion?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let callback = completion
        completion = nil
        callback?(region)
    }
}

private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DimView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
    }
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
    private let onSaveRegion: (CaptureRegion, @escaping () -> Void) -> Void
    private let onComplete: (CaptureRegion?) -> Void

    private var selectionRect: CGRect = .zero
    private var snapWindows: [SCWindow] = []
    private var excludedOverlayIDs: Set<CGWindowID> = []
    private var snapModifierHeld = false
    private var isSaving = false
    private let handleSize: CGFloat = 10
    private let edgeHitSlop: CGFloat = 6
    private let minSize: CGFloat = 20

    private var dragMode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var dragStartRect: CGRect = .zero

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

    private var badgeConfigured = false

    init(
        onSaveRegion: @escaping (CaptureRegion, @escaping () -> Void) -> Void,
        onComplete: @escaping (CaptureRegion?) -> Void
    ) {
        self.onSaveRegion = onSaveRegion
        self.onComplete = onComplete
        super.init(frame: .zero)
    }

    func setSnapWindows(_ windows: [SCWindow], excluding excludedIDs: Set<CGWindowID>) {
        snapWindows = windows
        excludedOverlayIDs = excludedIDs
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if selectionRect == .zero {
            let w: CGFloat = min(900, bounds.width * 0.5)
            let h: CGFloat = min(560, bounds.height * 0.5)
            selectionRect = CGRect(
                x: (bounds.width - w) / 2,
                y: (bounds.height - h) / 2,
                width: w,
                height: h
            )
        }
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
            onComplete(nil)
        case 36, 76:
            confirmSelection()
        case 1:
            requestSaveRegion()
        default:
            super.keyDown(with: event)
        }
    }

    private func currentRegion() -> CaptureRegion? {
        guard selectionRect.width >= minSize, selectionRect.height >= minSize else { return nil }
        let windowRect = convert(selectionRect, to: nil)
        guard let window else { return nil }
        let screenRect = window.convertToScreen(windowRect)
        return CaptureRegion(rect: screenRect)
    }

    private func requestSaveRegion() {
        guard !isSaving, let region = currentRegion() else { return }
        isSaving = true
        onSaveRegion(region) { [weak self] in
            self?.isSaving = false
            self?.needsDisplay = true
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let held = WindowSnapHelper.isSnapModifierHeld(event.modifierFlags)
        guard held != snapModifierHeld else { return }
        snapModifierHeld = held
        needsDisplay = true
    }

    private func confirmSelection() {
        guard let region = currentRegion() else {
            onComplete(nil)
            return
        }
        onComplete(region)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragStartRect = selectionRect

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
            var newRect = dragStartRect
            newRect.origin.x = clamp(dragStartRect.origin.x + dx, lower: 0, upper: bounds.width - dragStartRect.width)
            newRect.origin.y = clamp(dragStartRect.origin.y + dy, lower: 0, upper: bounds.height - dragStartRect.height)
            selectionRect = applySnapIfNeeded(to: newRect, cursorLocal: point, resizeEdges: nil)
        case .resize(let edges):
            var r = dragStartRect
            if edges.contains(.left) {
                let newX = min(dragStartRect.maxX - minSize, max(0, dragStartRect.origin.x + dx))
                r.size.width = dragStartRect.maxX - newX
                r.origin.x = newX
            }
            if edges.contains(.right) {
                let newW = max(minSize, min(bounds.width - dragStartRect.origin.x, dragStartRect.width + dx))
                r.size.width = newW
            }
            if edges.contains(.bottom) {
                let newY = min(dragStartRect.maxY - minSize, max(0, dragStartRect.origin.y + dy))
                r.size.height = dragStartRect.maxY - newY
                r.origin.y = newY
            }
            if edges.contains(.top) {
                let newH = max(minSize, min(bounds.height - dragStartRect.origin.y, dragStartRect.height + dy))
                r.size.height = newH
            }
            selectionRect = applySnapIfNeeded(to: r, cursorLocal: point, resizeEdges: edges)
        }

        window?.invalidateCursorRects(for: self)
        needsDisplay = true
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
        to rect: CGRect,
        cursorLocal: CGPoint,
        resizeEdges: WindowSnapEdges?
    ) -> CGRect {
        guard WindowSnapHelper.isSnapModifierHeld(NSEvent.modifierFlags), !snapWindows.isEmpty else {
            return rect
        }

        let screenFrame = window?.frame ?? bounds

        if resizeEdges == nil,
           let windowRect = WindowSnapHelper.snapToWindowUnderCursor(
               cursorLocal: cursorLocal,
               screenFrame: screenFrame,
               windows: snapWindows,
               excluding: excludedOverlayIDs,
               minSize: minSize
           ) {
            return windowRect
        }

        if let resizeEdges, !resizeEdges.isEmpty {
            let windowFrames = WindowSnapHelper.windowLocalFrames(from: snapWindows, on: screenFrame)
            return WindowSnapHelper.snapResizeEdges(
                of: rect,
                to: windowFrames,
                activeEdges: resizeEdges,
                minSize: minSize,
                bounds: bounds
            )
        }

        return rect
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
        let dimPath = NSBezierPath(rect: bounds)
        if selectionRect.width > 0, selectionRect.height > 0 {
            dimPath.appendRect(selectionRect)
        }
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dimPath.fill()

        guard selectionRect.width > 0, selectionRect.height > 0 else { return }

        let snapActive = snapModifierHeld || WindowSnapHelper.isSnapModifierHeld(NSEvent.modifierFlags)
        let strokeColor: NSColor = snapActive ? .systemOrange : .systemBlue
        strokeColor.setStroke()
        let path = NSBezierPath(rect: selectionRect)
        path.lineWidth = snapActive ? 2 : 1
        path.stroke()

        drawHandles(strokeColor: strokeColor)
        updateBadge()
    }

    private func configureBadgeIfNeeded() {
        guard !badgeConfigured else { return }
        badgeConfigured = true
        addSubview(badgeEffectView)
        badgeEffectView.addSubview(badgeLabel)
    }

    private func updateBadge() {
        guard selectionRect.width > 0, selectionRect.height > 0 else {
            badgeEffectView.isHidden = true
            return
        }

        configureBadgeIfNeeded()
        badgeEffectView.isHidden = false

        let snapActive = snapModifierHeld || WindowSnapHelper.isSnapModifierHeld(NSEvent.modifierFlags)
        let attributed = badgeAttributedString(snapActive: snapActive)
        badgeLabel.attributedText = attributed

        let padding = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        let textSize = badgeLabel.fittingSize()
        let bgSize = CGSize(
            width: textSize.width + padding.left + padding.right,
            height: textSize.height + padding.top + padding.bottom
        )

        let aboveY = selectionRect.maxY + 8
        let belowY = selectionRect.minY - bgSize.height - 8
        let originY: CGFloat = aboveY + bgSize.height <= bounds.maxY ? aboveY : max(belowY, 8)
        let originX = max(8, min(selectionRect.minX, bounds.maxX - bgSize.width - 8))
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

    private func badgeAttributedString(snapActive: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let sizeText = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
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

        result.append(NSAttributedString(string: "  ↩ Capture · S Save Region · Esc Cancel", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))

        return result
    }

    private func drawHandles(strokeColor: NSColor) {
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
