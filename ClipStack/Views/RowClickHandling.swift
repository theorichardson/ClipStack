import AppKit
import SwiftUI

extension View {
    /// Handles single- and double-click using AppKit click discrimination (macOS only).
    func onRowClick(single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        overlay {
            RowClickHandler(onSingleClick: single, onDoubleClick: double)
        }
    }
}

private struct RowClickHandler: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> RowClickHandlingView {
        let view = RowClickHandlingView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: RowClickHandlingView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class RowClickHandlingView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pendingSingleClick: DispatchWorkItem?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
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
