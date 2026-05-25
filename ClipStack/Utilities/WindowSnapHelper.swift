import AppKit
import ScreenCaptureKit

struct WindowSnapEdges: OptionSet {
    let rawValue: Int
    static let left   = WindowSnapEdges(rawValue: 1 << 0)
    static let right  = WindowSnapEdges(rawValue: 1 << 1)
    static let bottom = WindowSnapEdges(rawValue: 1 << 2)
    static let top    = WindowSnapEdges(rawValue: 1 << 3)
}

enum WindowSnapHelper {
    static let edgeThreshold: CGFloat = 12

    static func isSnapModifierHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.shift)
    }

    static func cocoaFrame(for quartzFrame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return quartzFrame }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: quartzFrame.origin.x,
            y: primaryHeight - quartzFrame.origin.y - quartzFrame.height,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }

    static func localFrame(forCocoaScreenFrame frame: CGRect, on screenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x - screenFrame.origin.x,
            y: frame.origin.y - screenFrame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    static func topmostShareableWindow(
        at cocoaPoint: CGPoint,
        in availableWindows: [SCWindow],
        excluding excludedIDs: Set<CGWindowID>
    ) -> SCWindow? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        let quartzPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)

        let byID = Dictionary(uniqueKeysWithValues: availableWindows.map { (CGWindowID($0.windowID), $0) })
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in raw {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let number = info[kCGWindowNumber as String] as? Int
            else { continue }

            let id = CGWindowID(number)
            if excludedIDs.contains(id) { continue }

            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.contains(quartzPoint)
            else { continue }

            if let sc = byID[id] { return sc }
        }
        return nil
    }

    static func windowLocalFrames(from windows: [SCWindow], on screenFrame: CGRect) -> [CGRect] {
        windows.compactMap { window in
            let cocoa = cocoaFrame(for: window.frame)
            let local = localFrame(forCocoaScreenFrame: cocoa, on: screenFrame)
            guard local.intersects(CGRect(origin: .zero, size: screenFrame.size)) else { return nil }
            return local
        }
    }

    static func snapToWindowUnderCursor(
        cursorLocal: CGPoint,
        screenFrame: CGRect,
        windows: [SCWindow],
        excluding excludedIDs: Set<CGWindowID>,
        minSize: CGFloat
    ) -> CGRect? {
        let cocoaCursor = CGPoint(
            x: screenFrame.origin.x + cursorLocal.x,
            y: screenFrame.origin.y + cursorLocal.y
        )
        guard let window = topmostShareableWindow(at: cocoaCursor, in: windows, excluding: excludedIDs) else {
            return nil
        }
        let local = localFrame(forCocoaScreenFrame: cocoaFrame(for: window.frame), on: screenFrame)
        return clampRect(local, to: CGRect(origin: .zero, size: screenFrame.size), minSize: minSize)
    }

    static func snapResizeEdges(
        of rect: CGRect,
        to windowFrames: [CGRect],
        activeEdges: WindowSnapEdges,
        threshold: CGFloat = edgeThreshold,
        minSize: CGFloat,
        bounds: CGRect
    ) -> CGRect {
        var r = rect

        var xTargets: [CGFloat] = []
        var yTargets: [CGFloat] = []
        for frame in windowFrames {
            xTargets.append(contentsOf: [frame.minX, frame.maxX])
            yTargets.append(contentsOf: [frame.minY, frame.maxY])
        }

        if activeEdges.contains(.left), let snap = nearestValue(to: r.minX, among: xTargets, within: threshold) {
            let newWidth = r.maxX - snap
            if newWidth >= minSize {
                r.origin.x = snap
                r.size.width = newWidth
            }
        }

        if activeEdges.contains(.right), let snap = nearestValue(to: r.maxX, among: xTargets, within: threshold) {
            let newWidth = snap - r.minX
            if newWidth >= minSize {
                r.size.width = newWidth
            }
        }

        if activeEdges.contains(.bottom), let snap = nearestValue(to: r.minY, among: yTargets, within: threshold) {
            let newHeight = r.maxY - snap
            if newHeight >= minSize {
                r.origin.y = snap
                r.size.height = newHeight
            }
        }

        if activeEdges.contains(.top), let snap = nearestValue(to: r.maxY, among: yTargets, within: threshold) {
            let newHeight = snap - r.minY
            if newHeight >= minSize {
                r.size.height = newHeight
            }
        }

        return clampRect(r, to: bounds, minSize: minSize)
    }

    private static func nearestValue(to value: CGFloat, among targets: [CGFloat], within threshold: CGFloat) -> CGFloat? {
        var best: (distance: CGFloat, target: CGFloat)?
        for target in targets {
            let distance = abs(value - target)
            guard distance <= threshold else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, target)
            }
        }
        return best?.target
    }

    private static func clampRect(_ rect: CGRect, to bounds: CGRect, minSize: CGFloat) -> CGRect {
        var r = rect
        r.size.width = max(minSize, min(r.width, bounds.width))
        r.size.height = max(minSize, min(r.height, bounds.height))
        r.origin.x = max(bounds.minX, min(r.origin.x, bounds.maxX - r.width))
        r.origin.y = max(bounds.minY, min(r.origin.y, bounds.maxY - r.height))
        return r
    }
}
