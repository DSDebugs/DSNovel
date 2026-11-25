import DSDesignSystem
import DSStorage
import SwiftUI

/// 书架顶部单行精致「听书统计」轻条（44pt 高：保留今日/本周/连续完整数据，立省垂直空间）
struct ListeningStatsCard: View {
    let overview: ListeningOverviewSummary
    let onOpenDetail: () -> Void

    var body: some View {
        let todayPair = ListeningStatsStore.formatCompactDuration(overview.todaySeconds)
        let weekPair = ListeningStatsStore.formatCompactDuration(overview.weekSeconds)

        Button(action: onOpenDetail) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "chart.bar.fill")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)

                HStack(spacing: 5) {
                    inlineMetric(label: "今日", value: "\(todayPair.value)\(todayPair.unit)")
                    Text("·")
                        .foregroundStyle(DSColors.inkSecondary.opacity(0.55))
                    inlineMetric(label: "本周", value: "\(weekPair.value)\(weekPair.unit)")
                    Text("·")
                        .foregroundStyle(DSColors.inkSecondary.opacity(0.55))
                    inlineMetric(label: "连续", value: "\(overview.streakDays)天")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    Text("详情")
                    Image(systemName: "chevron.right")
                        .font(DSTypography.caption2.weight(.semibold))
                }
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(DSColors.accent)
                .layoutPriority(1)
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(DSColors.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                            .stroke(DSColors.separator.opacity(0.32), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
            )
            .padding(.horizontal, DSSpacing.pageHorizontal)
        }
        .buttonStyle(.dsCard)
        .accessibilityIdentifier("library_listening_stats_card")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "听书统计，今日 \(todayPair.value)\(todayPair.unit)，本周 \(weekPair.value)\(weekPair.unit)，连续 \(overview.streakDays) 天"
        )
    }

    private func inlineMetric(label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.inkSecondary)
            Text(value)
                .font(DSTypography.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(DSColors.inkPrimary)
        }
    }
}
