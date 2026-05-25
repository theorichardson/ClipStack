import Foundation
import SwiftData

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    private let maxEntries = 500
    private var modelContext: ModelContext?

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func add(_ item: ParsedClipboardItem) {
        guard let modelContext else { return }

        if let duplicate = findRecentDuplicate(for: item, in: modelContext) {
            duplicate.createdAt = .now
            duplicate.source = item.source.rawValue
            duplicate.sourceAppName = item.sourceAppName
            duplicate.sourceAppBundleID = item.sourceAppBundleID
            try? modelContext.save()
            return
        }

        let entry = ClipboardEntry(
            contentType: item.contentType,
            textContent: item.textContent,
            imagePath: item.imagePath,
            preview: item.preview,
            source: item.source,
            sourceAppName: item.sourceAppName,
            sourceAppBundleID: item.sourceAppBundleID,
            searchableText: item.searchableText
        )

        modelContext.insert(entry)
        trimOldEntries(in: modelContext)
        try? modelContext.save()
    }

    func rename(_ entry: ClipboardEntry, to title: String) {
        guard let modelContext else { return }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.customTitle = trimmed.isEmpty ? nil : trimmed
        try? modelContext.save()
    }

    func delete(_ entry: ClipboardEntry) {
        guard let modelContext else { return }

        if let imagePath = entry.imagePath {
            try? FileManager.default.removeItem(atPath: imagePath)
        }

        modelContext.delete(entry)
        try? modelContext.save()
    }

    func clearAll() {
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<ClipboardEntry>()
        guard let entries = try? modelContext.fetch(descriptor) else { return }

        for entry in entries {
            if let imagePath = entry.imagePath {
                try? FileManager.default.removeItem(atPath: imagePath)
            }
            modelContext.delete(entry)
        }

        try? modelContext.save()
    }

    func copyEntries(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        if entries.count == 1 {
            copyEntry(entries[0])
            return
        }

        let joined = entries
            .map { entry -> String in
                if let text = entry.textContent, !text.isEmpty { return text }
                return entry.preview
            }
            .joined(separator: "\n")

        let aggregate = ParsedClipboardItem(
            contentType: .text,
            textContent: joined,
            imagePath: nil,
            preview: joined,
            source: .local,
            sourceAppName: "ClipStack",
            sourceAppBundleID: Bundle.main.bundleIdentifier,
            searchableText: joined
        )
        PasteboardMonitor.shared.copyToPasteboard(aggregate)
    }

    func copyEntry(_ entry: ClipboardEntry) {
        let item = ParsedClipboardItem(
            contentType: entry.typedContentType,
            textContent: entry.textContent,
            imagePath: entry.imagePath,
            preview: entry.preview,
            source: entry.typedSource,
            sourceAppName: entry.sourceAppName ?? "",
            sourceAppBundleID: entry.sourceAppBundleID,
            searchableText: entry.searchableText
        )
        PasteboardMonitor.shared.copyToPasteboard(item)
    }

    private func findRecentDuplicate(for item: ParsedClipboardItem, in context: ModelContext) -> ClipboardEntry? {
        let cutoff = Date().addingTimeInterval(-30)
        var descriptor = FetchDescriptor<ClipboardEntry>(
            predicate: #Predicate { $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 20

        guard let recent = try? context.fetch(descriptor) else { return nil }

        return recent.first { existing in
            existing.contentType == item.contentType.rawValue
                && existing.textContent == item.textContent
                && existing.imagePath == item.imagePath
        }
    }

    private func trimOldEntries(in context: ModelContext) {
        var descriptor = FetchDescriptor<ClipboardEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = maxEntries + 1

        guard let entries = try? context.fetch(descriptor), entries.count > maxEntries else { return }

        for entry in entries.dropFirst(maxEntries) {
            if let imagePath = entry.imagePath {
                try? FileManager.default.removeItem(atPath: imagePath)
            }
            context.delete(entry)
        }
    }
}
