import AppKit
import SwiftUI

struct RowClickHandler: NSViewRepresentable {
    @Binding var isHovered: Bool
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> RowClickHandlingView {
        let view = RowClickHandlingView()
        view.onHoverChanged = { hovering in
            isHovered = hovering
        }
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: RowClickHandlingView, context: Context) {
        nsView.onHoverChanged = { hovering in
            isHovered = hovering
        }
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ nsView: RowClickHandlingView, context: Context) {
        nsView.clearHover()
    }
}

final class RowClickHandlingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pendingSingleClick: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area

        // During scrolling, AppKit does not reliably deliver `mouseExited` for
        // rows that move out from under the cursor, which leaves stale rows
        // marked as hovered. Reconcile against the real cursor position
        // whenever tracking areas update (scroll, layout, window changes).
        syncHoverFromCursor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        if window == nil {
            clearHover()
        }
    }

    private func syncHoverFromCursor() {
        guard let window, window.isKeyWindow else {
            clearHover()
            return
        }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = convert(pointInWindow, from: nil)
        let visibleInside = visibleRect.contains(pointInView)
        let inside = visibleInside && bounds.contains(pointInView)
        if inside, !isHovering {
            setHover(true)
        } else if !inside, isHovering {
            clearHover()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    private func setHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHoverChanged?(hovering)
        if hovering {
            NSCursor.dragCopy.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func clearHover() {
        setHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick?()
            return
        }

        guard event.clickCount == 1 else { return }

        pendingSingleClick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onSingleClick?()
            self?.pendingSingleClick = nil
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval,
            execute: work
        )
    }

    deinit {
        pendingSingleClick?.cancel()
    }
}
