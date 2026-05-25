import AppKit

/// SF Symbol names for the four primary capture actions.
enum CaptureActionSymbol {
    static let screenshotRegion = "rectangle.dashed"
    static let screenshotWindow = "macwindow"
    static let recordRegion = "rectangle.dashed.badge.record"
    static let recordWindow = "macwindow.and.cursorarrow"

    static func image(for symbolName: String, pointSize: CGFloat = 13) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
