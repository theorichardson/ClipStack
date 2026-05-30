import AppKit
import SwiftData
import SwiftUI

/// Keyboard-driven clip picker opened via global shortcut.
struct ClipboardKeyboardView: View {
    @Query(sort: \ClipboardEntry.createdAt, order: .reverse) private var entries: [ClipboardEntry]

    @State private var searchText = ""
    @State private var sourceFilterKey: String?
    @ObservedObject private var downloadsIndexer = ClipStackDownloadsIndexer.shared
    @State private var selectedRowKeys: Set<String> = []
    @State private var activeRowKey: String?
    @State private var anchorRowKey: String?
    @State private var scrollTrigger: String?
    @State private var renamingEntryID: UUID?
    @State private var renameText = ""
    @State private var lastKeyboardSelectionTime: Date?
    @FocusState private var focusTarget: FocusTarget?
    @FocusState private var isRenameFocused: Bool

    var onDismiss: () -> Void = {}

    private enum FocusTarget {
        case search
        case panel
    }

    private var isRenaming: Bool {
        renamingEntryID != nil
    }

    private var renamingEntry: ClipboardEntry? {
        guard let renamingEntryID else { return nil }
        return entries.first { $0.id == renamingEntryID }
    }

    private let menuLimit = 30
    private static let selectionRestoreInterval: TimeInterval = 30

    private var isDownloadsMode: Bool {
        sourceFilterKey == ClipStackDownloadsStore.filterKey
    }

    private var filteredEntries: [ClipboardEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches = entries

        if let sourceFilterKey {
            matches = matches.filter { ClipSourceFilter.key(for: $0) == sourceFilterKey }
        }

        if !query.isEmpty {
            matches = matches.filter { entry in
                entry.searchableText.localizedCaseInsensitiveContains(query)
                    || entry.preview.localizedCaseInsensitiveContains(query)
                    || (entry.customTitle?.localizedCaseInsensitiveContains(query) ?? false)
                    || entry.displaySourceApp.localizedCaseInsensitiveContains(query)
            }
        }

        return Array(matches.prefix(menuLimit))
    }

    private var filteredDownloads: [ClipStackDownloadItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = downloadsIndexer.items

        guard !query.isEmpty else { return catalog }

        return catalog.filter { item in
            item.filename.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleRowKeys: [String] {
        if isDownloadsMode {
            return filteredDownloads.map(\.id)
        }
        return filteredEntries.map { rowKey(for: $0) }
    }

    private var activeEntry: ClipboardEntry? {
        guard let activeRowKey, !isDownloadsMode else { return nil }
        return filteredEntries.first { rowKey(for: $0) == activeRowKey }
    }

    private var activeDownload: ClipStackDownloadItem? {
        guard let activeRowKey, isDownloadsMode else { return nil }
        return filteredDownloads.first { $0.id == activeRowKey }
    }

    private var availableSourceFilters: [ClipSourceFilter] {
        var seen: Set<String> = []
        var result: [ClipSourceFilter] = []
        for entry in entries {
            let filter = ClipSourceFilter(entry: entry)
            if seen.insert(filter.key).inserted {
                result.append(filter)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            sourceFilterBar

            if isDownloadsMode, downloadsIndexer.isLoading, downloadsIndexer.items.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading downloads…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRowKeys.isEmpty {
                ContentUnavailableView {
                    Label(emptyStateTitle, systemImage: emptyStateSymbol)
                } description: {
                    Text(emptyStateMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    clipListColumn
                    ClipKeyboardDetailPanel(
                        entry: activeEntry,
                        download: activeDownload,
                        selectedCount: selectedRowKeys.count
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isRenaming, let entry = renamingEntry {
                Divider()
                ClipRenameBar(
                    preview: entry.preview,
                    renameText: $renameText,
                    isFocused: $isRenameFocused,
                    onSave: saveRename,
                    onCancel: cancelRename
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focusTarget, equals: .panel)
        .keyboardNavigationHandlers(
            onUp: { moveSelection(by: -1, modifiers: $0) },
            onDown: { moveSelection(by: 1, modifiers: $0) },
            onLeft: { _ in moveFilter(by: -1) },
            onRight: { _ in moveFilter(by: 1) },
            onEscape: {
                if isRenaming {
                    cancelRename()
                    return
                }
                onDismiss()
            },
            onReturn: {
                if isRenaming {
                    saveRename()
                    return
                }
                copySelectedEntries()
            }
        )
        .ignoresSafeArea(.container)
        .onAppear { prepareForDisplay() }
        .onReceive(NotificationCenter.default.publisher(for: .clipStackPanelDidShow)) { _ in
            prepareForDisplay()
        }
        .onChange(of: activeRowKey) { _, newValue in
            if let renamingEntryID,
               let entry = renamingEntry,
               newValue != rowKey(for: entry) {
                cancelRename()
            }
        }
        .onChange(of: sourceFilterKey) { _, newValue in
            if newValue == ClipStackDownloadsStore.filterKey {
                downloadsIndexer.refresh()
            }
            syncSelectionToVisibleRows()
        }
        .onChange(of: downloadsIndexer.isLoading) { wasLoading, isLoading in
            guard isDownloadsMode, wasLoading, !isLoading else { return }
            syncSelectionToVisibleRows()
        }
        .onChange(of: visibleRowKeys) { _, _ in
            syncSelectionToVisibleRows()
        }
        .background {
            Button("", action: copySelectedEntries)
                .keyboardShortcut("c", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    private var clipListColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isDownloadsMode {
                        ForEach(filteredDownloads) { item in
                            InsetSelectableRow(
                                isSelected: selectedRowKeys.contains(item.id),
                                isActive: activeRowKey == item.id,
                                onSingleClick: { copyDownloadFromRowClick(item) }
                            ) {
                                DownloadsKeyboardRow(item: item)
                            }
                            .id(item.id)
                        }
                    } else {
                        ForEach(filteredEntries) { entry in
                            InsetSelectableRow(
                                isSelected: selectedRowKeys.contains(rowKey(for: entry)),
                                isActive: activeRowKey == rowKey(for: entry),
                                onSingleClick: { copyEntryFromRowClick(entry) },
                                onDoubleClick: { beginRename(entry) }
                            ) {
                                ClipboardKeyboardRow(entry: entry)
                            }
                            .id(rowKey(for: entry))
                        }
                    }
                }
                .padding(.horizontal, RowLayout.inset)
                .padding(.vertical, RowLayout.inset)
            }
            .frame(width: PanelLayout.listWidth)
            .frame(maxHeight: .infinity)
            .onChange(of: scrollTrigger) { _, newValue in
                guard let newValue else { return }
                proxy.scrollTo(newValue, anchor: .center)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipStackPanelDidShow)) { _ in
                guard let activeRowKey else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(activeRowKey, anchor: .center)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: RowLayout.searchIconTextSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: RowLayout.iconSize, height: RowLayout.iconSize)

            TextField("Search…", text: $searchText)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .hideTextFieldFocusRing()
                .focused($focusTarget, equals: .search)
                .keyboardNavigationHandlers(
                    onUp: { moveSelection(by: -1, modifiers: $0) },
                    onDown: { moveSelection(by: 1, modifiers: $0) },
                    onLeft: { _ in moveFilter(by: -1) },
                    onRight: { _ in moveFilter(by: 1) },
                    onEscape: {
                        if isRenaming {
                            cancelRename()
                            return
                        }
                        onDismiss()
                    },
                    onReturn: {
                        if isRenaming {
                            saveRename()
                            return
                        }
                        copySelectedEntries()
                    }
                )
                .onSubmit {
                    if isRenaming {
                        saveRename()
                        return
                    }
                    copySelectedEntries()
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, RowLayout.rowContentLeadingInset - 1)
        .padding(.trailing, RowLayout.rowContentLeadingInset + 3)
        .padding(.top, RowLayout.searchTopInset)
        .padding(.bottom, RowLayout.inset)
    }

    private var emptyStateTitle: String {
        isDownloadsMode ? "No downloads" : "No clips"
    }

    private var emptyStateSymbol: String {
        isDownloadsMode ? "arrow.down.circle" : "doc.on.clipboard"
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "No matches for \"\(searchText)\"."
        }
        if isDownloadsMode {
            return "Files in your Downloads folder appear here. Search by name."
        }
        return "Copy something on your Mac or iPhone."
    }

    @ViewBuilder
    private var sourceFilterBar: some View {
        let filters = availableSourceFilters
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    SourcePill(
                        title: "Clipboard",
                        bundleID: nil,
                        showsIcon: false,
                        isSelected: sourceFilterKey == nil
                    ) {
                        sourceFilterKey = nil
                    }
                    .id(filterScrollID(for: nil))

                    SourcePill(
                        title: "Downloads",
                        bundleID: nil,
                        showsIcon: false,
                        isSelected: sourceFilterKey == ClipStackDownloadsStore.filterKey
                    ) {
                        sourceFilterKey = ClipStackDownloadsStore.filterKey
                    }
                    .id(filterScrollID(for: ClipStackDownloadsStore.filterKey))

                    ForEach(filters) { filter in
                        SourcePill(
                            title: filter.displayName,
                            symbolName: filter.fallbackSymbolName,
                            bundleID: filter.bundleID,
                            isSelected: sourceFilterKey == filter.key
                        ) {
                            sourceFilterKey = (sourceFilterKey == filter.key) ? nil : filter.key
                        }
                        .id(filterScrollID(for: filter.key))
                    }
                }
                .padding(.horizontal, RowLayout.rowContentLeadingInset - 1)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
            .onChange(of: sourceFilterKey) { _, newValue in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(filterScrollID(for: newValue), anchor: .center)
                }
            }
        }
    }

    private func rowKey(for entry: ClipboardEntry) -> String {
        "clip:\(entry.id.uuidString)"
    }

    private func syncSelectionToVisibleRows() {
        let ids = visibleRowKeys
        let visible = Set(ids)

        if let renamingEntryID,
           let entry = entries.first(where: { $0.id == renamingEntryID }),
           !visible.contains(rowKey(for: entry)) {
            cancelRename()
        }

        selectedRowKeys.formIntersection(visible)
        if let activeRowKey, !visible.contains(activeRowKey) {
            self.activeRowKey = ids.first
            anchorRowKey = ids.first
            if let first = ids.first { selectedRowKeys = [first] }
        } else if activeRowKey == nil {
            activeRowKey = ids.first
            anchorRowKey = ids.first
            if let first = ids.first { selectedRowKeys = [first] }
        }
    }

    private func prepareForDisplay() {
        cancelRename()
        searchText = ""
        downloadsIndexer.refresh()
        if sourceFilterKey != ClipStackDownloadsStore.filterKey {
            sourceFilterKey = nil
        }

        let visibleIDs = visibleRowKeys
        let visibleSet = Set(visibleIDs)
        let shouldRestoreSelection = lastKeyboardSelectionTime.map {
            Date().timeIntervalSince($0) < Self.selectionRestoreInterval
        } ?? false

        if shouldRestoreSelection, let activeRowKey, visibleSet.contains(activeRowKey) {
            selectedRowKeys.formIntersection(visibleSet)
            if selectedRowKeys.isEmpty { selectedRowKeys = [activeRowKey] }
            if anchorRowKey == nil || !(anchorRowKey.map(visibleSet.contains) ?? false) {
                anchorRowKey = activeRowKey
            }
        } else {
            lastKeyboardSelectionTime = nil
            let first = visibleIDs.first
            activeRowKey = first
            anchorRowKey = first
            selectedRowKeys = first.map { [$0] } ?? []
        }
        DispatchQueue.main.async {
            focusTarget = .search
        }
    }

    private func copyEntryFromRowClick(_ entry: ClipboardEntry) {
        ClipboardStore.shared.copyEntry(entry)
        onDismiss()
    }

    private func copyDownloadFromRowClick(_ item: ClipStackDownloadItem) {
        PasteboardMonitor.shared.copyFiles(at: [item.url])
        onDismiss()
    }

    private func beginRename(_ entry: ClipboardEntry) {
        if let renamingEntryID, renamingEntryID != entry.id {
            cancelRename()
        }
        renamingEntryID = entry.id
        renameText = entry.customTitle ?? ""
        replaceSelection(with: rowKey(for: entry))
        isRenameFocused = true
    }

    private func saveRename() {
        guard let entry = renamingEntry else {
            renamingEntryID = nil
            renameText = ""
            return
        }

        ClipboardStore.shared.rename(entry, to: renameText)
        renamingEntryID = nil
        renameText = ""
        isRenameFocused = false
    }

    private func cancelRename() {
        renamingEntryID = nil
        renameText = ""
        isRenameFocused = false
    }

    private func copySelectedEntries() {
        if isDownloadsMode {
            copySelectedDownloads()
            return
        }

        let ordered = filteredEntries.filter { selectedRowKeys.contains(rowKey(for: $0)) }
        let entriesToCopy: [ClipboardEntry]
        if ordered.isEmpty,
           let activeRowKey,
           let entry = filteredEntries.first(where: { rowKey(for: $0) == activeRowKey }) {
            entriesToCopy = [entry]
        } else {
            entriesToCopy = ordered
        }
        guard !entriesToCopy.isEmpty else { return }
        ClipboardStore.shared.copyEntries(entriesToCopy)
        onDismiss()
    }

    private func copySelectedDownloads() {
        let ordered = filteredDownloads.filter { selectedRowKeys.contains($0.id) }
        let urls: [URL]
        if ordered.isEmpty,
           let activeRowKey,
           let item = filteredDownloads.first(where: { $0.id == activeRowKey }) {
            urls = [item.url]
        } else {
            urls = ordered.map(\.url)
        }
        guard !urls.isEmpty else { return }
        PasteboardMonitor.shared.copyFiles(at: urls)
        onDismiss()
    }

    private func replaceSelection(with key: String) {
        selectedRowKeys = [key]
        activeRowKey = key
        anchorRowKey = key
    }

    private var filterKeys: [String?] {
        [nil, ClipStackDownloadsStore.filterKey] + availableSourceFilters.map(\.key)
    }

    private func filterScrollID(for key: String?) -> String {
        key.map { "filter:\($0)" } ?? "filter:all"
    }

    private func moveFilter(by offset: Int) {
        guard !isRenaming else { return }
        let keys = filterKeys
        guard keys.count > 1 else { return }

        let currentIndex = sourceFilterKey.flatMap { keys.firstIndex(of: $0) } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), keys.count - 1)
        sourceFilterKey = keys[nextIndex]
    }

    private func moveSelection(by offset: Int, modifiers: EventModifiers) {
        let ids = visibleRowKeys
        guard !ids.isEmpty else { return }

        let currentIndex: Int
        if let activeRowKey, let index = ids.firstIndex(of: activeRowKey) {
            currentIndex = index
        } else {
            currentIndex = offset > 0 ? -1 : ids.count
        }

        let nextIndex = min(max(currentIndex + offset, 0), ids.count - 1)
        let nextID = ids[nextIndex]

        if modifiers.contains(.shift) {
            if anchorRowKey == nil { anchorRowKey = activeRowKey ?? nextID }
            activeRowKey = nextID
            if let anchor = anchorRowKey, let anchorIndex = ids.firstIndex(of: anchor) {
                let lower = min(anchorIndex, nextIndex)
                let upper = max(anchorIndex, nextIndex)
                selectedRowKeys = Set(ids[lower...upper])
            } else {
                selectedRowKeys = [nextID]
            }
        } else {
            activeRowKey = nextID
            anchorRowKey = nextID
            selectedRowKeys = [nextID]
        }

        lastKeyboardSelectionTime = Date()
        scrollTrigger = nextID
    }
}

private struct DownloadsKeyboardRow: View {
    let item: ClipStackDownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: RowLayout.iconTextSpacing) {
            DownloadItemIcon(item: item, size: RowLayout.iconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Downloads · \(item.downloadedAt.clipMenuTimestamp)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct DownloadItemIcon: View {
    let item: ClipStackDownloadItem
    let size: CGFloat

    @State private var thumbnail: NSImage?

    private var isVisualFile: Bool {
        item.isImage || ClipEntryThumbnail.isVisualMediaPath(item.url.path)
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if isVisualFile {
                Image(systemName: "photo")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(nsImage: ClipEntryThumbnail.fileIcon(forExtension: item.fileExtension))
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: item.id) {
            let path = item.url.path
            let loadVisual = isVisualFile

            let loaded = await Task.detached(priority: .userInitiated) {
                if loadVisual {
                    return ClipEntryThumbnail.listThumbnail(forPath: path)
                }
                return nil
            }.value

            if loadVisual {
                thumbnail = loaded
            } else {
                thumbnail = ClipEntryThumbnail.fileIcon(forExtension: item.fileExtension)
            }
        }
    }
}

private struct InsetSelectableRow<Content: View>: View {
    let isSelected: Bool
    let isActive: Bool
    var onSingleClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RowLayout.rowCornerRadius, style: .continuous)
    }

    var body: some View {
        content()
            .padding(RowLayout.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .background {
                ZStack {
                    rowShape.fill(rowBackgroundColor)

                    RowClickHandler(
                        isHovered: $isHovered,
                        onSingleClick: onSingleClick,
                        onDoubleClick: onDoubleClick
                    )
                }
            }
            .overlay {
                if isActive && !isSelected {
                    rowShape.stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            let baseOpacity = isActive ? 0.28 : 0.18
            return Color.accentColor.opacity(isHovered ? baseOpacity + 0.06 : baseOpacity)
        }
        if isHovered {
            return Color.accentColor.opacity(0.08)
        }
        return Color.clear
    }
}

private struct ClipboardKeyboardRow: View {
    let entry: ClipboardEntry

    var body: some View {
        HStack(alignment: .top, spacing: RowLayout.iconTextSpacing) {
            ClipEntryLeadingIcon(entry: entry, size: RowLayout.iconSize)

            ClipEntryRowLabels(entry: entry)

            Spacer(minLength: 0)
        }
    }
}

private enum PanelLayout {
    static let listWidth: CGFloat = 268
}

private enum RowLayout {
    static let inset: CGFloat = 4
    static let searchTopInset: CGFloat = 4
    static let rowCornerRadius: CGFloat = 12
    static let iconSize: CGFloat = 32
    static let iconTextSpacing: CGFloat = 10
    static let searchIconTextSpacing: CGFloat = iconTextSpacing + 1

    /// Leading offset that aligns the search icon with the icons inside list rows.
    /// Rows live inside the LazyVStack (horizontal `inset` padding) and `InsetSelectableRow`
    /// (additional `inset` padding), so their leading icon sits at `inset * 2`.
    static var rowContentLeadingInset: CGFloat {
        inset * 2
    }
}

struct ClipSourceFilter: Identifiable, Hashable {
    let key: String
    let displayName: String
    let bundleID: String?
    let isUniversal: Bool

    var id: String { key }

    var fallbackSymbolName: String {
        isUniversal ? "iphone" : "app"
    }

    init(entry: ClipboardEntry) {
        self.bundleID = entry.sourceAppBundleID
        self.isUniversal = entry.typedSource == .universal
        self.displayName = entry.displaySourceApp
        self.key = Self.key(bundleID: entry.sourceAppBundleID, name: entry.displaySourceApp, isUniversal: isUniversal)
    }

    static func key(for entry: ClipboardEntry) -> String {
        key(
            bundleID: entry.sourceAppBundleID,
            name: entry.displaySourceApp,
            isUniversal: entry.typedSource == .universal
        )
    }

    private static func key(bundleID: String?, name: String, isUniversal: Bool) -> String {
        if let bundleID, !bundleID.isEmpty { return "bid:\(bundleID)" }
        if isUniversal { return "universal" }
        return "name:\(name.lowercased())"
    }
}

private struct SourcePill: View {
    let title: String
    var symbolName: String = "app"
    let bundleID: String?
    var showsIcon: Bool = true
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: showsIcon ? 5 : 0) {
                if showsIcon {
                    iconView
                        .frame(width: 16, height: 16)
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let bundleID, let icon = AppIconResolver.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.12))
        } else if isHovered {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
        } else {
            Color.clear
        }
    }
}
