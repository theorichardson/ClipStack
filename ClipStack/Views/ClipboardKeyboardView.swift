import SwiftData
import SwiftUI

/// Keyboard-driven clip picker opened via global shortcut.
struct ClipboardKeyboardView: View {
    @Query(sort: \ClipboardEntry.createdAt, order: .reverse) private var entries: [ClipboardEntry]

    @State private var searchText = ""
    @State private var selectedEntryID: UUID?
    @FocusState private var focusTarget: FocusTarget?

    var onDismiss: () -> Void = {}

    private enum FocusTarget {
        case search
        case panel
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
                                InsetSelectableRow(isSelected: selectedEntryID == entry.id) {
                                    ClipboardKeyboardRow(entry: entry)
                                }
                                .id(entry.id)
                                .onTapGesture {
                                    selectedEntryID = entry.id
                                }
                            }
                        }
                        .padding(.horizontal, RowLayout.inset)
                        .padding(.top, RowLayout.inset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: selectedEntryID) { _, newValue in
                        guard let newValue else { return }
                        withAnimation {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 280, height: 400)
        .focusable()
        .focused($focusTarget, equals: .panel)
        .keyboardNavigationHandlers(
            onUp: { moveSelection(by: -1) },
            onDown: { moveSelection(by: 1) },
            onEscape: onDismiss,
            onReturn: copySelectedEntry
        )
        .ignoresSafeArea(.container)
        .onAppear { prepareForDisplay() }
        .onReceive(NotificationCenter.default.publisher(for: .clipStackPanelDidShow)) { _ in
            prepareForDisplay()
        }
        .onChange(of: filteredEntries.map(\.id)) { _, ids in
            if let selectedEntryID, ids.contains(selectedEntryID) { return }
            selectedEntryID = ids.first
        }
        .background {
            Button("", action: copySelectedEntry)
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
                    onUp: { moveSelection(by: -1) },
                    onDown: { moveSelection(by: 1) },
                    onEscape: onDismiss,
                    onReturn: copySelectedEntry
                )
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
        .padding(.leading, RowLayout.contentLeadingInset)
        .padding(.trailing, RowLayout.inset)
        .padding(.top, RowLayout.searchTopInset)
        .padding(.bottom, RowLayout.inset)
    }

    private func prepareForDisplay() {
        searchText = ""
        selectedEntryID = filteredEntries.first?.id
        DispatchQueue.main.async {
            focusTarget = .search
        }
    }

    private func copySelectedEntry() {
        guard let selectedEntryID,
              let entry = filteredEntries.first(where: { $0.id == selectedEntryID }) else {
            return
        }
        ClipboardStore.shared.copyEntry(entry)
        onDismiss()
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

private struct InsetSelectableRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(RowLayout.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: RowLayout.rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.2))
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
    static let rowCornerRadius: CGFloat = 8
    static let iconSize: CGFloat = 32
    static let iconTextSpacing: CGFloat = 10

    static var contentLeadingInset: CGFloat {
        inset + inset + inset
    }
}
