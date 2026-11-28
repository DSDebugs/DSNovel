import AVFoundation
import Foundation

/// 蓝牙/有线个人音频外设路由识别、重连防抖与音频会话重试激活（拆分自 RemoteCommandController 保持 ≤ 384 行）
extension RemoteCommandController {
    nonisolated static func isPersonalAudioOutputPort(_ port: AVAudioSession.Port) -> Bool {
        switch port {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .carAudio:
            return true
        default:
            return false
        }
    }

    nonisolated static func hasPersonalAudioOutput(in route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains { isPersonalAudioOutputPort($0.portType) }
    }

    static func currentRouteHasPersonalAudioOutput() -> Bool {
        hasPersonalAudioOutput(in: AVAudioSession.sharedInstance().currentRoute)
    }

    func processRouteChange(
        reasonRaw: UInt?,
        previousRouteHadPersonalAudio: Bool,
        onRouteUnplugged: @escaping @MainActor () -> Void,
        onRouteReconnected: (@MainActor () -> Void)?
    ) {
        guard let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
            return
        }
        switch reason {
        case .oldDeviceUnavailable:
            guard previousRouteHadPersonalAudio else { return }
            isAudioSessionConfigured = false
            onRouteUnplugged()
        case .newDeviceAvailable:
            guard Self.currentRouteHasPersonalAudioOutput() else { return }
            isAudioSessionConfigured = false
            onRouteReconnected?()
        default:
            break
        }
    }

    /// 蓝牙 A2DP 握手完成后激活音频会话；若首次激活遇握手竞态则退避 350ms 重试一次
    @discardableResult
    func ensureAudioSessionActiveWithRetry() async -> Bool {
        configureAudioSession(force: true)
        if isAudioSessionConfigured { return true }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return false }
        configureAudioSession(force: true)
        return isAudioSessionConfigured
    }
}

// SAFETY: 仅在主线程注册并在 deinit 一次性移除 NotificationCenter 令牌。
final class NotificationObserverHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func replace(with next: [NSObjectProtocol]) {
        let old = lock.withLock { () -> [NSObjectProtocol] in
            let prev = tokens
            tokens = next
            return prev
        }
        for token in old {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func removeAll() {
        replace(with: [])
    }

    deinit {
        let old = lock.withLock { () -> [NSObjectProtocol] in
            let prev = tokens
            tokens = []
            return prev
        }
        for token in old {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
