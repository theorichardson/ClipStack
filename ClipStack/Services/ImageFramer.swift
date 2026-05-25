import AppKit

/// Composes a screenshot inside a wallpaper "frame" — wallpaper background,
/// consistent padding, rounded screenshot with a subtle shadow — and writes
/// the result alongside the original capture.
enum ImageFramer {
    enum FrameError: LocalizedError {
        case loadFailed
        case encodeFailed
        case unsupportedSource

        var errorDescription: String? {
            switch self {
            case .loadFailed: "ClipStack couldn't read the captured image to frame it."
            case .encodeFailed: "ClipStack couldn't encode the framed image."
            case .unsupportedSource: "Framing is only supported for screenshot images."
            }
        }
    }

    struct Options {
        /// Minimum padding (source-pixel units) between the screenshot and
        /// the nearest edge of the wallpaper canvas. The canvas itself is
        /// expanded as needed to satisfy `aspectRatio`, so padding on the
        /// non-constraining axis will be larger than this value.
        var minPadding: CGFloat = 96
        /// Width / height ratio of the output canvas. Defaults to a typical
        /// MacBook display (16:10) so screenshots — regardless of their own
        /// shape — sit inside a laptop-shaped frame.
        var aspectRatio: CGFloat = 16.0 / 10.0
        var screenshotCornerRadius: CGFloat = 16
        var screenshotShadowOpacity: CGFloat = 0.35
        var screenshotShadowRadius: CGFloat = 32
        var screenshotShadowOffset: CGSize = CGSize(width: 0, height: -10)
    }

    /// Render `sourceURL` inside `frame` and write a new PNG next to the
    /// original. Returns the URL of the new file.
    @discardableResult
    static func frameImage(
        at sourceURL: URL,
        with frame: WallpaperFrame,
        options: Options = Options()
    ) throws -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "tif", "tiff", "heic"].contains(ext) else {
            throw FrameError.unsupportedSource
        }

        guard let source = NSImage(contentsOf: sourceURL),
              let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw FrameError.loadFailed
        }

        let screenshotWidth = CGFloat(sourceCG.width)
        let screenshotHeight = CGFloat(sourceCG.height)

        // Canvas must be at least `minPadding` away from the screenshot on
        // every side AND match the requested aspect ratio. Pick the smaller
        // of the two axes as the constraint and expand the other to suit.
        let aspect = max(0.1, options.aspectRatio)
        let minWidth = screenshotWidth + options.minPadding * 2
        let minHeight = screenshotHeight + options.minPadding * 2
        let canvasWidth = max(minWidth, minHeight * aspect).rounded()
        let canvasHeight = (canvasWidth / aspect).rounded()
        let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(canvasWidth),
            height: Int(canvasHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FrameError.encodeFailed
        }

        // 1. Wallpaper background.
        let wallpaper = frame.makeImage(size: canvasSize)
        if let wallpaperCG = wallpaper.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(wallpaperCG, in: CGRect(origin: .zero, size: canvasSize))
        }

        // 2. Screenshot — centered, drawn rounded with a soft shadow so it
        //    feels inset inside the laptop-shaped wallpaper frame.
        let screenshotRect = CGRect(
            x: ((canvasWidth - screenshotWidth) / 2).rounded(),
            y: ((canvasHeight - screenshotHeight) / 2).rounded(),
            width: screenshotWidth,
            height: screenshotHeight
        )

        context.saveGState()
        context.setShadow(
            offset: options.screenshotShadowOffset,
            blur: options.screenshotShadowRadius,
            color: NSColor(white: 0, alpha: options.screenshotShadowOpacity).cgColor
        )

        let cornerPath = CGPath(
            roundedRect: screenshotRect,
            cornerWidth: options.screenshotCornerRadius,
            cornerHeight: options.screenshotCornerRadius,
            transform: nil
        )
        context.addPath(cornerPath)
        context.clip()
        context.draw(sourceCG, in: screenshotRect)
        context.restoreGState()

        guard let composedCG = context.makeImage() else {
            throw FrameError.encodeFailed
        }

        let bitmap = NSBitmapImageRep(cgImage: composedCG)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FrameError.encodeFailed
        }

        let destinationURL = makeDestinationURL(for: sourceURL, frame: frame)
        try data.write(to: destinationURL)
        return destinationURL
    }

    private static func makeDestinationURL(for sourceURL: URL, frame: WallpaperFrame) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let safeFrame = frame.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var candidate = directory.appendingPathComponent("\(base) - \(safeFrame).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) - \(safeFrame) \(counter).png")
            counter += 1
        }
        return candidate
    }
}
