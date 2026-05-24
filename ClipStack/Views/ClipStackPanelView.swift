import SwiftData
import SwiftUI

struct ClipStackPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardEntry.createdAt, order: .reverse) private var entries: [ClipboardEntry]

    @State private var searchText = ""
    @State private var selectedEntryID: UUID?
    @FocusState private var isSearchFocused: Bool

    let onClose: () -> Void

    private var filteredEntries: [ClipboardEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }

        return entries.filter { entry in
            entry.searchableText.localizedCaseInsensitiveContains(query)
                || entry.preview.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 520)
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            copySelectedEntry()
            return .handled
        }
        .background {
            Button("", action: copySelectedEntry)
                .keyboardShortcut("c", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipStackPanelDidShow)) { _ in
            isSearchFocused = true
            selectedEntryID = filteredEntries.first?.id
        }
        .onChange(of: filteredEntries.map(\.id)) { _, ids in
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
                                Button("Delete", role: .destructive) {
                                    ClipboardStore.shared.delete(entry)
                                }
                            }
                            .onTapGesture(count: 2) {
                                copy(entry)
                                onClose()
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedEntryID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
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
            .disabled(selectedEntryID == nil)

            Button("Close") {
                onClose()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
