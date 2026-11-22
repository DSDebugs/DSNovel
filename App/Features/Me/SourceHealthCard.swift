import DSDesignSystem
import SwiftUI

/// 「我的」顶部书源健康概览卡（1:1 复刻 v2.8 SourceHealthCard，展示已启用书源数与书源管理直达）
struct SourceHealthCard: View {
    let totalCount: Int
    let enabledCount: Int
    let needLoginCount: Int
    private let onOpenSourceList: () -> Void

    init(
        totalCount: Int,
        enabledCount: Int,
        needLoginCount: Int,
        onOpenSourceList: @escaping () -> Void
    ) {
        self.totalCount = totalCount
        self.enabledCount = enabledCount
        self.needLoginCount = needLoginCount
        self.onOpenSourceList = onOpenSourceList
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
        } else {
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.sm) {
                    Button(action: onOpenSourceList) {
                        HStack(spacing: DSSpacing.xs) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(enabledCount) / \(totalCount) 已启用")
                                    .font(DSTypography.sectionHeader.monospacedDigit())
                                    .foregroundStyle(DSColors.inkPrimary)
                                    .contentTransition(.numericText())
                                Text("共 \(totalCount) 个书源 · \(needLoginCount) 个支持登录")
                                    .font(DSTypography.numericFootnote)
                                    .foregroundStyle(DSColors.inkSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
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
                            .background(Capsule().fill(DSColors.accent.opacity(0.12)))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("书源状态：已启用 \(enabledCount) 个，共 \(totalCount) 个书源，点击进入书源管理")
                }
                .padding(DSSpacing.md)
            }
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                    .fill(DSColors.surfaceCard)
            )
        }
    }
}
