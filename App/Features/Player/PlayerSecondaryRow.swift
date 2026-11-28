import DSDesignSystem
import DSPlayback
import SwiftUI

/// 独立睡眠定时副功能按钮叶子视图：仅自身订阅 SleepTimerEngine，隔离 1Hz 重绘
private struct PlayerSleepSecondaryButton: View {
    let sleepTimer: SleepTimerEngine
    private let action: () -> Void

    init(sleepTimer: SleepTimerEngine, action: @escaping () -> Void) {
        self.sleepTimer = sleepTimer
        self.action = action
    }

    var body: some View {
        let isActive = sleepTimer.isActive
        let label = sleepTimer.displayBadge ?? "定时"
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: isActive ? "moon.fill" : "moon")
                    .font(DSTypography.body.weight(.medium))
                Text(label)
                    .font(DSTypography.numericCaption)
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? DSColors.accent : .white.opacity(0.78))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("睡眠定时 \(label)")
    }
}

/// 播放器底部无框功能条（倍速、音效、定时、目录直接悬浮于环境流光之上）
struct PlayerSecondaryRow: View {
    let speed: Double
    let effectLabel: String
    let effectIcon: String
    let isEffectActive: Bool
    let sleepTimer: SleepTimerEngine
    let currentChapterOneBased: Int
    let totalChapters: Int
    let hasNoBook: Bool
    private let onOpenSpeed: () -> Void
    private let onOpenAudioEffects: () -> Void
    private let onOpenSleep: () -> Void
    private let onOpenChapters: () -> Void

    init(
        speed: Double,
        effectLabel: String,
        effectIcon: String,
        isEffectActive: Bool,
        sleepTimer: SleepTimerEngine,
        currentChapterOneBased: Int,
        totalChapters: Int,
        hasNoBook: Bool,
        onOpenSpeed: @escaping () -> Void,
        onOpenAudioEffects: @escaping () -> Void,
        onOpenSleep: @escaping () -> Void,
        onOpenChapters: @escaping () -> Void
    ) {
        self.speed = speed
        self.effectLabel = effectLabel
        self.effectIcon = effectIcon
        self.isEffectActive = isEffectActive
        self.sleepTimer = sleepTimer
        self.currentChapterOneBased = currentChapterOneBased
        self.totalChapters = totalChapters
        self.hasNoBook = hasNoBook
        self.onOpenSpeed = onOpenSpeed
        self.onOpenAudioEffects = onOpenAudioEffects
        self.onOpenSleep = onOpenSleep
        self.onOpenChapters = onOpenChapters
    }

    private var chaptersDisplayLabel: String {
        if totalChapters > 0 && currentChapterOneBased > 0 {
            return "\(currentChapterOneBased)/\(totalChapters)"
        } else if totalChapters > 0 {
            return "共\(totalChapters)章"
        }
        return "目录"
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            secondaryButton(
                icon: "speedometer",
                label: PlayerSpeedFormatter.format(speed),
                isActive: abs(speed - 1.0) > 0.01,
                disabled: false,
                accessibilityTitle: "播放倍速 \(PlayerSpeedFormatter.format(speed))",
                action: onOpenSpeed
            )
            secondaryButton(
                icon: effectIcon,
                label: effectLabel,
                isActive: isEffectActive,
                disabled: false,
                accessibilityTitle: "音效设置 \(effectLabel)",
                action: onOpenAudioEffects
            )
            PlayerSleepSecondaryButton(sleepTimer: sleepTimer, action: onOpenSleep)
            secondaryButton(
                icon: "list.bullet",
                label: chaptersDisplayLabel,
                isActive: false,
                disabled: hasNoBook,
                accessibilityTitle: "章节目录 \(chaptersDisplayLabel)",
                action: onOpenChapters
            )
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    private func secondaryButton(
        icon: String,
        label: String,
        isActive: Bool,
        disabled: Bool,
        accessibilityTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(DSTypography.body.weight(.medium))
                Text(label)
                    .font(DSTypography.numericCaption)
                    .lineLimit(1)
            }
            .foregroundStyle(
                disabled ? .white.opacity(0.30) : (isActive ? DSColors.accent : .white.opacity(0.78))
            )
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(accessibilityTitle)
    }
}
