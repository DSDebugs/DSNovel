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
                HStack(spacing: Spacing.s2) {
                    Button {
                        if !isFocused {
                            isFocused = true
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(DSTypography.subtitle)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)

                    TextField(prompt, text: $text)
                        .focused($isFocused)
                        .submitLabel(.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(onSubmit)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .id("search.textfield.stable")
                        .accessibilityIdentifier("search.field")
                }
                .frame(maxWidth: .infinity, minHeight: 44)

                if !text.isEmpty {
                    Button {
                        text = ""
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DSTypography.subtitle)
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索词")
                    .accessibilityIdentifier("search.clear")
                }
            }
            .padding(.leading, Spacing.s3)
            .padding(.trailing, text.isEmpty ? Spacing.s3 : 0)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                    .fill(Color.dsSurfaceGrouped)
            )

            if isFocused || !text.isEmpty {
                Button {
                    isFocused = false
                    onCancel()
                } label: {
                    Text("取消")
                        .font(DSTypography.body)
                        .foregroundStyle(Color.dsAccent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.cancel")
            }
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }
}
