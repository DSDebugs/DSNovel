import SwiftUI
import UIKit

@MainActor
@Observable
final class ToastManager {
    static let shared = ToastManager()

    var currentMessage: String? {
        BannerCenter.shared.currentBanner?.message
    }

    init() {}

    func show(_ message: String, duration: TimeInterval = 2.5) {
        BannerCenter.shared.show(message, kind: .info)
    }

    func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        DSHapticPolicy.fire(.chapterSwitch)
    }
}

