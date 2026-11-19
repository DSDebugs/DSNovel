import SwiftUI

enum DSActionButtonRole {
    case primary
    case secondary
    case destructive
    case loading
}

struct DSActionButton: View {
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
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, Spacing.s4)
            .frame(maxWidth: role == .primary || role == .loading ? .infinity : nil)
            .frame(height: role == .primary || role == .loading ? 50 : 44)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
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
        DSActionButton(title: "继续 · 精品有声推荐", icon: "play.fill", role: .primary)
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
