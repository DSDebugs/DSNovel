import SwiftUI
import UIKit

enum DSHapticKind: String, CaseIterable, Equatable, Sendable {
    case selection
    case playPause
    case chapterSwitch
    case speedIncrease
    case speedDecrease
    case scrubberMinuteTick
    case success
    case error
    case warning
}

final class DSHapticPolicy: @unchecked Sendable {
    static let shared = DSHapticPolicy()

    private var lastTriggeredAt: [DSHapticKind: TimeInterval] = [:]
    private let lock = NSLock()

    init() {}

    func shouldTrigger(
        _ kind: DSHapticKind,
        hapticsEnabled: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard hapticsEnabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        let minInterval: TimeInterval
        switch kind {
        case .error:
            minInterval = 3.0
        case .scrubberMinuteTick:
            minInterval = 0.15
        default:
            minInterval = 0.0
        }
        if minInterval > 0, let last = lastTriggeredAt[kind], (now - last) < minInterval {
            return false
        }
        lastTriggeredAt[kind] = now
        return true
    }

    func reset() {
        lock.lock()
        lastTriggeredAt.removeAll()
        lock.unlock()
    }

    @MainActor
    static func fire(_ kind: DSHapticKind) {
        let enabled = AppSettingsStore.shared.hapticsEnabled
        guard shared.shouldTrigger(kind, hapticsEnabled: enabled) else { return }
        switch kind {
        case .selection, .scrubberMinuteTick:
            UISelectionFeedbackGenerator().selectionChanged()
        case .playPause:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .chapterSwitch, .speedIncrease, .speedDecrease:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

struct DSHapticModifier<T: Equatable>: ViewModifier {
    let kind: DSHapticKind
    let trigger: T

    init(kind: DSHapticKind, trigger: T) {
        self.kind = kind
        self.trigger = trigger
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, _ in
                DSHapticPolicy.fire(kind)
            }
    }
}

extension View {
    func dsHaptic<T: Equatable>(_ kind: DSHapticKind, trigger: T) -> some View {
        modifier(DSHapticModifier(kind: kind, trigger: trigger))
    }
}
