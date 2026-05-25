import AppKit
import AVFoundation

enum ClipEntryThumbnail {
    private static let cache = NSCache<NSString, NSImage>()

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp", "webp",
    ]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func image(
        imagePath: String?,
        textContent: String?,
        contentType: String
    ) -> NSImage? {
        if let imagePath {
            let path = (imagePath as NSString).expandingTildeInPath
            if let cached = cache.object(forKey: path as NSString) {
                return cached
            }
            if let image = loadThumbnail(from: path) {
                cache.setObject(image, forKey: path as NSString)
                return image
            }
        }

        let typed = ClipboardContentType(rawValue: contentType) ?? .unknown
        if typed == .file, let filePath = textContent {
            let path = (filePath as NSString).expandingTildeInPath
            if let cached = cache.object(forKey: path as NSString) {
                return cached
            }
            if let image = loadThumbnail(from: path) {
                cache.setObject(image, forKey: path as NSString)
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
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    private static func loadThumbnail(from path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if videoExtensions.contains(ext) {
            return videoThumbnail(for: url)
        }

        if imageExtensions.contains(ext) {
            return NSImage(contentsOf: url)
        }

        return NSImage(contentsOf: url)
    }

    private static func videoThumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 128, height: 128)

        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
