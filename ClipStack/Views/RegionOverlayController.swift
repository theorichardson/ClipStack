import AppKit

@MainActor
final class RegionOverlayController {
    static let shared = RegionOverlayController()

    private var windows: [NSWindow] = []

    private init() {}

    func show(region: CaptureRegion, label: String) {
        dismiss()

        for screen in NSScreen.screens where screen.frame.intersects(region.cocoaRect) {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true

            let view = RegionOverlayView(region: region, screenFrame: screen.frame, label: label)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class RegionOverlayView: NSView {
    private let region: CaptureRegion
    private let screenFrame: CGRect
    private let label: String

    init(region: CaptureRegion, screenFrame: CGRect, label: String) {
        self.region = region
        self.screenFrame = screenFrame
        self.label = label
        super.init(frame: screenFrame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let globalRect = region.cocoaRect
        let localRect = CGRect(
            x: globalRect.origin.x - screenFrame.origin.x,
            y: globalRect.origin.y - screenFrame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )

        guard bounds.intersects(localRect) else { return }

        NSColor.systemGreen.setStroke()
        let path = NSBezierPath(rect: localRect)
        path.lineWidth = 1
        let dash: [CGFloat] = [6, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.systemGreen,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let origin = CGPoint(
            x: localRect.minX + 8,
            y: min(localRect.maxY + 8, bounds.maxY - size.height - 8)
        )
        (label as NSString).draw(at: origin, withAttributes: attributes)
    }
}
