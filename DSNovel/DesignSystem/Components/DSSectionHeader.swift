import SwiftUI

struct DSSectionHeader: View {
    let title: String
    let subtitle: String?
    let actionTitle: String?
    private let onAction: (() -> Void)?

    init(
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
                Text(title)
                    .font(DSTypography.sectionHeader)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DSTypography.numericFootnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(DSTypography.subtitle.weight(.medium))
                        .foregroundStyle(Color.dsAccent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }
}

#Preview("Light") {
    DSSectionHeader(title: "我的书架", subtitle: "12 本", actionTitle: "管理", onAction: {})
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSSectionHeader(title: "最近在听", subtitle: "5 本")
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSSectionHeader(title: "播放历史", actionTitle: "清空", onAction: {})
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
