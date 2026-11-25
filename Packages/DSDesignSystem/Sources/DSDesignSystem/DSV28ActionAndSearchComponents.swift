import SwiftUI

/// 主/次/危险/加载操作按钮（1:1 复刻 v2.8 `DSActionButton`）
public enum DSActionButtonRole: Equatable, Sendable {
    case primary
    case secondary
    case destructive
    case loading
}

public struct DSActionButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let title: String
    public let icon: String?
    public let role: DSActionButtonRole
    private let action: () -> Void

    public init(
        title: String,
        icon: String? = nil,
        role: DSActionButtonRole = .primary,
        action: @escaping () -> Void = {}
    ) {
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }
    private var buttonCornerRadius: CGFloat { isAccessibilitySize ? 18 : DSRadius.pill }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.xs) {
                if role == .loading {
                    ProgressView().tint(DSColors.onAccent)
                } else if let icon {
                    Image(systemName: icon).font(DSTypography.body.weight(.semibold))
                }
                Text(title)
                    .font(DSTypography.rowTitle)
                    .lineLimit(isAccessibilitySize ? 3 : 2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, isAccessibilitySize ? DSSpacing.sm : DSSpacing.xs)
            .frame(
                maxWidth: role == .primary || role == .loading ? .infinity : nil,
                minHeight: role == .primary || role == .loading ? 50 : 44
            )
            .background(RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous).fill(backgroundColor))
            .overlay(RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous).strokeBorder(borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.dsCard)
        .disabled(role == .loading)
    }

    private var foregroundColor: Color {
        switch role {
        case .primary, .loading: return DSColors.onAccent
        case .secondary: return DSColors.inkPrimary
        case .destructive: return DSColors.danger
        }
    }

    private var backgroundColor: Color {
        switch role {
        case .primary, .loading: return DSColors.accent
        case .secondary: return DSColors.surfaceGrouped
        case .destructive: return DSColors.danger.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch role {
        case .primary, .loading: return .clear
        case .secondary: return DSColors.separator.opacity(0.4)
        case .destructive: return DSColors.danger.opacity(0.3)
        }
    }
}

/// 圆形图标按钮（1:1 复刻 v2.8 `DSIconButton`）
public struct DSIconButton: View {
    public let systemName: String
    public let accessibilityTitle: String
    public let isHighlighted: Bool
    public let size: CGFloat
    private let action: () -> Void

    public init(
        systemName: String,
        accessibilityTitle: String,
        isHighlighted: Bool = false,
        size: CGFloat = 44,
        action: @escaping () -> Void = {}
    ) {
        self.systemName = systemName
        self.accessibilityTitle = accessibilityTitle
        self.isHighlighted = isHighlighted
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DSTypography.body.weight(.semibold))
                .foregroundStyle(isHighlighted ? DSColors.accent : DSColors.inkPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(DSColors.surfaceGrouped))
        }
        .buttonStyle(.dsCard)
        .accessibilityLabel(accessibilityTitle)
    }
}

/// 14pt 圆角带清除与取消按钮的搜索输入框（1:1 复刻 v2.8 `DSSearchField`）
public struct DSSearchField: View {
    @Binding public var text: String
    @FocusState.Binding public var isFocused: Bool
    public let prompt: String
    private let onSubmit: () -> Void
    private let onClear: () -> Void
    private let onCancel: () -> Void

    public init(
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

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.xs) {
                Button {
                    if !isFocused { isFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(DSTypography.subtitle)
                        .foregroundStyle(DSColors.inkSecondary)
                        .frame(minWidth: 28, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                TextField(prompt, text: $text)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(onSubmit)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .id("search.textfield.stable")
                    .accessibilityIdentifier("search.field")

                if !text.isEmpty {
                    Button {
                        text = ""
                        onClear()
                        isFocused = true
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
            .padding(.leading, DSSpacing.sm)
            .padding(.trailing, text.isEmpty ? DSSpacing.sm : 0)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous).fill(DSColors.surfaceGrouped))

            if isFocused || !text.isEmpty {
                Button {
                    isFocused = false
                    onCancel()
                } label: {
                    Text("取消")
                        .font(DSTypography.body)
                        .foregroundStyle(DSColors.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.cancel")
            }
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }
}
