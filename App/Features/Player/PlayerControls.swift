import DSDesignSystem
import SwiftUI

/// 播放器主控制行（1:1 复刻 v2.8 顺序：上一章 · 后退15s · 74pt DSColors.accent 播放/暂停圆钮 · 前进30s · 下一章）
struct PlayerControls: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion

    let isPlaying: Bool
    let isBuffering: Bool
    let canPlayPrevious: Bool
    let canPlayNext: Bool
    private let onPreviousChapter: () -> Void
    private let onSkipBackward: () -> Void
    private let onTogglePlay: () -> Void
    private let onSkipForward: () -> Void
    private let onNextChapter: () -> Void

    init(
        isPlaying: Bool,
        isBuffering: Bool,
        canPlayPrevious: Bool,
        canPlayNext: Bool,
        onPreviousChapter: @escaping () -> Void,
        onSkipBackward: @escaping () -> Void,
        onTogglePlay: @escaping () -> Void,
        onSkipForward: @escaping () -> Void,
        onNextChapter: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.canPlayPrevious = canPlayPrevious
        self.canPlayNext = canPlayNext
        self.onPreviousChapter = onPreviousChapter
        self.onSkipBackward = onSkipBackward
        self.onTogglePlay = onTogglePlay
        self.onSkipForward = onSkipForward
        self.onNextChapter = onNextChapter
    }

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        HStack(spacing: DSSpacing.s5) {
            Button(action: onPreviousChapter) {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .foregroundStyle(canPlayPrevious ? .white : .white.opacity(0.32))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlayPrevious)
            .accessibilityLabel("上一章")
            .accessibilityHint(canPlayPrevious ? "切换到上一章" : "当前已是第一章")

            Button(action: onSkipBackward) {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("后退 15 秒")

            Button(action: onTogglePlay) {
                ZStack {
                    Circle()
                        .fill(DSColors.accent)
                        .frame(width: 74, height: 74)
                        .shadow(color: DSColors.accent.opacity(0.42), radius: 14, x: 0, y: 6)

                    if isBuffering {
                        ProgressView()
                            .tint(DSColors.onAccent)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title.weight(.bold))
                            .foregroundStyle(DSColors.onAccent)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(.dsCard)
            .accessibilityLabel(isPlaying ? "暂停" : "播放")
            .accessibilityValue(isBuffering ? "正在缓冲" : (isPlaying ? "播放中" : "已暂停"))

            Button(action: onSkipForward) {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前进 30 秒")

            Button(action: onNextChapter) {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundStyle(canPlayNext ? .white : .white.opacity(0.32))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlayNext)
            .accessibilityLabel("下一章")
            .accessibilityHint(canPlayNext ? "切换到下一章" : "当前已是最后一章")
        }
        .padding(.vertical, DSSpacing.xs)
    }
}
