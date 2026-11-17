import SwiftUI

struct DSMetricPill: View {
    let label: String
    let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DSTypography.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DSTypography.numericFootnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, Spacing.s2)
        .background(
            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                .fill(Color.dsSurfaceGrouped)
        )
    }
}

#Preview("Light") {
    DSMetricPill(label: "已下载", value: "12 章 · 48 MB")
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSMetricPill(label: "可用书源", value: "18 个")
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSMetricPill(label: "剩余空间", value: "24.5 GB")
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
