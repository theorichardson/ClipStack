import SwiftUI

struct ClipEntryRowLabels: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.preview)
                .lineLimit(entry.listPreviewLineLimit)
                .truncationMode(.tail)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            ClipEntryMetadataRow(entry: entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClipEntryMetadataRow: View {
    let entry: ClipboardEntry

    var body: some View {
        HStack(spacing: 0) {
            if entry.hasCustomTitle, let customTitle = entry.customTitle {
                Text(customTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(" · ")
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(entry.sourceSubtitle)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
