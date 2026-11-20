import SwiftUI

struct DSCardButtonStyle: ButtonStyle {
    @Environment(\.dsReduceMotion) private var reduceMotion

    init() {}

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(Motion.resolve(Motion.snappy, reduce: reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == DSCardButtonStyle {
    static var dsCard: DSCardButtonStyle { DSCardButtonStyle() }
}
