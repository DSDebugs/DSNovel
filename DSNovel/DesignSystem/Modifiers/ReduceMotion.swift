import SwiftUI

private struct DSReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var dsReduceMotion: Bool {
        get { self[DSReduceMotionKey.self] }
        set { self[DSReduceMotionKey.self] = newValue }
    }
}

struct DSReduceMotionObserverModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let appOverrideReduceMotion: Bool

    init(appOverrideReduceMotion: Bool = false) {
        self.appOverrideReduceMotion = appOverrideReduceMotion
    }

    private var effectiveReduceMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DSNOVEL_REDUCE_MOTION") {
            return true
        }
        #endif
        return systemReduceMotion || appOverrideReduceMotion
    }

    func body(content: Content) -> some View {
        content.environment(\.dsReduceMotion, effectiveReduceMotion)
    }
}

struct DSAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.dsReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    init(animation: Animation, value: V) {
        self.animation = animation
        self.value = value
    }

    func body(content: Content) -> some View {
        content.animation(Motion.resolve(animation, reduce: reduceMotion), value: value)
    }
}

extension View {
    func dsAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(DSAnimationModifier(animation: animation, value: value))
    }

    func dsSyncReduceMotion(override: Bool) -> some View {
        modifier(DSReduceMotionObserverModifier(appOverrideReduceMotion: override))
    }
}
