import SwiftUI

/// 独立睡眠倒计时徽标叶子视图：仅自身订阅 `player.estimatedSleepRemainingSec`，避免触发整个 PlayerScreen 每秒重绘
struct SleepCountdownBadge: View {
    let player: PlayerEngine
    private let onTap: () -> Void

    init(player: PlayerEngine, onTap: @escaping () -> Void) {
        self.player = player
        self.onTap = onTap
    }

    var body: some View {
        if player.sleepOption != .off {
            let remaining = player.estimatedSleepRemainingSec
            let sleepLabel = remaining > 0
                ? PlaybackClock.formatSeconds(Double(remaining))
                : player.sleepOption.label
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: "moon.fill")
                    Text(sleepLabel)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.s2)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("睡眠定时")
            .accessibilityValue("剩余 \(sleepLabel)")
        }
    }
}

/// 全屏播放器顶栏（已按实测反馈优化）：
/// 1. 彻底移除顶部小横杠（Grabber Capsule），让整体视觉更纯净并释放顶部纵向空间；
/// 2. 书源胶囊改为纯静态名称展示（移除切换书源点击交互）；
/// 3. 保留音质/离线状态徽标与独立叶子睡眠倒计时胶囊。
struct PlayerHeader: View {
    let sourceName: String
    let streamBadgeText: String
    let sleepOption: SleepTimerOption
    let sleepRemainingSec: Int
    let sleepPlayer: PlayerEngine?
    private let onDismiss: () -> Void
    private let onOpenAudioEffects: () -> Void
    private let onOpenSleepSheet: () -> Void
    private let onOpenMoreSheet: () -> Void

    init(
        sourceName: String = "",
        streamBadgeText: String = "高清·128k",
        sleepOption: SleepTimerOption = .off,
        sleepRemainingSec: Int = 0,
        sleepPlayer: PlayerEngine? = nil,
        onDismiss: @escaping () -> Void,
        onOpenAudioEffects: @escaping () -> Void = {},
        onOpenSleepSheet: @escaping () -> Void,
        onOpenMoreSheet: @escaping () -> Void
    ) {
        self.sourceName = sourceName
        self.streamBadgeText = streamBadgeText
        self.sleepOption = sleepOption
        self.sleepRemainingSec = sleepRemainingSec
        self.sleepPlayer = sleepPlayer
        self.onDismiss = onDismiss
        self.onOpenAudioEffects = onOpenAudioEffects
        self.onOpenSleepSheet = onOpenSleepSheet
        self.onOpenMoreSheet = onOpenMoreSheet
    }

    var body: some View {
        HStack(spacing: Spacing.s2) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Circle())
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
                    }
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("当前音源 \(sourceName)")
                }

                Button(action: onOpenAudioEffects) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(DSTypography.caption2)
                        Text(streamBadgeText)
                            .lineLimit(1)
                    }
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.dsAccent.opacity(0.18))
                    )
                    .overlay(
                        Capsule().strokeBorder(Color.dsAccent.opacity(0.45), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前音质 \(streamBadgeText)，点击打开音质与音效设置")

                if let sleepPlayer {
                    SleepCountdownBadge(player: sleepPlayer, onTap: onOpenSleepSheet)
                } else if sleepOption != .off {
                    let sleepLabel = sleepRemainingSec > 0
                        ? PlaybackClock.formatSeconds(Double(sleepRemainingSec))
                        : sleepOption.label
                    Button(action: onOpenSleepSheet) {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.fill")
                            Text(sleepLabel)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.s2)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("睡眠定时")
                    .accessibilityValue("剩余 \(sleepLabel)")
                }
            }

            Spacer(minLength: 4)

            Button(action: onOpenMoreSheet) {
                Image(systemName: "ellipsis")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多播放设置")
        }
        .padding(.horizontal, Spacing.pageHorizontal)
        .padding(.top, Spacing.s1)
    }
}
