import DSDesignSystem
import DSPlayback
import SwiftUI

/// 隔离 2Hz 播放时钟订阅：仅在播放且可见时实时刷新书封底部贴边进度条
struct MiniPlayerLiveProgressBar: View {
    let clock: PlaybackClock
    let width: CGFloat
    let accentColor: Color

    var body: some View {
        MiniPlayerProgressBarTrack(progress: clock.progress, width: width, accentColor: accentColor)
    }
}

struct MiniPlayerProgressBarTrack: View {
    let progress: Double
    let width: CGFloat
    let accentColor: Color

    var body: some View {
        let clamped = min(1.0, max(0.0, progress.isFinite ? progress : 0))
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.42))
            Capsule(style: .continuous)
                .fill(accentColor)
                .frame(width: max(clamped > 0.01 ? 4 : 0, width * clamped))
        }
        .frame(width: width, height: 2.5)
    }
}

/// 精修黑胶唱片（同心微音轨 + 斜向反光 + 哑光主题色中心圆标 + 银边轴孔）
struct MiniPlayerVinylDisc: View {
    let diameter: CGFloat
    let accentColor: Color
    let isPlaying: Bool
    let isActiveBook: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.black.opacity(0.95),
                            Color.white.opacity(0.08),
                            Color.black.opacity(0.96)
                        ],
                        center: .center,
                        startRadius: diameter * 0.16,
                        endRadius: diameter * 0.50
                    )
                )

            ForEach([0.84, 0.70, 0.56], id: \.self) { ratio in
                Circle()
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.45)
                    .frame(width: diameter * ratio, height: diameter * ratio)
            }

            Circle()
                .fill(
                    AngularGradient(
                        colors: [.clear, Color.white.opacity(0.16), .clear, .clear, Color.white.opacity(0.10), .clear],
                        center: .center
                    )
                )

            Circle()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)

            Circle()
                .fill(Color.black.opacity(0.82))
                .overlay(Circle().fill(accentColor.opacity(isActiveBook ? 0.34 : 0.14)))
                .overlay(Circle().strokeBorder(accentColor.opacity(isActiveBook ? 0.78 : 0.30), lineWidth: 0.65))
                .frame(width: diameter * 0.42, height: diameter * 0.42)

            Circle()
                .fill(Color.black.opacity(0.94))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.50), lineWidth: 0.6))
                .frame(width: max(4, diameter * 0.13), height: max(4, diameter * 0.13))
        }
        .frame(width: diameter, height: diameter)
        .shadow(
            color: isPlaying ? accentColor.opacity(0.32) : Color.black.opacity(0.28),
            radius: isPlaying ? 5 : 2,
            x: 1,
            y: 1
        )
    }
}
