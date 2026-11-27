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
                .fill(Color.black.opacity(0.38))
            Capsule(style: .continuous)
                .fill(accentColor)
                .frame(width: max(clamped > 0.01 ? 4 : 0, width * clamped))
        }
        .frame(width: width, height: 2)
    }
}

/// 精工典藏黑胶唱片（物理分离旋转盘体与静止 45° 镜面丝光 + 无脏晕贴地微影 + 旋转定位微标）
struct MiniPlayerVinylDisc: View {
    @Environment(\.colorScheme) private var colorScheme

    let diameter: CGFloat
    let accentColor: Color
    let isActiveBook: Bool
    let rotationDegrees: Double

    var body: some View {
        ZStack {
            rotatingDiscBody
                .rotationEffect(.degrees(rotationDegrees))

            staticSpecularOverlay
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.14),
            radius: 2,
            x: 0.5,
            y: 1
        )
    }

    private var rotatingDiscBody: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.12, green: 0.12, blue: 0.135),
                            Color(red: 0.045, green: 0.045, blue: 0.055),
                            Color(red: 0.08, green: 0.08, blue: 0.095)
                        ],
                        center: .center,
                        startRadius: diameter * 0.18,
                        endRadius: diameter * 0.50
                    )
                )

            ForEach([0.85, 0.72, 0.59], id: \.self) { ratio in
                Circle()
                    .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.45)
                    .frame(width: diameter * ratio, height: diameter * ratio)
            }

            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)

            centerLabel
        }
        .frame(width: diameter, height: diameter)
    }

    private var centerLabel: some View {
        let labelSize = diameter * 0.42
        let spindleSize = max(4.5, diameter * 0.14)

        return ZStack {
            Circle()
                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(isActiveBook ? 0.94 : 0.36),
                            accentColor.opacity(isActiveBook ? 0.74 : 0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(isActiveBook ? 0.38 : 0.16), lineWidth: 0.5)

            if isActiveBook {
                Circle()
                    .trim(from: 0.04, to: 0.18)
                    .stroke(
                        Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 0.85, lineCap: .round)
                    )
                    .frame(width: labelSize * 0.72, height: labelSize * 0.72)

                Circle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 1.8, height: 1.8)
                    .offset(x: labelSize * 0.34)
            }

            Circle()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.06))
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.68), lineWidth: 0.7)
                )
                .frame(width: spindleSize, height: spindleSize)
        }
        .frame(width: labelSize, height: labelSize)
    }

    private var staticSpecularOverlay: some View {
        Circle()
            .fill(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: Color.white.opacity(0.17), location: 0.07),
                        .init(color: .clear, location: 0.15),
                        .init(color: .clear, location: 0.50),
                        .init(color: Color.white.opacity(0.10), location: 0.57),
                        .init(color: .clear, location: 0.65),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: .center,
                    angle: .degrees(-42)
                )
            )
            .allowsHitTesting(false)
    }
}
