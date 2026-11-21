import Foundation
import Network
import os

/// 全局网络可达性监视器（S9：独立于 DownloadManager，切断 PluginRuntime ↔ DownloadManager 循环依赖）
final class NetworkReachabilityMonitor: @unchecked Sendable {
    static let shared = NetworkReachabilityMonitor()

    private struct State: Sendable {
        var isOnWiFi: Bool = true
        var wifiOverride: Bool?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.dsnovel.network.reachability", qos: .utility)

    init(startMonitoring: Bool = true) {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            self?.updateIsOnWiFi(wifi)
        }
        if startMonitoring {
            pathMonitor.start(queue: monitorQueue)
        }
    }

    deinit {
        pathMonitor.cancel()
    }

    /// 当前是否处于 Wi-Fi / 有线网络环境（默认 true；若设置了 override 则优先返回 override）
    var isOnWiFi: Bool {
        state.withLock { $0.wifiOverride ?? $0.isOnWiFi }
    }

    /// 由 NWPathMonitor 或外部模块同步当前 Wi-Fi 状态
    func updateIsOnWiFi(_ value: Bool) {
        state.withLock { $0.isOnWiFi = value }
    }

    /// 供测试或调试覆盖 Wi-Fi 状态（传 nil 恢复实时监测值）
    func setWiFiOverride(_ override: Bool?) {
        state.withLock { $0.wifiOverride = override }
    }
}
