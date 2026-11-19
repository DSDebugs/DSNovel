import SwiftUI

struct PlayerSecondaryRow: View {
    let speed: Double
    let effectPreset: AudioEffectPreset
    let sleepOption: SleepTimerOption
    let sleepRemainingSec: Int
    let currentChapterIndex: Int
    let totalChapters: Int
    private let onOpenSpeed: () -> Void
    private let onOpenAudioEffects: () -> Void
    private let onOpenSleep: () -> Void
    private let onOpenChapters: () -> Void

    init(
        speed: Double,
        effectPreset: AudioEffectPreset = .original,
        sleepOption: SleepTimerOption,
        sleepRemainingSec: Int = 0,
        currentChapterIndex: Int = 0,
        totalChapters: Int = 0,
        onOpenSpeed: @escaping () -> Void,
        onOpenAudioEffects: @escaping () -> Void = {},
        onOpenSleep: @escaping () -> Void,
        onOpenChapters: @escaping () -> Void
    ) {
        self.speed = speed
        self.effectPreset = effectPreset
        self.sleepOption = sleepOption
        self.sleepRemainingSec = sleepRemainingSec
        self.currentChapterIndex = currentChapterIndex
        self.totalChapters = totalChapters
        self.onOpenSpeed = onOpenSpeed
        self.onOpenAudioEffects = onOpenAudioEffects
        self.onOpenSleep = onOpenSleep
        self.onOpenChapters = onOpenChapters
    }

    private var sleepDisplayLabel: String {
        guard sleepOption != .off else { return "定时" }
        if sleepRemainingSec > 0 {
            return PlaybackClock.formatSeconds(Double(sleepRemainingSec))
        }
        return sleepOption.label
    }

    private var chaptersDisplayLabel: String {
        if totalChapters > 0 && currentChapterIndex > 0 {
            return "\(currentChapterIndex)/\(totalChapters)"
        } else if totalChapters > 0 {
            return "共\(totalChapters)章"
        }
        return "目录"
    }

    var body: some View {
        HStack(spacing: Spacing.s3) {
            secondaryButton(
                icon: "speedometer",
                label: PlayerSpeedFormatter.format(speed),
                isActive: abs(speed - 1.0) > 0.01,
                accessibilityTitle: "播放倍速 \(PlayerSpeedFormatter.format(speed))",
                action: onOpenSpeed
            )
            secondaryButton(
                icon: effectPreset.iconName,
                label: effectPreset.shortBadge,
                isActive: effectPreset != .original,
                accessibilityTitle: "音质与音效 \(effectPreset.title)",
                action: onOpenAudioEffects
            )
            secondaryButton(
                icon: sleepOption == .off ? "moon" : "moon.fill",
                label: sleepDisplayLabel,
                isActive: sleepOption != .off,
                accessibilityTitle: "睡眠定时 \(sleepDisplayLabel)",
                action: onOpenSleep
            )
            secondaryButton(
                icon: "list.bullet",
                label: chaptersDisplayLabel,
                isActive: false,
                accessibilityTitle: "章节目录 \(chaptersDisplayLabel)",
                action: onOpenChapters
            )
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    private func secondaryButton(
        icon: String,
        label: String,
        isActive: Bool,
        accessibilityTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(DSTypography.body.weight(.semibold))
                Text(label)
                    .font(DSTypography.numericCaption)
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.dsAccent : .white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.s3)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isActive ? Color.dsAccent.opacity(0.18) : Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.dsAccent.opacity(0.55) : Color.white.opacity(0.08),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
    }
}
