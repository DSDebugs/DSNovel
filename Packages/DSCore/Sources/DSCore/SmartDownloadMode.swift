import Foundation

/// 智能下载网络与音质策略（自动：流量标准/Wi-Fi超清；手动：不限网络按所选音质；Wi-Fi：仅 Wi-Fi 下载）
public enum SmartDownloadMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case manual
    case wifiOnly

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .auto: return "自动"
        case .manual: return "手动"
        case .wifiOnly: return "Wi-Fi"
        }
    }

    /// 结合当前网络状态与内置解析超清解锁状态，解析本次下载请求的目标音质
    public func resolvedDownloadQuality(
        selectedQuality: AudioQualityTier,
        isOnWiFi: Bool,
        allowUltraHigh: Bool
    ) -> AudioQualityTier {
        switch self {
        case .auto:
            return isOnWiFi ? (allowUltraHigh ? .high : .standard) : .saver
        case .manual:
            return selectedQuality.resolved(isOnWiFi: isOnWiFi, allowUltraHigh: allowUltraHigh)
        case .wifiOnly:
            return selectedQuality.resolved(isOnWiFi: true, allowUltraHigh: allowUltraHigh)
        }
    }
}
