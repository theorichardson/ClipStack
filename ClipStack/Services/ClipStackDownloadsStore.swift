import Foundation

struct ClipStackDownloadItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// When the file landed in Downloads — not content modification time, which browsers often copy from the server.
    let downloadedAt: Date

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
    private var refreshToken = UUID()

    private static let maxFiles = 10_000

    private static let incompleteSuffixes = [".download", ".crdownload", ".part", ".partial"]

    private init() {}

    func refresh() {
        refreshToken = UUID()
        guard loadTask == nil else { return }
        loadTask = Task { await runRefreshLoop() }
    }

    private func runRefreshLoop() async {
        while true {
            let token = refreshToken
            let showLoadingIndicator = items.isEmpty
            if showLoadingIndicator {
                isLoading = true
            }

            let scanned = await Task.detached(priority: .userInitiated) {
                Self.scanDownloadsDirectory()
            }.value

            if showLoadingIndicator {
                isLoading = false
            }

            guard token == refreshToken else { continue }

            items = scanned
            loadTask = nil
            return
        }
    }

    nonisolated private static func scanDownloadsDirectory() -> [ClipStackDownloadItem] {
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .addedToDirectoryDateKey,
            .isRegularFileKey,
        ]
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

            let downloadedAt = Self.downloadedAt(from: values)
            items.append(ClipStackDownloadItem(url: url, downloadedAt: downloadedAt))
        }

        items.sort {
            if $0.downloadedAt != $1.downloadedAt {
                return $0.downloadedAt > $1.downloadedAt
            }
            return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }
        return items
    }

    nonisolated private static func downloadedAt(from values: URLResourceValues?) -> Date {
        values?.addedToDirectoryDate
            ?? values?.creationDate
            ?? values?.contentModificationDate
            ?? .distantPast
    }
}
