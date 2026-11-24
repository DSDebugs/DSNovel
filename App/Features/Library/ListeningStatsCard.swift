import DSDesignSystem
import DSStorage
import SwiftUI

/// 书架顶部紧凑型「听书统计」概览卡（点击进入完整统计页）
struct ListeningStatsCard: View {
    let overview: ListeningOverviewSummary
    let onOpenDetail: () -> Void

    var body: some View {
        let todayPair = ListeningStatsStore.formatCompactDuration(overview.todaySeconds)
        let weekPair = ListeningStatsStore.formatCompactDuration(overview.weekSeconds)

        Button(action: onOpenDetail) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "chart.bar.fill")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(DSColors.accent.opacity(0.12)))

                    Text("听书统计")
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(DSColors.inkPrimary)

                    Spacer()

                    HStack(spacing: 2) {
                        Text("详情")
                        Image(systemName: "chevron.right")
                            .font(DSTypography.caption2.weight(.semibold))
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                }

                HStack(spacing: 0) {
                    metricCell(title: "今日", value: todayPair.value, unit: todayPair.unit)
                    divider
                    metricCell(title: "本周", value: weekPair.value, unit: weekPair.unit)
                    divider
                    metricCell(title: "连续", value: "\(overview.streakDays)", unit: "天")
                }
            }
            .padding(DSSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(DSColors.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                            .stroke(DSColors.separator.opacity(0.28), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
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

    private var divider: some View {
        Rectangle()
            .fill(DSColors.separator.opacity(0.45))
            .frame(width: 0.5, height: 28)
    }

    private func metricCell(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .center, spacing: 3) {
            Text(title)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.inkSecondary)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(DSTypography.title.monospacedDigit())
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(unit)
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
