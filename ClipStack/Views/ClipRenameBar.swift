import SwiftUI

struct ClipRenameBar: View {
    let preview: String
    @Binding var renameText: String
    var isFocused: FocusState<Bool>.Binding
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name this clip…", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused(isFocused)
                    .focusEffectDisabled()
                    .hideTextFieldFocusRing()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit(onSave)
                    .onKeyPress(.return) {
                        onSave()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }

                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Save") {
                onSave()
            }
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
