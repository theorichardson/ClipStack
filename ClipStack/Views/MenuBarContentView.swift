import SwiftData
import SwiftUI

struct MenuBarContentView: View {
    @Query(sort: \ClipboardEntry.createdAt, order: .reverse) private var entries: [ClipboardEntry]

    private let menuLimit = 25

    private var recentEntries: [ClipboardEntry] {
        Array(entries.prefix(menuLimit))
    }

    var body: some View {
        if recentEntries.isEmpty {
            Text("No clips yet")
                .disabled(true)
        } else {
            ForEach(recentEntries) { entry in
                Button {
                    ClipboardStore.shared.copyEntry(entry)
                } label: {
                    Label {
                        Text("\(entry.preview)\t\(entry.sourceSubtitle)")
                            .lineLimit(1)
                    } icon: {
                        ClipEntryLeadingIcon(entry: entry, size: 18)
                    }
                }
            }

            if entries.count > menuLimit {
                Text("\(entries.count - menuLimit) more in history")
                    .disabled(true)
            }
        }

        Divider()

        Button("Clear History", role: .destructive) {
            ClipboardStore.shared.clearAll()
        }
        .disabled(entries.isEmpty)

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Button("Quit ClipStack") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
