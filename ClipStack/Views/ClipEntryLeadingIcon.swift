import AppKit
import SwiftUI

struct ClipEntryLeadingIcon: View {
    let entry: ClipboardEntry
    var size: CGFloat = 28

    var body: some View {
        Group {
            if entry.typedContentType == .image,
               let path = entry.imagePath,
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
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
    }

    private var cornerRadius: CGFloat {
        size <= 18 ? 4 : 6
    }

    private var symbolName: String {
        if entry.typedSource == .universal {
            return "iphone"
        }

        switch entry.typedContentType {
        case .url:
            return "link"
        case .image:
            return "photo"
        case .file:
            return "doc"
        default:
            return "text.alignleft"
        }
    }

    private var symbolColor: Color {
        switch entry.typedContentType {
        case .url:
            return .blue
        default:
            return .secondary
        }
    }
}
