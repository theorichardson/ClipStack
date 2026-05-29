import Foundation

struct ClipStackDownloadItem: Identifiable, Hashable, Sendable {
    let url: URL
    let modifiedAt: Date

    var id: String { url.path }

    var filename: String { url.lastPathComponent }

    var displayTitle: String { filename }

    var fileExtension: String { url.pathExtension.lowercased() }

    var isImage: Bool {
        Self.imageExtensions.contains(fileExtension)
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp", "webp",
    ]
}

enum ClipStackDownloadsStore {
    static let filterKey = "downloads"
}

@MainActor
final class ClipStackDownloadsIndexer: ObservableObject {
    static let shared = ClipStackDownloadsIndexer()

    @Published private(set) var items: [ClipStackDownloadItem] = []
    @Published private(set) var isLoading = false

    private var loadTask: Task<Void, Never>?

    private static let maxFiles = 10_000

    private static let incompleteSuffixes = [".download", ".crdownload", ".part", ".partial"]

    private init() {}

    func refresh() {
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            items = []

            let scanned = await Task.detached(priority: .userInitiated) {
                Self.scanDownloadsDirectory()
            }.value

            guard !Task.isCancelled else { return }

            guard !Task.isCancelled else { return }

            items = scanned
            isLoading = false
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    nonisolated private static func scanDownloadsDirectory() -> [ClipStackDownloadItem] {
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return []
        }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [ClipStackDownloadItem] = []
        items.reserveCapacity(min(urls.count, maxFiles))

        for url in urls {
            guard items.count < maxFiles else { break }

            let filename = url.lastPathComponent
            let lower = filename.lowercased()
            if Self.incompleteSuffixes.contains(where: { lower.hasSuffix($0) }) {
                continue
            }

            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }

            let modifiedAt = values?.contentModificationDate ?? .distantPast
            items.append(ClipStackDownloadItem(url: url, modifiedAt: modifiedAt))
        }

        items.sort { $0.modifiedAt > $1.modifiedAt }
        return items
    }
}
