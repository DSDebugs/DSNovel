import DSCore
import DSDesignSystem
import DSStorage
import SwiftUI

/// 听书统计详情页（周期切换、汇总 Hero 卡、每日趋势柱状图、最常听书籍排行）
struct ListeningStatsView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router

    @State private var selectedPeriod: ListeningStatsPeriod = .week

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        let _ = container.listeningStats.revision
        let report = container.listeningStats.report(for: selectedPeriod)

        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.sectionVertical) {
                periodSegmentBar
                heroSummaryCard(report: report)
                dailyTrendCard(report: report)
                topBooksCard(report: report)
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .padding(.vertical, DSSpacing.md)
        }
        .background(DSColors.surfaceBase)
        .navigationTitle("听书统计")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("listening_stats_view")
    }

    private var periodSegmentBar: some View {
        HStack(spacing: DSSpacing.xxs) {
            ForEach(ListeningStatsPeriod.allCases) { period in
                let isSelected = (period == selectedPeriod)
                Button {
                    DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                        selectedPeriod = period
                    }
                } label: {
                    Text(period.title)
                        .font(DSTypography.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 34)
                        .background(
                            Capsule()
                                .fill(isSelected ? DSColors.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stats_period_\(period.rawValue)")
            }
        }
        .padding(DSSpacing.xxs)
        .background(Capsule().fill(DSColors.surfaceGrouped))
    }

    private func heroSummaryCard(report: ListeningPeriodReport) -> some View {
        let totalPair = ListeningStatsStore.formatCompactDuration(report.totalSeconds)
        let todayText = ListeningStatsStore.formatInlineDuration(report.todaySeconds)
        let avgText = ListeningStatsStore.formatInlineDuration(report.dailyAverageSeconds)

        return VStack(alignment: .leading, spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(report.period.heroTitle)
                    .font(DSTypography.footnote)
                    .foregroundStyle(DSColors.inkSecondary)

                HStack(alignment: .lastTextBaseline, spacing: DSSpacing.xs) {
                    Text(totalPair.value)
                        .font(DSTypography.largeTitle.monospacedDigit())
                        .foregroundStyle(DSColors.inkPrimary)
                    Text(totalPair.unit)
                        .font(DSTypography.headline)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            Rectangle()
                .fill(DSColors.separator.opacity(0.35))
                .frame(height: 0.5)

            HStack(spacing: 0) {
                heroSubMetric(title: "今日", value: todayText)
                heroSubMetric(title: "日均", value: avgText)
                heroSubMetric(title: "连续收听", value: "\(report.streakDays) 天")
            }
        }
        .padding(DSSpacing.md)
        .background(cardBackground(radius: DSRadius.heroCard))
    }

    private func heroSubMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.inkSecondary)
            Text(value)
                .font(DSTypography.cardTitle.monospacedDigit())
                .foregroundStyle(DSColors.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailyTrendCard(report: ListeningPeriodReport) -> some View {
        let maxSec = maxBarSeconds(in: report.dailyBars)
        let avgSec = report.dailyAverageSeconds
        let chartHeight: CGFloat = 132

        return VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.period == .month ? "近 14 日收听时长" : "每日收听时长")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer()
                if avgSec > 0 {
                    Text("日均 \(ListeningStatsStore.formatInlineDuration(avgSec))")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            ZStack(alignment: .bottom) {
                if maxSec > 0 && avgSec > 0 {
                    let ratio = min(1.0, max(0.08, avgSec / maxSec))
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        DashedAverageLine()
                            .stroke(
                                DSColors.accent.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                            .frame(height: 1)
                            .padding(.bottom, chartHeight * CGFloat(ratio) + 22)
                    }
                    .frame(height: chartHeight + 24)
                }

                HStack(alignment: .bottom, spacing: report.period == .month ? 4 : 10) {
                    ForEach(report.dailyBars) { bar in
                        let heightRatio = maxSec > 0 ? min(1.0, bar.seconds / maxSec) : 0
                        let barHeight = bar.seconds > 0
                            ? max(8, chartHeight * CGFloat(heightRatio))
                            : 6

                        VStack(spacing: DSSpacing.xs) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                .fill(barColor(for: bar))
                                .frame(height: barHeight)
                                .animation(
                                    DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion),
                                    value: selectedPeriod
                                )

                            Text(bar.label)
                                .font(DSTypography.caption2.monospacedDigit())
                                .foregroundStyle(bar.isToday ? DSColors.accent : DSColors.inkSecondary)
                                .fontWeight(bar.isToday ? .semibold : .regular)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: chartHeight + 24)
            }

            if report.totalSeconds <= 0 {
                Text("开始播放有声书后，将自动按天累计真实收听时长。")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
        }
        .padding(DSSpacing.md)
        .background(cardBackground(radius: DSRadius.card))
    }

    private func topBooksCard(report: ListeningPeriodReport) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("最常听书籍")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer()
                if !report.topBooks.isEmpty {
                    Text("Top \(report.topBooks.count)")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            if report.topBooks.isEmpty {
                VStack(spacing: DSSpacing.sm) {
                    Image(systemName: "headphones")
                        .font(DSTypography.title)
                        .foregroundStyle(DSColors.inkSecondary)
                    Text("暂无收听排行")
                        .font(DSTypography.cardTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                    Text("去书架或首页听一本书，这里会展示你的收听时长排行。")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.md)
            } else {
                VStack(spacing: DSSpacing.md) {
                    ForEach(report.topBooks) { item in
                        topBookRow(item)
                    }
                }
            }
        }
        .padding(DSSpacing.md)
        .background(cardBackground(radius: DSRadius.card))
    }

    private func topBookRow(_ item: ListeningBookRankItem) -> some View {
        Button {
            router.push(.bookDetail(item.toBookSummaryDTO()))
        } label: {
            HStack(spacing: DSSpacing.sm) {
                DSCover(
                    url: item.coverURL,
                    title: item.bookTitle,
                    pipeline: container.coverPipeline,
                    side: 46
                )

                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(item.bookTitle)
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                        Spacer(minLength: DSSpacing.xs)
                        Text(ListeningStatsStore.formatInlineDuration(item.seconds))
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DSColors.surfaceGrouped)
                            Capsule()
                                .fill(DSColors.accent)
                                .frame(width: max(8, geo.size.width * CGFloat(item.ratio)))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsCard)
    }

    private func barColor(for bar: ListeningDayBar) -> Color {
        if bar.seconds <= 0 {
            return DSColors.surfaceGrouped
        }
        if bar.isToday || bar.isAboveAverage {
            return DSColors.accent
        }
        return DSColors.accent.opacity(0.32)
    }

    private func maxBarSeconds(in bars: [ListeningDayBar]) -> Double {
        var best: Double = 0
        for bar in bars where bar.seconds > best {
            best = bar.seconds
        }
        return best
    }

    private func cardBackground(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(DSColors.surfaceCard)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(DSColors.separator.opacity(0.28), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
    }
}

private struct DashedAverageLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}
