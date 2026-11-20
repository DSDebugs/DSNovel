import SwiftUI

enum DSBadgeStyle {
    case accent
    case neutral
    case success
    case warning
    case danger
}

struct DSBadge: View {
    let text: String
    let icon: String?
    let style: DSBadgeStyle

    init(_ text: String, icon: String? = nil, style: DSBadgeStyle = .neutral) {
        self.text = text
        self.icon = icon
        self.style = style
    }

    private var foregroundColor: Color {
        switch style {
        case .accent: return Color.dsOnAccent
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .accent: return Color.dsAccent
        case .neutral: return Color.dsSurfaceGrouped
        case .success: return Color.green.opacity(0.15)
        case .warning: return Color.orange.opacity(0.15)
        case .danger: return Color.red.opacity(0.15)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(DSTypography.caption2.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, Spacing.s2)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(backgroundColor))
    }
}

#Preview("Light") {
    HStack {
        DSBadge("VIP", style: .accent)
        DSBadge("120ms", icon: "checkmark.circle.fill", style: .success)
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    HStack {
        DSBadge("需登录", icon: "person.badge.key", style: .warning)
        DSBadge("异常", icon: "exclamationmark.triangle.fill", style: .danger)
    }
    .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSBadge("已下载", style: .neutral)
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
