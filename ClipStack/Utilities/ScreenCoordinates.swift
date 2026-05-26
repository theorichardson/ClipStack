import AppKit
import CoreGraphics

/// Converts between AppKit's global Cocoa coordinate space (origin at the
/// bottom-left of the primary display) and the Quartz global space used by
/// ScreenCaptureKit, CGWindowList, and SCWindow/SCDisplay frames (origin at
/// the top-left of the primary display).
enum ScreenCoordinates {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static var desktopBounds: CGRect {
        NSScreen.screens.reduce(into: CGRect.null) { partial, screen in
            partial = partial.isNull ? screen.frame : partial.union(screen.frame)
        }
    }

    static func cocoaToQuartz(_ rect: CGRect) -> CGRect {
        let height = primaryHeight
        return CGRect(
            x: rect.origin.x,
            y: height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func quartzToCocoa(_ rect: CGRect) -> CGRect {
        let height = primaryHeight
        return CGRect(
            x: rect.origin.x,
            y: height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func cocoaToQuartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func quartzToCocoa(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func localRect(forGlobalCocoa rect: CGRect, on screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(containingCocoaPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func sourceRect(forCocoaRegion region: CGRect, onQuartzDisplayFrame displayFrame: CGRect) -> CGRect {
        let globalQuartz = cocoaToQuartz(region)
        return CGRect(
            x: globalQuartz.origin.x - displayFrame.origin.x,
            y: globalQuartz.origin.y - displayFrame.origin.y,
            width: region.width,
            height: region.height
        )
    }
}
