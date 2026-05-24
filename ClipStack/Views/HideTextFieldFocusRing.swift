import AppKit
import SwiftUI

extension View {
    func hideTextFieldFocusRing() -> some View {
        background(FocusRingHiddenAnchor())
    }
}

private struct FocusRingHiddenAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            disableFocusRing(startingAt: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            disableFocusRing(startingAt: nsView)
        }
    }

    private func disableFocusRing(startingAt view: NSView) {
        var current: NSView? = view.superview
        while let currentView = current {
            if let textField = currentView as? NSTextField {
                textField.focusRingType = .none
                return
            }
            current = currentView.superview
        }
    }
}
