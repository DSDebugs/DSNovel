import SwiftUI

struct PlayerControls: View {
    let isPlaying: Bool
    let isBuffering: Bool
    let canPlayNext: Bool
    let sleepOption: SleepTimerOption
    let sleepRemainingSec: Int
    private let onOpenSleep: () -> Void
    private let onPreviousChapter: () -> Void
    private let onTogglePlay: () -> Void
    private let onNextChapter: () -> Void
    private let onOpenChapters: () -> Void

    init(
        isPlaying: Bool,
        isBuffering: Bool,
        canPlayNext: Bool,
        sleepOption: SleepTimerOption = .off,
        sleepRemainingSec: Int = 0,
        onOpenSleep: @escaping () -> Void = {},
        onPreviousChapter: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void = {},
        onTogglePlay: @escaping () -> Void,
        onSkipForward: @escaping () -> Void = {},
        onNextChapter: @escaping () -> Void,
        onOpenChapters: @escaping () -> Void = {}
    ) {
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.canPlayNext = canPlayNext
        self.sleepOption = sleepOption
        self.sleepRemainingSec = sleepRemainingSec
        self.onOpenSleep = onOpenSleep
        self.onPreviousChapter = onPreviousChapter
        self.onTogglePlay = onTogglePlay
        self.onNextChapter = onNextChapter
        self.onOpenChapters = onOpenChapters
        _ = onSkipBackward
        _ = onSkipForward
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenSleep) {
                VStack(spacing: 2) {
                    Image(systemName: sleepOption == .off ? "clock.badge.checkmark" : "moon.zzz.fill")
                        .font(.title3)
                        .foregroundStyle(sleepOption == .off ? .white.opacity(0.85) : Color.dsAccent)
                    if sleepOption != .off {
                        Text(sleepRemainingSec > 0 ? PlaybackClock.formatSeconds(Double(sleepRemainingSec)) : sleepOption.label)
                            .font(DSTypography.caption2.monospacedDigit())
                            .foregroundStyle(Color.dsAccent)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("定时关闭")

            Button(action: onPreviousChapter) {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上一章")

            Button(action: onTogglePlay) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 68, height: 68)

                    if isBuffering {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                            .offset(x: isPlaying ? 0 : 2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dsCard)
            .accessibilityLabel(isPlaying ? "暂停" : "播放")

            Button(action: onNextChapter) {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
                    .foregroundStyle(canPlayNext ? .white : .white.opacity(0.35))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .disabled(!canPlayNext)
            .accessibilityLabel("下一章")

            Button(action: onOpenChapters) {
                Image(systemName: "list.bullet.indent")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放列表")
        }
        .padding(.horizontal, Spacing.pageHorizontal)
        .padding(.vertical, Spacing.s1)
    }
}
