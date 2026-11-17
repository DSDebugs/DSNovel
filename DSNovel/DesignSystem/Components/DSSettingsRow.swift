import SwiftUI

struct DSSettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let valueText: String?

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        valueText: String? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.valueText = valueText
    }

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.dsAccent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DSTypography.body)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let valueText, !valueText.isEmpty {
                Text(valueText)
                    .font(DSTypography.numericFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
    }
}

#Preview("Light") {
    DSSettingsRow(icon: "waveform", title: "音频通道", subtitle: "人声增强", valueText: "人声")
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSSettingsRow(icon: "arrow.down.circle", title: "下载与存储", valueText: "128 MB")
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSSettingsRow(icon: " paintbrush", title: "外观与交互", valueText: "跟随系统")
        .padding()
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
