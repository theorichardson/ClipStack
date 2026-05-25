import AppKit

/// A backdrop you can render behind a screenshot to give it a polished
/// "wallpaper frame" look. The wallpaper itself is generated on demand at
/// whatever size the framing pipeline requests so it always looks crisp.
struct WallpaperFrame: Sendable, Identifiable, Hashable {
    enum Style: Sendable, Hashable {
        /// Diagonal linear gradient between two colors (top-left → bottom-right).
        case linearGradient(start: RGBA, end: RGBA)
        /// Solid background color.
        case solid(RGBA)
        /// Bundled image resource (PNG/JPEG) drawn aspect-fill at the
        /// requested size. `swatchTint` is used only for the menu icon
        /// fallback color when the image hasn't loaded yet.
        case image(resourceName: String, swatchTint: RGBA)
    }

    struct RGBA: Sendable, Hashable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var alpha: CGFloat = 1

        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
            self.red = r
            self.green = g
            self.blue = b
            self.alpha = a
        }

        static func hex(_ value: UInt32) -> RGBA {
            RGBA(
                CGFloat((value >> 16) & 0xff) / 255,
                CGFloat((value >> 8) & 0xff) / 255,
                CGFloat(value & 0xff) / 255
            )
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    let id: String
    let name: String
    let style: Style

    /// Color used to render the small swatch in the picker menu.
    var swatchColor: NSColor {
        switch style {
        case .linearGradient(let start, _):
            return start.nsColor
        case .solid(let color):
            return color.nsColor
        case .image(_, let tint):
            return tint.nsColor
        }
    }

    /// Render the wallpaper at the requested pixel size.
    func makeImage(size: CGSize) -> NSImage {
        let pixelWidth = max(1, Int(size.width.rounded()))
        let pixelHeight = max(1, Int(size.height.rounded()))
        let image = NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
        image.lockFocusFlipped(false)
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

        switch style {
        case .solid(let color):
            color.nsColor.setFill()
            rect.fill()

        case .linearGradient(let start, let end):
            // Diagonal top-left → bottom-right gradient.
            let gradient = NSGradient(
                starting: start.nsColor,
                ending: end.nsColor
            )
            gradient?.draw(in: rect, angle: -45)

        case .image(let resourceName, let tint):
            // Fallback fill so the area is never transparent if the asset
            // can't be located in the bundle for some reason.
            tint.nsColor.setFill()
            rect.fill()

            if let source = Self.loadResourceImage(named: resourceName) {
                let sourceSize = source.size
                guard sourceSize.width > 0, sourceSize.height > 0 else { break }

                // Aspect-fill: scale the source so it fully covers the
                // target rect while preserving its aspect ratio, then
                // center-crop any overflow.
                let scale = max(rect.width / sourceSize.width, rect.height / sourceSize.height)
                let drawSize = CGSize(
                    width: sourceSize.width * scale,
                    height: sourceSize.height * scale
                )
                let drawRect = CGRect(
                    x: rect.midX - drawSize.width / 2,
                    y: rect.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
                source.draw(
                    in: drawRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
        }

        return image
    }

    private static func loadResourceImage(named name: String) -> NSImage? {
        if let image = NSImage(named: name) {
            return image
        }
        // Files live in ClipStack/Resources/Wallpapers; xcodegen folds them
        // into the bundle's resources without a subdirectory, but try a few
        // common locations defensively.
        for ext in ["png", "jpg", "jpeg"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Wallpapers"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}
