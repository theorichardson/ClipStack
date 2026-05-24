import SwiftUI

struct ClipEntryRowLabels: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.preview)
                .lineLimit(2)
                .font(.body)

            Text(entry.sourceSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
