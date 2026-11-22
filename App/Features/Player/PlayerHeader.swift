import DSDesignSystem
import DSPlayback
import SwiftUI

/// 独立睡眠倒计时胶囊叶子视图：仅自身订阅 SleepTimerEngine，避免触发 PlayerScreen 每秒全页重绘
struct PlayerSleepCountdownBadge: View {
    let sleepTimer: SleepTimerEngine
    private let onTap: () -> Void

    init(sleepTimer: SleepTimerEngine, onTap: @escaping () -> Void) {
        self.sleepTimer = sleepTimer
        self.onTap = onTap
    }

    var body: some View {
        if sleepTimer.isActive, let label = sleepTimer.displayBadge {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: "moon.fill")
                    Text(label)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.18)))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("睡眠定时")
            .accessibilityValue("剩余 \(label)")
        }
    }
}

/// 全屏播放器顶栏（1:1 复刻 v2.8：左 42pt 收起钮 · 中书源胶囊 + 音质胶囊 + 定时胶囊 · 右 42pt 更多钮）
struct PlayerHeader: View {
    let sourceName: String
    let qualityBadgeText: String?
    let sleepTimer: SleepTimerEngine
    private let onDismiss: () -> Void
    private let onOpenQuality: () -> Void
    private let onOpenSleepSheet: () -> Void
    private let onOpenMoreSheet: () -> Void

    init(
        sourceName: String,
        qualityBadgeText: String?,
        sleepTimer: SleepTimerEngine,
        onDismiss: @escaping () -> Void,
        onOpenQuality: @escaping () -> Void,
        onOpenSleepSheet: @escaping () -> Void,
        onOpenMoreSheet: @escaping () -> Void
    ) {
        self.sourceName = sourceName
        self.qualityBadgeText = qualityBadgeText
        self.sleepTimer = sleepTimer
        self.onDismiss = onDismiss
        self.onOpenQuality = onOpenQuality
        self.onOpenSleepSheet = onOpenSleepSheet
        self.onOpenMoreSheet = onOpenMoreSheet
    }

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起播放器")

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if !sourceName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.circle.fill")
                            .font(DSTypography.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                        Text(sourceName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                    .frame(maxWidth: 112)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("当前音源 \(sourceName)")
                }

                if let badge = qualityBadgeText, !badge.isEmpty {
                    Button(action: onOpenQuality) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(DSTypography.caption2)
                            Text(badge)
                                .lineLimit(1)
                        }
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DSColors.accent.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(DSColors.accent.opacity(0.45), lineWidth: 0.5))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .accessibilityLabel("当前音质 \(badge)，点击切换播放音质")
                }

                PlayerSleepCountdownBadge(sleepTimer: sleepTimer, onTap: onOpenSleepSheet)
            }

            Spacer(minLength: 4)

            Button(action: onOpenMoreSheet) {
                Image(systemName: "ellipsis")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多播放设置")
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.top, DSSpacing.xxs)
    }
}
