import AppKit
import Foundation

@MainActor
final class PasteboardMonitor: ObservableObject {
    static let shared = PasteboardMonitor()

    private static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    private static let handoffType = NSPasteboard.PasteboardType("com.apple.handoffpasteboard")

    private var timer: Timer?
    private var lastChangeCount: Int
    private var isInternalCopy = false

    var onNewEntry: ((ParsedClipboardItem) -> Void)?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPasteboard()
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func copyToPasteboard(_ item: ParsedClipboardItem) {
        isInternalCopy = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isInternalCopy = false
                self?.lastChangeCount = NSPasteboard.general.changeCount
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.contentType {
        case .text, .url, .rtf, .unknown:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                pasteboard.writeObjects([image])
            } else if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .file:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        checkPasteboard()
    }

    private func checkPasteboard() {
        guard !isInternalCopy else { return }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let parsed = parsePasteboard(pasteboard) else { return }
        onNewEntry?(parsed)
    }

    private func parsePasteboard(_ pasteboard: NSPasteboard) -> ParsedClipboardItem? {
        let types = Set(pasteboard.types ?? [])
        let isUniversal = types.contains(Self.remoteClipboardType) || types.contains(Self.handoffType)
        let source: ClipboardSource = isUniversal ? .universal : .local
        let origin = Self.sourceAppOrigin(isUniversal: isUniversal)
        let sourceAppName = origin.name
        let sourceAppBundleID = origin.bundleID

        if let image = NSImage(pasteboard: pasteboard) {
            let imagePath = Self.storeImage(image)
            return ParsedClipboardItem(
                contentType: .image,
                textContent: nil,
                imagePath: imagePath,
                preview: "Image",
                source: source,
                sourceAppName: sourceAppName,
                sourceAppBundleID: sourceAppBundleID,
                searchableText: "image photo picture \(sourceAppName)"
            )
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let fileURL = urls.first,
           urls.count == 1,
           fileURL.isFileURL {
            let path = fileURL.path
            if ClipEntryThumbnail.isVisualMediaPath(path),
               let image = NSImage(contentsOf: fileURL),
               let imagePath = Self.storeImage(image) {
                return ParsedClipboardItem(
                    contentType: .image,
                    textContent: nil,
                    imagePath: imagePath,
                    preview: fileURL.lastPathComponent,
                    source: source,
                    sourceAppName: sourceAppName,
                    sourceAppBundleID: sourceAppBundleID,
                    searchableText: "\(path) image photo picture \(sourceAppName)"
                )
            }

            return ParsedClipboardItem(
                contentType: .file,
                textContent: path,
                imagePath: nil,
                preview: fileURL.lastPathComponent,
                source: source,
                sourceAppName: sourceAppName,
                sourceAppBundleID: sourceAppBundleID,
                searchableText: "\(path) \(sourceAppName)"
            )
        }

        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            let contentType: ClipboardContentType
            if let url = URL(string: string), url.scheme != nil, url.host != nil {
                contentType = .url
            } else {
                contentType = .text
            }

            return ParsedClipboardItem(
                contentType: contentType,
                textContent: string,
                imagePath: nil,
                preview: Self.preview(for: string),
                source: source,
                sourceAppName: sourceAppName,
                sourceAppBundleID: sourceAppBundleID,
                searchableText: "\(string) \(sourceAppName)"
            )
        }

        return nil
    }

    private static func sourceAppOrigin(isUniversal: Bool) -> (name: String, bundleID: String?) {
        if isUniversal {
            return ("iPhone", nil)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let name = frontmost?.localizedName ?? "Unknown"
        return (name, frontmost?.bundleIdentifier)
    }

    private static func preview(for text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 120 {
            return singleLine
        }
        return String(singleLine.prefix(117)) + "..."
    }

    private static func storeImage(_ image: NSImage) -> String? {
        let bitmap: NSBitmapImageRep?
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            bitmap = rep
        } else if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            bitmap = NSBitmapImageRep(cgImage: cgImage)
        } else {
            bitmap = nil
        }

        guard let bitmap,
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let directory = AppStorage.imagesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = "\(UUID().uuidString).png"
        let url = directory.appendingPathComponent(filename)

        do {
            try png.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}

struct ParsedClipboardItem: Sendable {
    let contentType: ClipboardContentType
    let textContent: String?
    let imagePath: String?
    let preview: String
    let source: ClipboardSource
    let sourceAppName: String
    let sourceAppBundleID: String?
    let searchableText: String
}

enum AppStorage {
    static var appSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipStack", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var imagesDirectory: URL {
        appSupportDirectory.appendingPathComponent("images", isDirectory: true)
    }
}
