import DSDesignSystem
import SwiftUI

/// 「我的」顶部书源概览卡（展示已启用书源数、喜马拉雅登录态与书源管理直达）
struct SourceHealthCard: View {
    let totalCount: Int
    let enabledCount: Int
    let needLoginCount: Int
    let statusSubtitle: String?
    private let onOpenSourceList: () -> Void

    init(
        totalCount: Int,
        enabledCount: Int,
        needLoginCount: Int,
        statusSubtitle: String? = nil,
        onOpenSourceList: @escaping () -> Void
    ) {
        self.totalCount = totalCount
        self.enabledCount = enabledCount
        self.needLoginCount = needLoginCount
        self.statusSubtitle = statusSubtitle
        self.onOpenSourceList = onOpenSourceList
    }

    private var resolvedSubtitle: String {
        if let statusSubtitle, !statusSubtitle.isEmpty {
            return statusSubtitle
        }
        return "共 \(totalCount) 个书源 · \(needLoginCount) 个支持登录"
    }

    var body: some View {
        if totalCount == 0 {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text("导入书源后才能搜索与播放")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                DSActionButton(
                    title: "书源管理",
                    icon: "plus.circle.fill",
                    role: .primary,
                    action: onOpenSourceList
                )
            }
            .padding(DSSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                    .fill(DSColors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                    .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.75)
            )
        } else {
            Button(action: onOpenSourceList) {
                HStack(spacing: DSSpacing.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(enabledCount) / \(totalCount) 已启用")
                            .font(DSTypography.title.monospacedDigit())
                            .foregroundStyle(DSColors.inkPrimary)
                            .contentTransition(.numericText())
                        Text(resolvedSubtitle)
                            .font(DSTypography.numericFootnote)
                            .foregroundStyle(DSColors.inkSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        Text("书源管理")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                        Image(systemName: "chevron.right")
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                    }
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(DSColors.accent.opacity(0.14)))
                    .overlay(
                        Capsule()
                            .strokeBorder(DSColors.accent.opacity(0.35), lineWidth: 0.75)
                    )
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.md)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                    .fill(DSColors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                    .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.75)
            )
            .accessibilityLabel("书源状态：已启用 \(enabledCount) 个，共 \(totalCount) 个书源，点击进入书源管理")
        }
    }
}
