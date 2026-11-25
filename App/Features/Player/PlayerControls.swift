import DSDesignSystem
import SwiftUI

/// 播放器主控制行（无界流光风格：无框上一章 · 无框后退15s · 68pt 纯白圆钮播放/暂停 · 无框前进30s · 无框下一章）
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
                    .foregroundStyle(canPlayPrevious ? .white.opacity(0.92) : .white.opacity(0.28))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlayPrevious)
            .accessibilityLabel("上一章")
            .accessibilityHint(canPlayPrevious ? "切换到上一章" : "当前已是第一章")

            Button(action: onSkipBackward) {
                Image(systemName: "gobackward.15")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("后退 15 秒")

            Button(action: onTogglePlay) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)
                        .shadow(
                            color: Color.white.opacity(isPlaying ? 0.28 : 0.12),
                            radius: isPlaying ? 18 : 10,
                            x: 0,
                            y: 4
                        )

                    if isBuffering {
                        ProgressView()
                            .tint(Color.black.opacity(0.85))
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.black.opacity(0.88))
                            .offset(x: isPlaying ? 0 : 1.5)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(.dsCard)
            .accessibilityLabel(isPlaying ? "暂停" : "播放")
            .accessibilityValue(isBuffering ? "正在缓冲" : (isPlaying ? "播放中" : "已暂停"))

            Button(action: onSkipForward) {
                Image(systemName: "goforward.30")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前进 30 秒")

            Button(action: onNextChapter) {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundStyle(canPlayNext ? .white.opacity(0.92) : .white.opacity(0.28))
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
