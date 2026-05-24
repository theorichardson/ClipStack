import AppKit
import SwiftData
import SwiftUI

/// Keyboard-driven clip picker opened via global shortcut.
struct ClipboardKeyboardView: View {
    @Query(sort: \ClipboardEntry.createdAt, order: .reverse) private var entries: [ClipboardEntry]

    @State private var searchText = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var activeID: UUID?
    @State private var anchorID: UUID?
    @State private var scrollTrigger: UUID?
    @State private var renamingEntryID: UUID?
    @State private var renameText = ""
    @State private var lastRowClickID: UUID?
    @State private var lastRowClickTime = Date.distantPast
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

    private var filteredEntries: [ClipboardEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [ClipboardEntry]

        if query.isEmpty {
            matches = entries
        } else {
            matches = entries.filter { entry in
                entry.searchableText.localizedCaseInsensitiveContains(query)
                    || entry.preview.localizedCaseInsensitiveContains(query)
                    || (entry.customTitle?.localizedCaseInsensitiveContains(query) ?? false)
                    || entry.displaySourceApp.localizedCaseInsensitiveContains(query)
            }
        }

        return Array(matches.prefix(menuLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

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
                        LazyVStack(spacing: RowLayout.inset) {
                            ForEach(filteredEntries) { entry in
                                InsetSelectableRow(
                                    isSelected: selectedIDs.contains(entry.id),
                                    isActive: activeID == entry.id
                                ) {
                                    ClipboardKeyboardRow(entry: entry)
                                }
                                .id(entry.id)
                                .contentShape(RoundedRectangle(cornerRadius: RowLayout.rowCornerRadius, style: .continuous))
                                .onTapGesture {
                                    handleRowClick(on: entry)
                                }
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
        .focusable()
        .focusEffectDisabled()
        .focused($focusTarget, equals: .panel)
        .keyboardNavigationHandlers(
            onUp: { moveSelection(by: -1, modifiers: $0) },
            onDown: { moveSelection(by: 1, modifiers: $0) },
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
        HStack(spacing: RowLayout.iconTextSpacing) {
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
        .padding(.leading, RowLayout.rowContentLeadingInset)
        .padding(.trailing, RowLayout.inset)
        .padding(.top, RowLayout.searchTopInset)
        .padding(.bottom, RowLayout.inset)
    }

    private func prepareForDisplay() {
        cancelRename()
        searchText = ""
        let visibleIDs = filteredEntries.map(\.id)
        let visibleSet = Set(visibleIDs)
        if let activeID, visibleSet.contains(activeID) {
            selectedIDs.formIntersection(visibleSet)
            if selectedIDs.isEmpty { selectedIDs = [activeID] }
            if anchorID == nil || !(anchorID.map(visibleSet.contains) ?? false) {
                anchorID = activeID
            }
        } else {
            let first = visibleIDs.first
            activeID = first
            anchorID = first
            selectedIDs = first.map { [$0] } ?? []
        }
        DispatchQueue.main.async {
            focusTarget = .search
        }
    }

    private func handleRowClick(on entry: ClipboardEntry) {
        let now = Date()
        if lastRowClickID == entry.id,
           now.timeIntervalSince(lastRowClickTime) < 0.35 {
            beginRename(entry)
            lastRowClickID = nil
            lastRowClickTime = .distantPast
            return
        }

        lastRowClickID = entry.id
        lastRowClickTime = now
        handleTap(on: entry.id)
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

    private func handleTap(on id: UUID) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            toggleSelection(id)
        } else if mods.contains(.shift) {
            extendSelection(to: id)
        } else {
            replaceSelection(with: id)
        }
    }

    private func replaceSelection(with id: UUID) {
        selectedIDs = [id]
        activeID = id
        anchorID = id
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if activeID == id {
                activeID = selectedIDs.isEmpty ? nil : id
            }
        } else {
            selectedIDs.insert(id)
        }
        activeID = id
        anchorID = id
    }

    private func extendSelection(to id: UUID) {
        let ids = filteredEntries.map(\.id)
        guard let anchor = anchorID ?? activeID,
              let anchorIndex = ids.firstIndex(of: anchor),
              let targetIndex = ids.firstIndex(of: id) else {
            replaceSelection(with: id)
            return
        }
        let range = anchorIndex <= targetIndex
            ? ids[anchorIndex...targetIndex]
            : ids[targetIndex...anchorIndex]
        selectedIDs = Set(range)
        activeID = id
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

        scrollTrigger = nextID
    }
}

private struct InsetSelectableRow<Content: View>: View {
    let isSelected: Bool
    let isActive: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(RowLayout.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: RowLayout.rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(isActive ? 0.28 : 0.18))
                }
            }
            .overlay {
                if isActive && !isSelected {
                    RoundedRectangle(cornerRadius: RowLayout.rowCornerRadius, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                }
            }
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
    static let searchTopInset: CGFloat = 28
    static let rowCornerRadius: CGFloat = 12
    static let iconSize: CGFloat = 32
    static let iconTextSpacing: CGFloat = 10

    /// Leading offset that aligns the search icon with the icons inside list rows.
    /// Rows live inside the LazyVStack (horizontal `inset` padding) and `InsetSelectableRow`
    /// (additional `inset` padding), so their leading icon sits at `inset * 2`.
    static var rowContentLeadingInset: CGFloat {
        inset * 2
    }
}
