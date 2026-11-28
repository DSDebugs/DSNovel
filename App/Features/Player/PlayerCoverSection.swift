import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI
import UIKit

/// 播放器沉浸封面组件（圆角方封面 + 封面自身色彩弥散呼吸背光 + 方案三封面取色 1pt 呼吸微光边框）
struct PlayerCoverSection: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    let coverURL: String
    let bookTitle: String
    let pipeline: CoverImagePipeline
    let ambientColor: Color
    let coverImage: UIImage?
    let playbackState: PlaybackState
    let isObscured: Bool
    private let onDoubleTapPlayPause: () -> Void
    private let onImageLoaded: (UIImage) -> Void

    init(
        coverURL: String,
        bookTitle: String,
        pipeline: CoverImagePipeline,
        ambientColor: Color = DSColors.accent,
        coverImage: UIImage? = nil,
        playbackState: PlaybackState,
        isObscured: Bool = false,
        onDoubleTapPlayPause: @escaping () -> Void,
        onImageLoaded: @escaping (UIImage) -> Void
    ) {
        self.coverURL = coverURL
        self.bookTitle = bookTitle
        self.pipeline = pipeline
        self.ambientColor = ambientColor
        self.coverImage = coverImage
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
        let useStaticBacklight = PlayerAmbientFallbackPolicy.shouldUseStaticGradient(
            isLowPowerMode: isLowPowerMode,
            reduceMotion: reduceMotion,
            thermalState: thermalState
        )
        let isTimelinePaused = !isPlaying || isObscured || scenePhase != .active || useStaticBacklight

        GeometryReader { geo in
            let maxByHeight = max(88, geo.size.height - 16)
            let adaptiveSide = max(0, min(geo.size.width * 0.74, maxByHeight, 286))
            let cornerRadius = DSRadius.cover(forSide: adaptiveSide)
            let isUltraCompactHeight = geo.size.height < 100

            ZStack {
                if useStaticBacklight || isUltraCompactHeight {
                    coverComposition(
                        side: adaptiveSide,
                        cornerRadius: cornerRadius,
                        scale: scale,
                        breathScale: isPlaying ? 1.02 : 0.90,
                        rimPulse: isPlaying ? 0.5 : 0.0,
                        isUltraCompactHeight: isUltraCompactHeight
                    )
                } else {
                    TimelineView(
                        AnimationTimelineSchedule(minimumInterval: 1.0 / 12.0, paused: isTimelinePaused)
                    ) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let wave = sin(t * 1.4)
                        let breathScale = isPlaying ? (1.015 + 0.020 * wave) : 0.90
                        let rimPulse = isPlaying ? (0.5 + 0.5 * wave) : 0.0
                        coverComposition(
                            side: adaptiveSide,
                            cornerRadius: cornerRadius,
                            scale: scale,
                            breathScale: breathScale,
                            rimPulse: rimPulse,
                            isUltraCompactHeight: isUltraCompactHeight
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: 296)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    @ViewBuilder
    private func coverComposition(
        side: CGFloat,
        cornerRadius: CGFloat,
        scale: CGFloat,
        breathScale: CGFloat,
        rimPulse: Double,
        isUltraCompactHeight: Bool
    ) -> some View {
        ZStack {
            if !isUltraCompactHeight {
                coverBloomLayer(side: side, cornerRadius: cornerRadius, breathScale: breathScale)
                    .animation(DSMotion.resolved(DSMotion.smooth, reduceMotion: reduceMotion), value: isPlaying)
            }

            DSCover(
                url: coverURL,
                title: bookTitle.isEmpty ? "有声书" : bookTitle,
                pipeline: pipeline,
                side: side,
                showsBorder: false,
                showsSoftShadow: false,
                onImageLoaded: onImageLoaded
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(isPlaying ? 0.0 : 0.20))
            )
            .overlay(coverRimOverlay(cornerRadius: cornerRadius, rimPulse: rimPulse))
            .shadow(
                color: Color.black.opacity(isPlaying ? 0.34 : 0.22),
                radius: isUltraCompactHeight ? 8 : (isPlaying ? 22 : 12),
                x: 0,
                y: isUltraCompactHeight ? 4 : (isPlaying ? 12 : 6)
            )
            .scaleEffect(scale)
            .animation(DSMotion.resolved(DSMotion.bouncy, reduceMotion: reduceMotion), value: scale)
            .animation(DSMotion.resolved(DSMotion.smooth, reduceMotion: reduceMotion), value: isPlaying)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onDoubleTapPlayPause()
                }
            )
            .accessibilityLabel("专辑封面，双击播放或暂停")
        }
    }

    /// 方案三：封面取色 1pt 极细呼吸微光边（顶角细腻镜面高光 + 封面主色柔润过渡 + 外缘 0.5pt 深色分离线）
    private func coverRimOverlay(cornerRadius: CGFloat, rimPulse: Double) -> some View {
        let topSpecular = isPlaying ? (0.24 + 0.16 * rimPulse) : 0.12
        let ambientEdge = isPlaying ? (0.30 + 0.24 * rimPulse) : 0.14
        let midSoft = isPlaying ? (0.12 + 0.10 * rimPulse) : 0.06
        let bottomTint = isPlaying ? (0.34 + 0.22 * rimPulse) : 0.14

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(topSpecular), location: 0.0),
                            .init(color: ambientColor.opacity(ambientEdge), location: 0.26),
                            .init(color: ambientColor.opacity(midSoft), location: 0.55),
                            .init(color: ambientColor.opacity(bottomTint), location: 0.84),
                            .init(color: Color.white.opacity(topSpecular * 0.65), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.28), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func coverBloomLayer(side: CGFloat, cornerRadius: CGFloat, breathScale: CGFloat) -> some View {
        Group {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side * 1.03, height: side * 1.03)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius + 6, style: .continuous))
                    .saturation(1.35)
                    .blur(radius: isPlaying ? 30 : 12)
                    .opacity(isPlaying ? 0.56 : 0.12)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius + 8, style: .continuous)
                    .fill(ambientColor.opacity(0.65))
                    .frame(width: side + 10, height: side + 10)
                    .blur(radius: isPlaying ? 26 : 10)
                    .opacity(isPlaying ? 0.50 : 0.10)
            }
        }
        .scaleEffect(breathScale)
        .offset(y: isPlaying ? 6 : 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
