import SwiftUI

struct DSSearchField: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let prompt: String
    private let onSubmit: () -> Void
    private let onClear: () -> Void
    private let onCancel: () -> Void

    init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        prompt: String = "搜索书名、作者或演播",
        onSubmit: @escaping () -> Void = {},
        onClear: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) {
        self._text = text
        self._isFocused = isFocused
        self.prompt = prompt
        self.onSubmit = onSubmit
        self.onClear = onClear
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: Spacing.s2) {
            HStack(spacing: Spacing.s2) {
                Image(systemName: "magnifyingglass")
                    .font(DSTypography.subtitle)
                    .foregroundStyle(.secondary)

                TextField(prompt, text: $text)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(onSubmit)
                    .id("search.textfield.stable")
                    .accessibilityIdentifier("search.field")

                if !text.isEmpty {
                    Button {
                        text = ""
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DSTypography.subtitle)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索词")
                    .accessibilityIdentifier("search.clear")
                }
            }
            .padding(.horizontal, Spacing.s3)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                    .fill(Color.dsSurfaceGrouped)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if !isFocused {
                    isFocused = true
                }
            }

            if isFocused || !text.isEmpty {
                Button("取消") {
                    isFocused = false
                    onCancel()
                }
                .font(DSTypography.body)
                .foregroundStyle(Color.dsAccent)
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.cancel")
            }
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }
}
