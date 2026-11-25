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
                        .font(DSTypography.caption2)
                    Text(label)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(DSTypography.caption2.weight(.semibold))
                .foregroundStyle(DSColors.accent)
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.11)))
                .overlay(Capsule().strokeBorder(DSColors.accent.opacity(0.35), lineWidth: 0.5))
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

/// 全屏播放器顶栏（无界流光风格：左无框收起钮 · 中统一半透明「书源 · 音质」胶囊 + 定时胶囊 · 右无框更多钮）
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

    private var trimmedSourceName: String {
        sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedQualityBadge: String? {
        guard let raw = qualityBadgeText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(DSTypography.rowTitle.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起播放器")

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if let badge = trimmedQualityBadge {
                    Button(action: onOpenQuality) {
                        unifiedPillLabel(source: trimmedSourceName, quality: badge)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .accessibilityLabel(
                        trimmedSourceName.isEmpty
                            ? "当前音质 \(badge)，点击查看或切换音质"
                            : "当前音源 \(trimmedSourceName)，音质 \(badge)，点击查看或切换音质"
                    )
                } else if !trimmedSourceName.isEmpty {
                    unifiedPillLabel(source: trimmedSourceName, quality: nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("当前音源 \(trimmedSourceName)")
                }

                PlayerSleepCountdownBadge(sleepTimer: sleepTimer, onTap: onOpenSleepSheet)
            }

            Spacer(minLength: 4)

            Button(action: onOpenMoreSheet) {
                Image(systemName: "ellipsis")
                    .font(DSTypography.rowTitle.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多播放设置")
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.top, DSSpacing.xxs)
    }

    private func unifiedPillLabel(source: String, quality: String?) -> some View {
        HStack(spacing: 5) {
            if !source.isEmpty {
                Text(source)
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if !source.isEmpty, quality != nil {
                Text("·")
                    .font(DSTypography.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.42))
            }

            if let quality {
                Text(quality)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.11)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .frame(maxWidth: 196)
    }
}
