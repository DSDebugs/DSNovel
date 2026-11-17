import SwiftUI

struct PlayerControls: View {
    let isPlaying: Bool
    let isBuffering: Bool
    let canPlayNext: Bool
    private let onPreviousChapter: () -> Void
    private let onSkipBackward: () -> Void
    private let onTogglePlay: () -> Void
    private let onSkipForward: () -> Void
    private let onNextChapter: () -> Void

    init(
        isPlaying: Bool,
        isBuffering: Bool,
        canPlayNext: Bool,
        onPreviousChapter: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void,
        onTogglePlay: @escaping () -> Void,
        onSkipForward: @escaping () -> Void,
        onNextChapter: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.canPlayNext = canPlayNext
        self.onPreviousChapter = onPreviousChapter
        self.onSkipBackward = onSkipBackward
        self.onTogglePlay = onTogglePlay
        self.onSkipForward = onSkipForward
        self.onNextChapter = onNextChapter
    }

    var body: some View {
        HStack(spacing: Spacing.s5) {
            Button(action: onPreviousChapter) {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上一章")

            Button(action: onSkipBackward) {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("后退 15 秒")

            Button(action: onTogglePlay) {
                ZStack {
                    Circle()
                        .fill(Color.dsAccent)
                        .frame(width: 72, height: 72)

                    if isBuffering {
                        ProgressView()
                            .tint(Color.dsOnAccent)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title.weight(.bold))
                            .foregroundStyle(Color.dsOnAccent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(.dsCard)
            .accessibilityLabel(isPlaying ? "暂停" : "播放")

            Button(action: onSkipForward) {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前进 30 秒")

            Button(action: onNextChapter) {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundStyle(canPlayNext ? .white : .white.opacity(0.35))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(!canPlayNext)
            .accessibilityLabel("下一章")
        }
        .padding(.vertical, Spacing.s2)
    }
}
