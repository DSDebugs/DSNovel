import SwiftUI

struct MiniPlayerProgressRing: View {
    let clock: PlaybackClock
    let isPlaying: Bool
    let isBuffering: Bool
    private let onTogglePlay: () -> Void

    init(
        clock: PlaybackClock,
        isPlaying: Bool,
        isBuffering: Bool,
        onTogglePlay: @escaping () -> Void
    ) {
        self.clock = clock
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.onTogglePlay = onTogglePlay
    }

    var body: some View {
        Button(action: onTogglePlay) {
            ZStack {
                DSProgress(
                    value: clock.progressFraction,
                    style: .ring(size: 34, lineWidth: 2.5)
                )
                if isBuffering {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(DSTypography.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
    }
}
