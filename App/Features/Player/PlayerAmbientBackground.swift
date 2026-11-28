import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI
import UIKit

/// 播放器环境光与封面缩放降级策略（1:1 复刻 v2.8）
enum PlayerAmbientFallbackPolicy {
    static func shouldUseStaticGradient(
        isLowPowerMode: Bool,
        reduceMotion: Bool,
        exceededFrameBudget: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) -> Bool {
        let isThermalConstrained = (thermalState == .serious || thermalState == .critical)
        return isLowPowerMode || reduceMotion || exceededFrameBudget || isThermalConstrained
    }

    static func coverScale(for state: PlaybackState, isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return 1.0 }
        if isPressed { return 0.96 }
        return state.isPlaying ? 1.0 : 0.86
    }
}

/// 沉浸式流体封面漫射背景（Apple Music 风格：真实封面双层柔焦流体漂移 + 下半区可读性压暗 + 低电量/高热/减弱动态自动静态降级）
struct PlayerAmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @State private var accumulatedPhase: TimeInterval = 0
    @State private var activePhaseStartDate: Date?

    let primaryColor: Color
    let coverImage: UIImage?
    let isPlaying: Bool
    let isObscured: Bool

    init(primaryColor: Color, coverImage: UIImage? = nil, isPlaying: Bool, isObscured: Bool = false) {
        self.primaryColor = primaryColor
        self.coverImage = coverImage
        self.isPlaying = isPlaying
        self.isObscured = isObscured
    }

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        let useStatic = PlayerAmbientFallbackPolicy.shouldUseStaticGradient(
            isLowPowerMode: isLowPowerMode,
            reduceMotion: reduceMotion,
            thermalState: thermalState
        )
        let isTimelinePaused = !isPlaying || isObscured || scenePhase != .active

        ZStack {
            Color.black

            if useStatic {
                staticAtmosphereLayer
                    .animation(DSMotion.resolved(DSMotion.ambient, reduceMotion: reduceMotion), value: isPlaying)
            } else {
                TimelineView(AnimationTimelineSchedule(minimumInterval: 1.0 / 12.0, paused: isTimelinePaused)) { context in
                    let elapsed = (!isTimelinePaused && activePhaseStartDate != nil)
                        ? max(0, context.date.timeIntervalSince(activePhaseStartDate ?? context.date))
                        : 0
                    animatedAtmosphereLayer(phase: accumulatedPhase + elapsed)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { syncPhaseClock(paused: isTimelinePaused) }
        .onChange(of: isTimelinePaused) { _, paused in syncPhaseClock(paused: paused) }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private var staticAtmosphereLayer: some View {
        GeometryReader { geo in
            let downscale: CGFloat = 0.25
            let renderWidth = max(1, geo.size.width * downscale)
            let renderHeight = max(1, geo.size.height * downscale)

            ZStack {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: renderWidth, height: renderHeight)
                        .scaleEffect(1.45)
                        .saturation(1.38)
                        .blur(radius: 18)
                        .opacity(isPlaying ? 0.92 : 0.62)
                } else {
                    fallbackColorGradient
                }
                legibilityScrim
            }
            .frame(width: renderWidth, height: renderHeight)
            .drawingGroup()
            .scaleEffect(1.0 / downscale, anchor: .center)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private var fallbackColorGradient: some View {
        ZStack {
            LinearGradient(
                colors: [
                    primaryColor.opacity(isPlaying ? 0.88 : 0.45),
                    primaryColor.opacity(isPlaying ? 0.46 : 0.22),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    primaryColor.opacity(isPlaying ? 0.55 : 0.20),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0.34),
                startRadius: 8,
                endRadius: 95
            )
        }
    }

    private var legibilityScrim: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(isPlaying ? 0.14 : 0.34), location: 0.0),
                .init(color: Color.black.opacity(isPlaying ? 0.24 : 0.44), location: 0.38),
                .init(color: Color.black.opacity(isPlaying ? 0.56 : 0.68), location: 0.68),
                .init(color: Color.black.opacity(0.84), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func syncPhaseClock(paused: Bool) {
        if paused {
            if let start = activePhaseStartDate {
                accumulatedPhase += max(0, Date.now.timeIntervalSince(start))
                activePhaseStartDate = nil
            }
        } else if activePhaseStartDate == nil {
            activePhaseStartDate = .now
        }
    }

    @ViewBuilder
    private func animatedAtmosphereLayer(phase: TimeInterval) -> some View {
        let angleA = Angle.degrees((phase * 3.6).truncatingRemainder(dividingBy: 360.0))
        let angleB = Angle.degrees((-phase * 5.0).truncatingRemainder(dividingBy: 360.0))
        let driftX = CGFloat(sin(phase * 0.32)) * (isPlaying ? 12 : 3)
        let driftY = CGFloat(cos(phase * 0.26)) * (isPlaying ? 10 : 3)
        let counterX = CGFloat(cos(phase * 0.24)) * (isPlaying ? 14 : 3)
        let counterY = CGFloat(sin(phase * 0.30)) * (isPlaying ? 11 : 3)

        GeometryReader { geo in
            let downscale: CGFloat = 0.25
            let renderWidth = max(1, geo.size.width * downscale)
            let renderHeight = max(1, geo.size.height * downscale)

            ZStack {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: renderWidth, height: renderHeight)
                        .scaleEffect(1.55)
                        .rotationEffect(angleA)
                        .offset(x: driftX * downscale, y: driftY * downscale)
                        .saturation(1.42)
                        .blur(radius: 18)
                        .opacity(isPlaying ? 0.94 : 0.62)

                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: renderWidth, height: renderHeight)
                        .scaleEffect(1.85)
                        .rotationEffect(angleB)
                        .offset(x: counterX * downscale, y: counterY * downscale)
                        .saturation(1.52)
                        .blur(radius: 22)
                        .opacity(isPlaying ? 0.50 : 0.24)
                } else {
                    fallbackColorGradient
                }

                legibilityScrim
            }
            .frame(width: renderWidth, height: renderHeight)
            .drawingGroup()
            .scaleEffect(1.0 / downscale, anchor: .center)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}
