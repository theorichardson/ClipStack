import SwiftUI

struct ClipEntryRowLabels: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.preview)
                .lineLimit(entry.listPreviewLineLimit)
                .truncationMode(.tail)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.hasCustomTitle, let customTitle = entry.customTitle {
                Text(customTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(entry.sourceSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
