import SwiftUI

struct PlayerHeader: View {
    let sourceName: String
    let streamBadgeText: String
    let sleepOption: SleepTimerOption
    let sleepRemainingSec: Int
    private let onDismiss: () -> Void
    private let onOpenSourceSwitch: () -> Void
    private let onOpenAudioEffects: () -> Void
    private let onOpenSleepSheet: () -> Void
    private let onOpenMoreSheet: () -> Void

    init(
        sourceName: String = "",
        streamBadgeText: String = "HQ 128k",
        sleepOption: SleepTimerOption,
        sleepRemainingSec: Int,
        onDismiss: @escaping () -> Void,
        onOpenSourceSwitch: @escaping () -> Void = {},
        onOpenAudioEffects: @escaping () -> Void = {},
        onOpenSleepSheet: @escaping () -> Void,
        onOpenMoreSheet: @escaping () -> Void
    ) {
        self.sourceName = sourceName
        self.streamBadgeText = streamBadgeText
        self.sleepOption = sleepOption
        self.sleepRemainingSec = sleepRemainingSec
        self.onDismiss = onDismiss
        self.onOpenSourceSwitch = onOpenSourceSwitch
        self.onOpenAudioEffects = onOpenAudioEffects
        self.onOpenSleepSheet = onOpenSleepSheet
        self.onOpenMoreSheet = onOpenMoreSheet
    }

    var body: some View {
        VStack(spacing: Spacing.s2) {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, Spacing.s2)
                .accessibilityHidden(true)

            HStack(spacing: Spacing.s2) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.down")
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起播放器")

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if !sourceName.isEmpty {
                        Button(action: onOpenSourceSwitch) {
                            HStack(spacing: 4) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(DSTypography.caption2)
                                Text(sourceName)
                                    .lineLimit(1)
                            }
                            .font(DSTypography.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, Spacing.s2)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("当前书源 \(sourceName)，点击切换书源")
                    }

                    Button(action: onOpenAudioEffects) {
                        HStack(spacing: 3) {
                            Image(systemName: streamBadgeText == "本地离线" ? "checkmark.circle.fill" : "waveform.badge.magnifyingglass")
                                .font(DSTypography.caption2)
                            Text(streamBadgeText)
                                .lineLimit(1)
                        }
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .padding(.horizontal, Spacing.s2)
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

                    if sleepOption != .off {
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
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多播放设置")
            }
            .padding(.horizontal, Spacing.pageHorizontal)
        }
    }
}
