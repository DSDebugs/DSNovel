import SwiftUI
import UIKit

@MainActor
@Observable
final class ToastManager {
    static let shared = ToastManager()

    private(set) var currentMessage: String?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, duration: TimeInterval = 2.0) {
        dismissTask?.cancel()
        currentMessage = message
        triggerHaptic(.light)
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled {
                currentMessage = nil
            }
        }
    }

    func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let enabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

/// 轻量底部纯色圆角提示（不使用玻璃，符合 5.8 节规范）
struct ToastOverlayView: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(uiColor: .label))
                )
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: message)
                .allowsHitTesting(false)
        }
    }
}
