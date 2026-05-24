import AppKit
import SwiftUI

@MainActor
final class PanelController: NSObject {
    static let shared = PanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Builds the panel without showing it. Rendering warm-up happens on first show.
    func prepare() {
        guard panel == nil else { return }
        buildPanel()
    }

    func show() {
        if panel == nil {
            buildPanel()
            warmUpRendering()
        }

        guard let panel, let hostingView else { return }

        positionPanel(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.alphaValue = 1

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hostingView)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipStackPanelDidShow, object: nil)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "ClipStack"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.titlebarSeparatorStyle = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.animationBehavior = .none
        panel.backgroundColor = .windowBackgroundColor
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        let rootView = AnyView(
            ClipboardKeyboardView(onDismiss: { [weak self] in
                self?.hide()
            })
            .modelContainer(AppModelContainer.shared)
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
    }

    private func warmUpRendering() {
        guard let panel, let hostingView else { return }

        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        panel.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let panelSize = panel.frame.size
        var origin = NSPoint(
            x: mouseLocation.x - panelSize.width / 2,
            y: mouseLocation.y - panelSize.height - 12
        )

        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)

        panel.setFrameOrigin(origin)
    }
}

extension PanelController: NSWindowDelegate {
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            hide()
        }
    }
}

extension Notification.Name {
    static let clipStackPanelDidShow = Notification.Name("clipStackPanelDidShow")
}
