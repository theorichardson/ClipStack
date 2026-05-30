import AppKit
import SwiftUI

struct ClipKeyboardDetailPanel: View {
    let entry: ClipboardEntry?
    let download: ClipStackDownloadItem?
    let selectedCount: Int

    var body: some View {
        Group {
            if entry != nil || download != nil {
                VStack(alignment: .leading, spacing: DetailLayout.sectionSpacing) {
                    if selectedCount > 1 {
                        Text("\(selectedCount) items selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let entry {
                        ClipEntryDetailContent(entry: entry)
                    } else if let download {
                        DownloadItemDetailVisual(item: download)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DetailLayout.padding)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select an item")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum DetailLayout {
    static let padding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let visualCornerRadius: CGFloat = 12
    static let textMaxHeightWhenVisual: CGFloat = 160
}

// MARK: - Maximized visual

private struct DetailMaximizedVisual<Placeholder: View>: View {
    let image: NSImage?
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    placeholder()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: DetailLayout.visualCornerRadius, style: .continuous))
        }
    }
}

// MARK: - Clipboard entry

private struct ClipEntryDetailContent: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DetailLayout.sectionSpacing) {
            if showsVisual {
                ClipEntryDetailVisual(entry: entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }

            if let text = clippedText {
                ScrollView {
                    Text(text)
                        .font(clippedTextFont)
                        .foregroundStyle(clippedTextForeground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: showsVisual ? DetailLayout.textMaxHeightWhenVisual : .infinity
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var showsVisual: Bool {
        switch entry.typedContentType {
        case .image:
            return true
        case .file:
            if let imagePath = entry.imagePath {
                return ClipEntryThumbnail.isVisualMediaPath(imagePath)
            }
            if let filePath = entry.textContent {
                return ClipEntryThumbnail.isVisualMediaPath(filePath)
            }
            return false
        default:
            return entry.imagePath != nil
        }
    }

    private var clippedText: String? {
        switch entry.typedContentType {
        case .image:
            return nil
        case .file:
            guard !showsVisual else { return nil }
            guard let path = entry.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return path
        case .text, .url, .rtf, .unknown:
            let text = entry.textContent?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? entry.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private var clippedTextFont: Font {
        entry.typedContentType == .file ? .system(.body, design: .monospaced) : .body
    }

    private var clippedTextForeground: Color {
        entry.typedContentType == .file ? .secondary : .primary
    }
}

private struct ClipEntryDetailVisual: View {
    let entry: ClipboardEntry

    @State private var thumbnail: NSImage?

    var body: some View {
        DetailMaximizedVisual(image: thumbnail) {
            if entry.typedContentType == .image {
                Image(systemName: entry.menuSymbolName)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: taskID) {
            let imagePath = entry.imagePath
            let textContent = entry.textContent
            let contentType = entry.contentType
            let loaded = await Task.detached(priority: .userInitiated) {
                ClipEntryThumbnail.detailImage(
                    imagePath: imagePath,
                    textContent: textContent,
                    contentType: contentType
                )
            }.value
            thumbnail = loaded
        }
    }

    private var taskID: String {
        "\(entry.id.uuidString)|\(entry.imagePath ?? "")|\(entry.textContent ?? "")|\(entry.contentType)"
    }
}

// MARK: - Downloads

private struct DownloadItemDetailVisual: View {
    let item: ClipStackDownloadItem

    @State private var thumbnail: NSImage?

    private var isVideo: Bool {
        ClipEntryThumbnail.isVideoPath(item.url.path)
    }

    private var isImageFile: Bool {
        item.isImage || ClipEntryThumbnail.isImagePath(item.url.path)
    }

    var body: some View {
        Group {
            if isVideo {
                GeometryReader { geo in
                    DownloadDetailVideoPlayer(url: item.url)
                        .id(item.id)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                DetailMaximizedVisual(image: thumbnail) {
                    if isImageFile {
                        Image(systemName: "photo")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(nsImage: fileIcon)
                            .resizable()
                            .scaledToFit()
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DetailLayout.visualCornerRadius, style: .continuous))
        .task(id: item.id) {
            guard isImageFile else { return }

            let path = item.url.path
            let loaded = await Task.detached(priority: .utility) {
                ClipEntryThumbnail.detailThumbnail(forPath: path)
            }.value

            thumbnail = loaded
        }
    }

    private var fileIcon: NSImage {
        ClipEntryThumbnail.fileIcon(forExtension: item.fileExtension)
    }
}
