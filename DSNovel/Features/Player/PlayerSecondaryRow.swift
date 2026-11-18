import SwiftUI

struct PlayerSecondaryRow: View {
    let speed: Double
    let isSubtitleActive: Bool
    let soundEffectTitle: String
    private let onDownloadCurrent: () -> Void
    private let onOpenSpeed: () -> Void
    private let onOpenSoundEffect: () -> Void
    private let onToggleSubtitle: () -> Void
    private let onOpenMore: () -> Void

    init(
        speed: Double,
        isSubtitleActive: Bool = true,
        soundEffectTitle: String = "音效",
        onDownloadCurrent: @escaping () -> Void = {},
        onOpenSpeed: @escaping () -> Void,
        onOpenSoundEffect: @escaping () -> Void = {},
        onToggleSubtitle: @escaping () -> Void = {},
        onOpenMore: @escaping () -> Void
    ) {
        self.speed = speed
        self.isSubtitleActive = isSubtitleActive
        self.soundEffectTitle = soundEffectTitle
        self.onDownloadCurrent = onDownloadCurrent
        self.onOpenSpeed = onOpenSpeed
        self.onOpenSoundEffect = onOpenSoundEffect
        self.onToggleSubtitle = onToggleSubtitle
        self.onOpenMore = onOpenMore
    }

    var body: some View {
        HStack(spacing: 0) {
            actionIcon(
                icon: "arrow.down.to.line",
                badge: nil,
                isActive: false,
                label: "下载本集",
                action: onDownloadCurrent
            )

            actionIcon(
                icon: "gauge.with.dots.needle.33percent",
                badge: String(format: "%.2gx", speed),
                isActive: abs(speed - 1.0) > 0.01,
                label: "播放倍速",
                action: onOpenSpeed
            )

            actionIcon(
                icon: "waveform.circle",
                badge: soundEffectTitle,
                isActive: true,
                label: "音质音效",
                action: onOpenSoundEffect
            )

            actionIcon(
                icon: isSubtitleActive ? "captions.bubble.fill" : "captions.bubble",
                badge: "AI文稿",
                isActive: isSubtitleActive,
                label: "切换文稿字幕",
                action: onToggleSubtitle
            )

            actionIcon(
                icon: "ellipsis.circle",
                badge: nil,
                isActive: false,
                label: "更多设置",
                action: onOpenMore
            )
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    private func actionIcon(
        icon: String,
        badge: String?,
        isActive: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isActive ? .white : .white.opacity(0.78))
                    .frame(width: 44, height: 40)

                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                        .offset(x: 8, y: -2)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
