import SwiftUI

enum DSActionButtonRole {
    case primary
    case secondary
    case destructive
    case loading
}

struct DSActionButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let icon: String?
    let role: DSActionButtonRole
    private let action: () -> Void

    init(
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

    private var isAccessibilitySize: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var buttonCornerRadius: CGFloat {
        isAccessibilitySize ? 18 : 999
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s2) {
                if role == .loading {
                    ProgressView()
                        .tint(Color.dsOnAccent)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.body.weight(.semibold))
                }
                Text(title)
                    .font(DSTypography.rowTitle)
                    .lineLimit(isAccessibilitySize ? 3 : 2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, Spacing.s4)
            .padding(.vertical, isAccessibilitySize ? Spacing.s3 : Spacing.s2)
            .frame(
                maxWidth: role == .primary || role == .loading ? .infinity : nil,
                minHeight: role == .primary || role == .loading ? 50 : 44
            )
            .background(
                RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.dsCard)
        .disabled(role == .loading)
    }

    private var foregroundColor: Color {
        switch role {
        case .primary, .loading: return Color.dsOnAccent
        case .secondary: return .primary
        case .destructive: return .red
        }
    }

    private var backgroundColor: Color {
        switch role {
        case .primary, .loading: return Color.dsAccent
        case .secondary: return Color.dsSurfaceGrouped
        case .destructive: return Color.red.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch role {
        case .primary, .loading: return .clear
        case .secondary: return Color.dsSeparator.opacity(0.4)
        case .destructive: return Color.red.opacity(0.3)
        }
    }
}

#Preview("Light") {
    VStack(spacing: 12) {
        DSActionButton(title: "继续 · 第九特区 第 99 章 暗斗变明斗 2", icon: "play.fill", role: .primary)
        DSActionButton(title: "下载章节", icon: "arrow.down.circle", role: .secondary)
    }
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    VStack(spacing: 12) {
        DSActionButton(title: "正在获取章节…", role: .loading)
        DSActionButton(title: "删除书源", icon: "trash", role: .destructive)
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("AX") {
    VStack(spacing: 12) {
        DSActionButton(title: "继续 · 第九特区 第 99 章 暗斗变明斗 2", icon: "play.fill", role: .primary)
        DSActionButton(title: "下载章节", icon: "arrow.down.circle", role: .secondary)
    }
    .padding()
    .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
