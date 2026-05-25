import AppKit
import SwiftData
import SwiftUI

/// Keyboard-driven clip picker opened via global shortcut.
struct ClipboardKeyboardView: View {
    @Query(sort: \ClipboardEntry.createdAt, order: .reverse) private var entries: [ClipboardEntry]

    @State private var searchText = ""
    @State private var sourceFilterKey: String?
    @State private var selectedIDs: Set<UUID> = []
    @State private var activeID: UUID?
    @State private var anchorID: UUID?
    @State private var scrollTrigger: UUID?
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

            if filteredEntries.isEmpty {
                ContentUnavailableView {
                    Label("No clips", systemImage: "doc.on.clipboard")
                } description: {
                    Text(searchText.isEmpty
                        ? "Copy something on your Mac or iPhone."
                        : "No matches for \"\(searchText)\".")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredEntries) { entry in
                                InsetSelectableRow(
                                    isSelected: selectedIDs.contains(entry.id),
                                    isActive: activeID == entry.id,
                                    onSingleClick: { copyEntryFromRowClick(entry) },
                                    onDoubleClick: { beginRename(entry) }
                                ) {
                                    ClipboardKeyboardRow(entry: entry)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, RowLayout.inset)
                        .padding(.vertical, RowLayout.inset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: scrollTrigger) { _, newValue in
                        guard let newValue else { return }
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .clipStackPanelDidShow)) { _ in
                        guard let activeID else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                }
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
        .onChange(of: activeID) { _, newValue in
            if let renamingEntryID, newValue != renamingEntryID {
                cancelRename()
            }
        }
        .onChange(of: filteredEntries.map(\.id)) { _, ids in
            let visible = Set(ids)
            if let renamingEntryID, !visible.contains(renamingEntryID) {
                cancelRename()
            }
            selectedIDs.formIntersection(visible)
            if let activeID, !visible.contains(activeID) {
                self.activeID = ids.first
                anchorID = ids.first
                if let first = ids.first { selectedIDs = [first] }
            } else if activeID == nil {
                activeID = ids.first
                anchorID = ids.first
                if let first = ids.first { selectedIDs = [first] }
            }
        }
        .background {
            Button("", action: copySelectedEntries)
                .keyboardShortcut("c", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
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

    @ViewBuilder
    private var sourceFilterBar: some View {
        let filters = availableSourceFilters
        if filters.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        SourcePill(
                            title: "All",
                            symbolName: "tray.full",
                            bundleID: nil,
                            isSelected: sourceFilterKey == nil
                        ) {
                            sourceFilterKey = nil
                        }
                        .id(filterScrollID(for: nil))

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
    }

    private func prepareForDisplay() {
        cancelRename()
        searchText = ""
        sourceFilterKey = nil
        let visibleIDs = filteredEntries.map(\.id)
        let visibleSet = Set(visibleIDs)
        let shouldRestoreSelection = lastKeyboardSelectionTime.map {
            Date().timeIntervalSince($0) < Self.selectionRestoreInterval
        } ?? false

        if shouldRestoreSelection, let activeID, visibleSet.contains(activeID) {
            selectedIDs.formIntersection(visibleSet)
            if selectedIDs.isEmpty { selectedIDs = [activeID] }
            if anchorID == nil || !(anchorID.map(visibleSet.contains) ?? false) {
                anchorID = activeID
            }
        } else {
            lastKeyboardSelectionTime = nil
            let first = visibleIDs.first
            activeID = first
            anchorID = first
            selectedIDs = first.map { [$0] } ?? []
        }
        DispatchQueue.main.async {
            focusTarget = .search
        }
    }

    private func copyEntryFromRowClick(_ entry: ClipboardEntry) {
        ClipboardStore.shared.copyEntry(entry)
        onDismiss()
    }

    private func beginRename(_ entry: ClipboardEntry) {
        if let renamingEntryID, renamingEntryID != entry.id {
            cancelRename()
        }
        renamingEntryID = entry.id
        renameText = entry.customTitle ?? ""
        replaceSelection(with: entry.id)
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
        let ordered = filteredEntries.filter { selectedIDs.contains($0.id) }
        let entriesToCopy: [ClipboardEntry]
        if ordered.isEmpty, let activeID, let entry = filteredEntries.first(where: { $0.id == activeID }) {
            entriesToCopy = [entry]
        } else {
            entriesToCopy = ordered
        }
        guard !entriesToCopy.isEmpty else { return }
        ClipboardStore.shared.copyEntries(entriesToCopy)
        onDismiss()
    }

    private func replaceSelection(with id: UUID) {
        selectedIDs = [id]
        activeID = id
        anchorID = id
    }

    private var filterKeys: [String?] {
        [nil] + availableSourceFilters.map(\.key)
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
        let ids = filteredEntries.map(\.id)
        guard !ids.isEmpty else { return }

        let currentIndex: Int
        if let activeID, let index = ids.firstIndex(of: activeID) {
            currentIndex = index
        } else {
            currentIndex = offset > 0 ? -1 : ids.count
        }

        let nextIndex = min(max(currentIndex + offset, 0), ids.count - 1)
        let nextID = ids[nextIndex]

        if modifiers.contains(.shift) {
            if anchorID == nil { anchorID = activeID ?? nextID }
            activeID = nextID
            if let anchor = anchorID, let anchorIndex = ids.firstIndex(of: anchor) {
                let lower = min(anchorIndex, nextIndex)
                let upper = max(anchorIndex, nextIndex)
                selectedIDs = Set(ids[lower...upper])
            } else {
                selectedIDs = [nextID]
            }
        } else {
            activeID = nextID
            anchorID = nextID
            selectedIDs = [nextID]
        }

        lastKeyboardSelectionTime = Date()
        scrollTrigger = nextID
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
    let symbolName: String
    let bundleID: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                iconView
                    .frame(width: 16, height: 16)
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
