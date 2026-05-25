import AppKit
import SwiftUI

struct ClipEntryLeadingIcon: View {
    let entry: ClipboardEntry
    var size: CGFloat = 28
    var showsImageThumbnail: Bool = true
    var showsSourceAppBadge: Bool = true

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if showsImageThumbnail, let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbolName)
                    .font(size <= 18 ? .caption : .body)
                    .foregroundStyle(symbolColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .bottomTrailing) {
            sourceAppBadge
        }
        .task(id: thumbnailTaskID) {
            guard showsImageThumbnail else {
                thumbnail = nil
                return
            }

            let imagePath = entry.imagePath
            let textContent = entry.textContent
            let contentType = entry.contentType
            let loaded = await Task.detached(priority: .userInitiated) {
                ClipEntryThumbnail.image(
                    imagePath: imagePath,
                    textContent: textContent,
                    contentType: contentType
                )
            }.value
            thumbnail = loaded
        }
    }

    private var thumbnailTaskID: String {
        "\(entry.id.uuidString)|\(entry.imagePath ?? "")|\(entry.textContent ?? "")|\(entry.contentType)"
    }

    private var cornerRadius: CGFloat {
        8
    }

    private var symbolName: String {
        entry.menuSymbolName
    }

    private var symbolColor: Color {
        switch entry.typedContentType {
        case .url:
            return .blue
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private var sourceAppBadge: some View {
        if showsSourceAppBadge, let icon = AppIconResolver.icon(forBundleID: entry.sourceAppBundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: badgeSize, height: badgeSize)
                .offset(x: badgeSize * 0.25 - 4, y: badgeSize * 0.25 - 4)
                .allowsHitTesting(false)
        }
    }

    private var badgeSize: CGFloat {
        max(12, size * 0.5)
    }
}
