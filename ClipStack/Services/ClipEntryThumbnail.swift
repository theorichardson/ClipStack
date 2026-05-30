import AppKit
import AVFoundation
import ImageIO

enum ClipEntryThumbnail {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    private static let fileIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Target size for list-row thumbnails (clipboard and downloads).
    static let listThumbnailPixelSize: CGFloat = 64

    /// Target size for the keyboard panel detail preview.
    static let detailThumbnailPixelSize: CGFloat = 480

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp", "webp",
    ]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func image(
        imagePath: String?,
        textContent: String?,
        contentType: String,
        maxPixelSize: CGFloat = listThumbnailPixelSize
    ) -> NSImage? {
        visualThumbnail(
            imagePath: imagePath,
            textContent: textContent,
            contentType: contentType,
            maxPixelSize: maxPixelSize,
            cacheKeyPrefix: maxPixelSize == listThumbnailPixelSize ? "" : "detail:"
        )
    }

    static func detailImage(
        imagePath: String?,
        textContent: String?,
        contentType: String
    ) -> NSImage? {
        image(
            imagePath: imagePath,
            textContent: textContent,
            contentType: contentType,
            maxPixelSize: detailThumbnailPixelSize
        )
    }

    private static func visualThumbnail(
        imagePath: String?,
        textContent: String?,
        contentType: String,
        maxPixelSize: CGFloat,
        cacheKeyPrefix: String
    ) -> NSImage? {
        if let imagePath {
            let path = (imagePath as NSString).expandingTildeInPath
            let cacheKey = "\(cacheKeyPrefix)\(path)" as NSString
            if let cached = cache.object(forKey: cacheKey) {
                return cached
            }
            if let image = loadThumbnail(from: path, maxPixelSize: maxPixelSize) {
                cache.setObject(image, forKey: cacheKey)
                return image
            }
        }

        let typed = ClipboardContentType(rawValue: contentType) ?? .unknown
        if typed == .file, let filePath = textContent {
            let path = (filePath as NSString).expandingTildeInPath
            let cacheKey = "\(cacheKeyPrefix)\(path)" as NSString
            if let cached = cache.object(forKey: cacheKey) {
                return cached
            }
            if let image = loadThumbnail(from: path, maxPixelSize: maxPixelSize) {
                cache.setObject(image, forKey: cacheKey)
                return image
            }
        }

        return nil
    }

    static func image(for entry: ClipboardEntry) -> NSImage? {
        image(
            imagePath: entry.imagePath,
            textContent: entry.textContent,
            contentType: entry.contentType
        )
    }

    static func isVisualMediaPath(_ path: String) -> Bool {
        isImagePath(path) || isVideoPath(path)
    }

    static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isVideoPath(_ path: String) -> Bool {
        videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func detailThumbnail(forPath path: String) -> NSImage? {
        let expanded = (path as NSString).expandingTildeInPath
        let cacheKey = "detail-path:\(expanded)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = loadThumbnail(from: expanded, maxPixelSize: detailThumbnailPixelSize) else {
            return nil
        }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func loadThumbnail(from path: String, maxPixelSize: CGFloat = listThumbnailPixelSize) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if videoExtensions.contains(ext) {
            return videoThumbnail(for: url, maxPixelSize: maxPixelSize)
        }

        return downsampledImage(at: url, maxPixelSize: maxPixelSize)
    }

    static func listThumbnail(forPath path: String) -> NSImage? {
        let expanded = (path as NSString).expandingTildeInPath
        let listKey = "list:\(expanded)" as NSString
        if let cached = cache.object(forKey: listKey) {
            return cached
        }

        let detailKey = "detail-path:\(expanded)" as NSString
        if let cached = cache.object(forKey: detailKey) {
            cache.setObject(cached, forKey: listKey)
            return cached
        }

        guard let image = loadThumbnail(from: expanded, maxPixelSize: listThumbnailPixelSize) else {
            return nil
        }
        cache.setObject(image, forKey: listKey)
        return image
    }

    static func fileIcon(forExtension ext: String) -> NSImage {
        let key = (ext.isEmpty ? "__none__" : ext.lowercased()) as NSString
        if let cached = fileIconCache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFileType: ext.isEmpty ? "public.data" : ext)
        fileIconCache.setObject(icon, forKey: key)
        return icon
    }

    private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private static func videoThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
