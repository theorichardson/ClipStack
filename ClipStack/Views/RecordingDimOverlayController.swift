import AppKit

/// Persistent dim overlay shown for the duration of a region recording.
/// Mirrors the dimming used in `RegionSelectorController` (rest of screen
/// dimmed, region kept clear) but without the blue selection frame,
/// handles, or any interaction — purely a visual reminder of what's
/// being recorded.
@MainActor
final class RecordingDimOverlayController {
    static let shared = RecordingDimOverlayController()

    private var windows: [NSWindow] = []

    private init() {}

    func show(region: CaptureRegion) {
        dismiss()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            // Sit above normal windows but below modal alerts / status menus.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.hasShadow = false

            let view = RecordingDimOverlayView(region: region, screenFrame: screen.frame)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class RecordingDimOverlayView: NSView {
    private let region: CaptureRegion
    private let screenFrame: CGRect

    init(region: CaptureRegion, screenFrame: CGRect) {
        self.region = region
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Region is in global Cocoa screen coordinates; convert to this
        // screen's local coordinates (window frame matches the screen).
        let global = region.cocoaRect
        let localRegion = CGRect(
            x: global.origin.x - screenFrame.origin.x,
            y: global.origin.y - screenFrame.origin.y,
            width: global.width,
            height: global.height
        )

        let dimPath = NSBezierPath(rect: bounds)
        let hole = localRegion.intersection(bounds)
        if !hole.isNull, hole.width > 0, hole.height > 0 {
            dimPath.appendRect(hole)
            dimPath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dimPath.fill()
    }
}
