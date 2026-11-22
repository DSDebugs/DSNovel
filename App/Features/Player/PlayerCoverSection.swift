import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI
import UIKit

/// 播放器沉浸封面组件（1:1 复刻 v2.8：1:1 DSCover + 播放态 1.0x 柔光声波环 / 暂停态 0.86x 内收 + 双击播放暂停）
struct PlayerCoverSection: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let coverURL: String
    let bookTitle: String
    let pipeline: CoverImagePipeline
    let ambientColor: Color
    let playbackState: PlaybackState
    let isObscured: Bool
    private let onDoubleTapPlayPause: () -> Void
    private let onImageLoaded: (UIImage) -> Void

    init(
        coverURL: String,
        bookTitle: String,
        pipeline: CoverImagePipeline,
        ambientColor: Color = DSColors.accent,
        playbackState: PlaybackState,
        isObscured: Bool = false,
        onDoubleTapPlayPause: @escaping () -> Void,
        onImageLoaded: @escaping (UIImage) -> Void
    ) {
        self.coverURL = coverURL
        self.bookTitle = bookTitle
        self.pipeline = pipeline
        self.ambientColor = ambientColor
        self.playbackState = playbackState
        self.isObscured = isObscured
        self.onDoubleTapPlayPause = onDoubleTapPlayPause
        self.onImageLoaded = onImageLoaded
    }

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    private var isPlaying: Bool { playbackState.isPlaying }

    var body: some View {
        let scale = PlayerAmbientFallbackPolicy.coverScale(
            for: playbackState,
            isPressed: false,
            reduceMotion: reduceMotion
        )
        let isTimelinePaused = !isPlaying || isObscured || scenePhase != .active

        GeometryReader { geo in
            let maxByHeight = max(88, geo.size.height - 24)
            let adaptiveSide = max(0, min(geo.size.width * 0.68, maxByHeight, 264))
            let cornerRadius = DSRadius.cover(forSide: adaptiveSide)
            let isUltraCompactHeight = geo.size.height < 100

            ZStack {
                if !isUltraCompactHeight {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    DSColors.accent.opacity(isPlaying ? 0.46 : 0.10),
                                    ambientColor.opacity(isPlaying ? 0.58 : 0.14),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 12,
                                endRadius: adaptiveSide * 0.72
                            )
                        )
                        .frame(width: adaptiveSide * 1.32, height: adaptiveSide * 1.32)
                        .scaleEffect(isPlaying ? 1.06 : 0.78)
                        .blur(radius: isPlaying ? 18 : 10)
                        .animation(DSMotion.resolved(DSMotion.smooth, reduceMotion: reduceMotion), value: isPlaying)
                }

                if !reduceMotion && !isUltraCompactHeight {
                    TimelineView(AnimationTimelineSchedule(minimumInterval: 1.0 / 24.0, paused: isTimelinePaused)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let wave1 = isPlaying ? (1.0 + 0.045 * sin(t * 2.4)) : 0.86
                        let wave2 = isPlaying ? (1.05 + 0.055 * cos(t * 1.8)) : 0.86
                        ZStack {
                            RoundedRectangle(cornerRadius: cornerRadius + 6, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            DSColors.accent.opacity(isPlaying ? 0.55 : 0.0),
                                            Color.white.opacity(isPlaying ? 0.22 : 0.0),
                                            DSColors.accent.opacity(isPlaying ? 0.40 : 0.0)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.4
                                )
                                .frame(width: adaptiveSide + 12, height: adaptiveSide + 12)
                                .scaleEffect(wave1)

                            RoundedRectangle(cornerRadius: cornerRadius + 14, style: .continuous)
                                .strokeBorder(
                                    Color.white.opacity(isPlaying ? 0.14 : 0.0),
                                    lineWidth: 1.0
                                )
                                .frame(width: adaptiveSide + 28, height: adaptiveSide + 28)
                                .scaleEffect(wave2)
                        }
                    }
                }

                DSCover(
                    url: coverURL,
                    title: bookTitle.isEmpty ? "有声书" : bookTitle,
                    pipeline: pipeline,
                    side: adaptiveSide,
                    showsBorder: false,
                    showsSoftShadow: false,
                    onImageLoaded: onImageLoaded
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isPlaying ? Color.white.opacity(0.28) : Color.white.opacity(0.12),
                            lineWidth: isPlaying ? 1.0 : 0.5
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(isPlaying ? 0.0 : 0.26))
                )
                .shadow(
                    color: isPlaying ? Color.black.opacity(0.52) : Color.black.opacity(0.30),
                    radius: isUltraCompactHeight ? 8 : (isPlaying ? 26 : 14),
                    x: 0,
                    y: isUltraCompactHeight ? 4 : (isPlaying ? 14 : 6)
                )
                .scaleEffect(scale)
                .rotation3DEffect(
                    .degrees(isPlaying || reduceMotion ? 0 : -4),
                    axis: (x: 1, y: 0, z: 0)
                )
                .animation(DSMotion.resolved(DSMotion.bouncy, reduceMotion: reduceMotion), value: scale)
                .animation(DSMotion.resolved(DSMotion.smooth, reduceMotion: reduceMotion), value: isPlaying)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onDoubleTapPlayPause()
                    }
                )
                .accessibilityLabel("专辑封面，双击播放或暂停")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: 272)
    }
}
