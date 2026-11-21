import SwiftUI

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
        return state == .playing ? 1.0 : 0.86
    }
}

/// 沉浸式流体极光与声学呼吸背景：
/// - 播放态：9 点 3×3 MeshGradient 10fps 轻流 + 0.25× 离屏降采样放大 + 常规 alpha 径向聚光灯；
/// - 暂停/遮挡/退后台：TimelineView 自动休眠停止帧驱动；
/// - 低电量/高热态：动态监听系统通知自动降级为静态渐变。
struct PlayerAmbientBackground: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    let primaryColor: Color
    let isPlaying: Bool
    let isObscured: Bool

    init(primaryColor: Color, isPlaying: Bool, isObscured: Bool = false) {
        self.primaryColor = primaryColor
        self.isPlaying = isPlaying
        self.isObscured = isObscured
    }

    var body: some View {
        let useStatic = PlayerAmbientFallbackPolicy.shouldUseStaticGradient(
            isLowPowerMode: isLowPowerMode,
            reduceMotion: reduceMotion,
            thermalState: thermalState
        )
        let isTimelinePaused = !isPlaying || isObscured || scenePhase != .active

        ZStack {
            Color.dsSurfaceBase

            if useStatic {
                staticAtmosphereLayer
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: isTimelinePaused)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    animatedAtmosphereLayer(time: t)
                }
            }
        }
        .dsAnimation(Motion.ambient, value: isPlaying)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private var staticAtmosphereLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    primaryColor.opacity(isPlaying ? 0.92 : 0.45),
                    primaryColor.opacity(isPlaying ? 0.48 : 0.20),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.dsAccent.opacity(isPlaying ? 0.30 : 0.08),
                    primaryColor.opacity(isPlaying ? 0.45 : 0.15),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0.34),
                startRadius: 20,
                endRadius: isPlaying ? 340 : 190
            )
        }
    }

    @ViewBuilder
    private func animatedAtmosphereLayer(time t: TimeInterval) -> some View {
        let speedFactor = isPlaying ? 1.0 : 0.22
        let phase = t * speedFactor
        let dx1 = Float(sin(phase * 0.75) * (isPlaying ? 0.18 : 0.05))
        let dy1 = Float(cos(phase * 0.62) * (isPlaying ? 0.16 : 0.04))
        let dx2 = Float(cos(phase * 0.52) * (isPlaying ? 0.15 : 0.04))
        let dy2 = Float(sin(phase * 0.85) * (isPlaying ? 0.14 : 0.04))
        let pulse = 0.5 + 0.5 * sin(t * (isPlaying ? 2.1 : 0.6))

        GeometryReader { geo in
            let downscale: CGFloat = 0.25
            let renderWidth = max(1, geo.size.width * downscale)
            let renderHeight = max(1, geo.size.height * downscale)

            ZStack {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0.0, 0.0], [0.5 + dx2 * 0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.45 + dy2 * 0.4], [0.5 + dx1, 0.38 + dy1], [1.0, 0.5 - dy1 * 0.4],
                        [0.0, 1.0], [0.5 - dx1 * 0.4, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        primaryColor.opacity(isPlaying ? 0.95 : 0.42),
                        Color.dsAccent.opacity(isPlaying ? 0.52 : 0.16),
                        primaryColor.opacity(isPlaying ? 0.78 : 0.30),
                        primaryColor.opacity(isPlaying ? 0.82 : 0.32),
                        Color.dsAccent.opacity(isPlaying ? 0.44 : 0.12),
                        primaryColor.opacity(isPlaying ? 0.64 : 0.24),
                        Color.black.opacity(0.92),
                        primaryColor.opacity(isPlaying ? 0.35 : 0.12),
                        Color.black
                    ]
                )

                // 封面核心区声学呼吸光晕：播放时随节拍舒展发亮，暂停时明显收敛暗化（常规 alpha 混合）
                RadialGradient(
                    colors: [
                        Color.dsAccent.opacity(isPlaying ? (0.34 + 0.12 * pulse) : 0.06),
                        primaryColor.opacity(isPlaying ? (0.55 + 0.10 * pulse) : 0.16),
                        Color.clear
                    ],
                    center: .init(
                        x: 0.5 + Double(dx1) * 0.35,
                        y: 0.33 + Double(dy1) * 0.25
                    ),
                    startRadius: (isPlaying ? 16 : 8) * downscale,
                    endRadius: (isPlaying ? (310 + 45 * pulse) : 165) * downscale
                )

                // 底部控制区柔和暗角衬底，确保进度条与文字高对比度清晰可读
                LinearGradient(
                    colors: [
                        Color.black.opacity(isPlaying ? 0.08 : 0.32),
                        Color.black.opacity(isPlaying ? 0.36 : 0.58),
                        Color.black.opacity(0.84)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: renderWidth, height: renderHeight)
            .drawingGroup()
            .scaleEffect(1.0 / downscale, anchor: .center)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}
