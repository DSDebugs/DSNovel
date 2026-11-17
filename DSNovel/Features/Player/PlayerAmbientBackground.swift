import SwiftUI

enum PlayerAmbientFallbackPolicy {
    static func shouldUseStaticGradient(
        isLowPowerMode: Bool,
        reduceMotion: Bool,
        exceededFrameBudget: Bool = false
    ) -> Bool {
        isLowPowerMode || reduceMotion || exceededFrameBudget
    }

    static func coverScale(for state: PlaybackState, isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return 1.0 }
        if isPressed { return 0.96 }
        return state == .playing ? 1.0 : 0.86
    }
}

struct PlayerAmbientBackground: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    let primaryColor: Color
    let isPlaying: Bool

    init(primaryColor: Color, isPlaying: Bool) {
        self.primaryColor = primaryColor
        self.isPlaying = isPlaying
    }

    var body: some View {
        let useStatic = PlayerAmbientFallbackPolicy.shouldUseStaticGradient(
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            reduceMotion: reduceMotion
        )
        Group {
            if useStatic || !isPlaying {
                LinearGradient(
                    colors: [primaryColor, Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let dx = Float(sin(t / 6.0) * 0.08)
                    let dy = Float(cos(t / 6.0) * 0.08)
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: [
                            [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                            [0.0, 0.5], [0.5 + dx, 0.5 + dy], [1.0, 0.5],
                            [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                        ],
                        colors: [
                            primaryColor, primaryColor.opacity(0.85), Color.black,
                            primaryColor.opacity(0.75), primaryColor.opacity(0.45), Color.black,
                            Color.black, Color.black, Color.black
                        ]
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}
