import SwiftUI

enum DSSettingsRowStyle: Equatable, Sendable {
    case value
    case navigation
    case action
    case destructive
}

struct DSSettingsRow: View {
    @Environment(\.sizeCategory) private var sizeCategory

    let icon: String
    let title: String
    let subtitle: String?
    let valueText: String?
    let style: DSSettingsRowStyle

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        valueText: String? = nil,
        style: DSSettingsRowStyle = .value
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.valueText = valueText
        self.style = style
    }

    private var iconForeground: Color {
        style == .destructive ? .red : Color.dsAccent
    }

    private var iconBackground: Color {
        style == .destructive ? Color.red.opacity(0.12) : Color.dsAccent.opacity(0.10)
    }

    private var titleForeground: Color {
        switch style {
        case .action:
            return Color.dsAccent
        case .destructive:
            return .red
        case .value, .navigation:
            return .primary
        }
    }

    var body: some View {
        Group {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    HStack(spacing: Spacing.s3) {
                        iconBadge
                        Text(title)
                            .font(DSTypography.body)
                            .foregroundStyle(titleForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if style == .navigation {
                            chevronIcon
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DSTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let valueText, !valueText.isEmpty {
                        Text(valueText)
                            .font(DSTypography.numericFootnote)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            } else {
                HStack(spacing: Spacing.s3) {
                    iconBadge

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(DSTypography.body)
                            .foregroundStyle(titleForeground)
                            .lineLimit(2)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: Spacing.s2)

                    if let valueText, !valueText.isEmpty {
                        Text(valueText)
                            .font(DSTypography.numericFootnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }

                    if style == .navigation {
                        chevronIcon
                    }
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits((style == .navigation || style == .action || style == .destructive) ? .isButton : [])
    }

    private var iconBadge: some View {
        Image(systemName: icon)
            .font(DSTypography.subtitle.weight(.semibold))
            .foregroundStyle(iconForeground)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                    .fill(iconBackground)
            )
            .accessibilityHidden(true)
    }

    private var chevronIcon: some View {
        Image(systemName: "chevron.right")
            .font(DSTypography.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

#Preview("Light") {
    DSSettingsRow(icon: "waveform", title: "音频通道", subtitle: "人声增强", valueText: "人声", style: .navigation)
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSSettingsRow(icon: "arrow.down.circle", title: "下载与存储", valueText: "128 MB", style: .navigation)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSSettingsRow(icon: "paintbrush", title: "外观与交互", valueText: "跟随系统", style: .value)
        .padding()
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
