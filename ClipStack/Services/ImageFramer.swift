import AppKit
import CoreImage

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
        /// Corner radius for a solid rectangular capture, in source pixels.
        /// Window captures already include the system corner mask in their
        /// alpha, so they follow that shape instead of this radius.
        var screenshotCornerRadius: CGFloat = 16
        /// Soft ambient shadow — the broad falloff under a floating window.
        var screenshotShadowOpacity: CGFloat = 0.35
        var screenshotShadowRadius: CGFloat = 32
        var screenshotShadowOffset: CGSize = CGSize(width: 0, height: -8)
        /// Tight contact shadow — the crisp edge macOS windows sit on.
        var screenshotContactShadowOpacity: CGFloat = 0.22
        var screenshotContactShadowRadius: CGFloat = 4
        var screenshotContactShadowOffset: CGSize = CGSize(width: 0, height: -2)
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

        // 2. Screenshot — centered, with a macOS-style drop shadow so it
        //    reads as a floating window on the backdrop.
        let screenshotRect = CGRect(
            x: ((canvasWidth - screenshotWidth) / 2).rounded(),
            y: ((canvasHeight - screenshotHeight) / 2).rounded(),
            width: screenshotWidth,
            height: screenshotHeight
        )

        if hasTransparentCorners(sourceCG) {
            // Window captures from ScreenCaptureKit already mask to the
            // system corner radius (larger, and continuous, on macOS 26).
            // A fixed rounded-rect silhouette shows through those corners
            // as a white cell. Cast the shadow from the image alpha instead.
            if let shadow = makeShapeShadow(
                image: sourceCG,
                canvasSize: canvasSize,
                imageRect: screenshotRect,
                options: options
            ) {
                context.draw(shadow, in: CGRect(origin: .zero, size: canvasSize))
            }
            context.draw(sourceCG, in: screenshotRect)
        } else {
            let cornerPath = CGPath(
                roundedRect: screenshotRect,
                cornerWidth: options.screenshotCornerRadius,
                cornerHeight: options.screenshotCornerRadius,
                transform: nil
            )

            // Shadows must come from a filled path. Clipping before draw()
            // suppresses the shadow entirely, so paint the silhouette first,
            // then the image. The image is opaque, so the white fill stays hidden.
            let shadowSilhouette = NSColor.white.cgColor

            context.saveGState()
            context.setShadow(
                offset: options.screenshotContactShadowOffset,
                blur: options.screenshotContactShadowRadius,
                color: NSColor(white: 0, alpha: options.screenshotContactShadowOpacity).cgColor
            )
            context.addPath(cornerPath)
            context.setFillColor(shadowSilhouette)
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.setShadow(
                offset: options.screenshotShadowOffset,
                blur: options.screenshotShadowRadius,
                color: NSColor(white: 0, alpha: options.screenshotShadowOpacity).cgColor
            )
            context.addPath(cornerPath)
            context.setFillColor(shadowSilhouette)
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.addPath(cornerPath)
            context.clip()
            context.draw(sourceCG, in: screenshotRect)
            context.restoreGState()
        }

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

    private static let ciContext: CIContext = {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
        ])
    }()

    /// True when every corner of the bitmap is clear, which is how
    /// ScreenCaptureKit returns a window: the pixels outside the window's
    /// rounded corners are transparent.
    private static func hasTransparentCorners(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return false }
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width - 1, y: 0),
            CGPoint(x: 0, y: height - 1),
            CGPoint(x: width - 1, y: height - 1),
        ]
        return corners.allSatisfy { alpha(of: image, at: $0) < 0.02 }
    }

    private static func alpha(of image: CGImage, at point: CGPoint) -> CGFloat {
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        guard let cropped = image.cropping(to: rect) else { return 1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 1 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(pixel[3]) / 255
    }

    /// Soft contact + ambient shadow that follows `image`'s alpha, with no
    /// opaque silhouette left behind.
    private static func makeShapeShadow(
        image: CGImage,
        canvasSize: CGSize,
        imageRect: CGRect,
        options: Options
    ) -> CGImage? {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let placed = CIImage(cgImage: image).transformed(
            by: CGAffineTransform(translationX: imageRect.minX, y: imageRect.minY)
        )

        func shadowLayer(offset: CGSize, blur: CGFloat, opacity: CGFloat) -> CIImage {
            let silhouette = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
            // CGContext shadow blur is about twice CIGaussianBlur's radius.
            return silhouette
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur / 2])
                .transformed(by: CGAffineTransform(translationX: offset.width, y: offset.height))
        }

        let contact = shadowLayer(
            offset: options.screenshotContactShadowOffset,
            blur: options.screenshotContactShadowRadius,
            opacity: options.screenshotContactShadowOpacity
        )
        let ambient = shadowLayer(
            offset: options.screenshotShadowOffset,
            blur: options.screenshotShadowRadius,
            opacity: options.screenshotShadowOpacity
        )
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvasRect)
        let combined = contact.composited(over: ambient).composited(over: clear).cropped(to: canvasRect)
        return ciContext.createCGImage(combined, from: canvasRect)
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
