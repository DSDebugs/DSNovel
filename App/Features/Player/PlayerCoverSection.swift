import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI
import UIKit

/// 播放器沉浸封面组件（大尺寸无框圆角方封面 + 贴合方形轮廓的流光极光背光，播放态流动呼吸 / 暂停态柔和熄灭）
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
                if !isUltraCompactHeight {
                    if useStaticBacklight {
                        staticSquareBacklight(side: adaptiveSide, cornerRadius: cornerRadius)
                    } else {
                        TimelineView(
                            AnimationTimelineSchedule(minimumInterval: 1.0 / 15.0, paused: isTimelinePaused)
                        ) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                            let bloomAngle = Angle.degrees((t * 26.0).truncatingRemainder(dividingBy: 360.0))
                            let rimAngle = Angle.degrees((t * 38.0).truncatingRemainder(dividingBy: 360.0))
                            let breathScale = isPlaying ? (1.03 + 0.024 * sin(t * 1.9)) : 0.90

                            ZStack {
                                RoundedRectangle(cornerRadius: cornerRadius + 8, style: .continuous)
                                    .fill(auroraGradient(angle: bloomAngle, intensity: 0.72))
                                    .frame(width: adaptiveSide + 14, height: adaptiveSide + 14)
                                    .scaleEffect(breathScale)
                                    .blur(radius: isPlaying ? 26 : 12)
                                    .opacity(isPlaying ? 0.88 : 0.0)

                                RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                                    .strokeBorder(
                                        auroraRimGradient(angle: rimAngle),
                                        lineWidth: 2.2
                                    )
                                    .frame(width: adaptiveSide + 4, height: adaptiveSide + 4)
                                    .blur(radius: 1.4)
                                    .opacity(isPlaying ? 0.90 : 0.0)
                            }
                        }
                        .animation(
                            DSMotion.resolved(DSMotion.smooth, reduceMotion: reduceMotion),
                            value: isPlaying
                        )
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
                            isPlaying ? Color.white.opacity(0.24) : Color.white.opacity(0.10),
                            lineWidth: isPlaying ? 0.8 : 0.5
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(isPlaying ? 0.0 : 0.22))
                )
                .shadow(
                    color: isPlaying ? Color.black.opacity(0.50) : Color.black.opacity(0.28),
                    radius: isUltraCompactHeight ? 8 : (isPlaying ? 28 : 14),
                    x: 0,
                    y: isUltraCompactHeight ? 4 : (isPlaying ? 14 : 6)
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

    private func staticSquareBacklight(side: CGFloat, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius + 8, style: .continuous)
            .fill(auroraGradient(angle: .degrees(35), intensity: 0.65))
            .frame(width: side + 12, height: side + 12)
            .blur(radius: isPlaying ? 24 : 10)
            .opacity(isPlaying ? 0.80 : 0.0)
            .animation(DSMotion.resolved(DSMotion.smooth, reduceMotion: reduceMotion), value: isPlaying)
    }

    private func auroraGradient(angle: Angle, intensity: Double) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                ambientColor.opacity(intensity),
                DSColors.accent.opacity(intensity * 0.92),
                Color.white.opacity(intensity * 0.42),
                ambientColor.opacity(intensity * 0.48),
                DSColors.accent.opacity(intensity * 0.78),
                ambientColor.opacity(intensity)
            ]),
            center: .center,
            angle: angle
        )
    }

    private func auroraRimGradient(angle: Angle) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color.white.opacity(0.55),
                DSColors.accent.opacity(0.85),
                ambientColor.opacity(0.65),
                Color.white.opacity(0.12),
                DSColors.accent.opacity(0.45),
                Color.white.opacity(0.55)
            ]),
            center: .center,
            angle: angle
        )
    }
}
