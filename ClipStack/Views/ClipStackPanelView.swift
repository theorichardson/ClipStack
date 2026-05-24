import SwiftData
import SwiftUI

struct ClipStackPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardEntry.createdAt, order: .reverse) private var entries: [ClipboardEntry]

    @State private var searchText = ""
    @State private var selectedEntryID: UUID?
    @State private var renamingEntryID: UUID?
    @State private var renameText = ""
    @State private var lastRowClickID: UUID?
    @State private var lastRowClickTime = Date.distantPast
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isRenameFocused: Bool

    let onClose: () -> Void

    private var isRenaming: Bool {
        renamingEntryID != nil
    }

    private var renamingEntry: ClipboardEntry? {
        guard let renamingEntryID else { return nil }
        return entries.first { $0.id == renamingEntryID }
    }

    private var filteredEntries: [ClipboardEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }

        return entries.filter { entry in
            entry.searchableText.localizedCaseInsensitiveContains(query)
                || entry.preview.localizedCaseInsensitiveContains(query)
                || (entry.customTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
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
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 520)
        .onKeyPress(.upArrow) {
            guard !isRenaming else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !isRenaming else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard !isRenaming else { return .ignored }
            copySelectedEntry()
            return .handled
        }
        .onKeyPress(.escape) {
            if isRenaming {
                cancelRename()
                return .handled
            }
            return .ignored
        }
        .background {
            Button("", action: copySelectedEntry)
                .keyboardShortcut("c", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipStackPanelDidShow)) { _ in
            cancelRename()
            isSearchFocused = true
            selectedEntryID = filteredEntries.first?.id
        }
        .onChange(of: filteredEntries.map(\.id)) { _, ids in
            if let renamingEntryID, !ids.contains(renamingEntryID) {
                cancelRename()
            }
            if let selectedEntryID, ids.contains(selectedEntryID) {
                return
            }
            selectedEntryID = ids.first
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search clipboard history…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    guard !isRenaming else { return }
                    copySelectedEntry()
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            ContentUnavailableView {
                Label("No Clips", systemImage: "doc.on.clipboard")
            } description: {
                Text(searchText.isEmpty
                    ? "Copy something on your Mac or iPhone — it will show up here."
                    : "No matches for \"\(searchText)\".")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(selection: $selectedEntryID) {
                    ForEach(filteredEntries) { entry in
                        ClipboardItemRow(entry: entry)
                            .tag(entry.id)
                            .id(entry.id)
                            .contextMenu {
                                Button("Copy") {
                                    copy(entry)
                                }
                                Button("Rename") {
                                    beginRename(entry)
                                }
                                Button("Delete", role: .destructive) {
                                    ClipboardStore.shared.delete(entry)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                handleRowClick(on: entry)
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedEntryID) { _, newValue in
                    if let renamingEntryID, newValue != renamingEntryID {
                        cancelRename()
                    }
                    guard let newValue else { return }
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(filteredEntries.count) clip\(filteredEntries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Clear All") {
                ClipboardStore.shared.clearAll()
            }
            .disabled(entries.isEmpty)

            Button("Copy") {
                copySelectedEntry()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selectedEntryID == nil || isRenaming)

            Button("Close") {
                onClose()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        selectedEntryID = entry.id
    }

    private func beginRename(_ entry: ClipboardEntry) {
        if let renamingEntryID, renamingEntryID != entry.id {
            cancelRename()
        }
        renamingEntryID = entry.id
        selectedEntryID = entry.id
        renameText = entry.customTitle ?? ""
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

    private func copySelectedEntry() {
        guard let selectedEntryID,
              let entry = filteredEntries.first(where: { $0.id == selectedEntryID }) else {
            return
        }
        copy(entry)
    }

    private func copy(_ entry: ClipboardEntry) {
        ClipboardStore.shared.copyEntry(entry)
    }

    private func moveSelection(by offset: Int) {
        let ids = filteredEntries.map(\.id)
        guard !ids.isEmpty else { return }

        if let selectedEntryID, let index = ids.firstIndex(of: selectedEntryID) {
            let nextIndex = min(max(index + offset, 0), ids.count - 1)
            self.selectedEntryID = ids[nextIndex]
        } else {
            selectedEntryID = offset > 0 ? ids.first : ids.last
        }
    }
}

struct ClipboardItemRow: View {
    let entry: ClipboardEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClipEntryLeadingIcon(entry: entry, size: 28)

            ClipEntryRowLabels(entry: entry)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
