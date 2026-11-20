import SwiftUI

enum Motion {
    static let snappy: Animation = .snappy(duration: 0.28)
    static let smooth: Animation = .smooth(duration: 0.38)
    static let bouncy: Animation = .bouncy(duration: 0.45, extraBounce: 0.12)
    static let ambient: Animation = .easeInOut(duration: 0.6)
    static let quick: Animation = .easeOut(duration: 0.15)
    static let follow: Animation = .interactiveSpring(response: 0.28, dampingFraction: 0.86)

    static func resolve(_ animation: Animation, reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : animation
    }
}
