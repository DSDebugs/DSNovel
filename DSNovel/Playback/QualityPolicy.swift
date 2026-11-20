import Foundation

/// 音质**链**（两个解析通道）：书源链走官方客户端接口，解析器链走内置解析脚本
enum QualityChain: Sendable {
    case bookSource
    case builtinParser
}

/// 统一音质档位策略层（唯一映射入口）
enum QualityPolicy {

    // MARK: - 能力判定

    /// 具备原生多码率能力的书源（内置包 v5.6.5 起：仅喜马拉雅）
    static let multiBitrateSourceIDs: Set<String> = ["6e2b9c4d8a1f4d37b5c0e73a9f1d2b64"]

    static func sourceHasMultipleBitrates(sourceID: String) -> Bool {
        multiBitrateSourceIDs.contains(sourceID)
    }

    // MARK: - 系统托管的解析器配置键

    /// 这些键由 App/脚本内部管理，永不在解析器界面渲染。
    static let managedParserConfigKeys: Set<String> = [
        "quality", "cookieSource", "allowRemoteCookie", "remoteCookieURL", "linkTTL"
    ]

    // MARK: - 解析器声明的能力（② 能力声明驱动 UI）

    /// 解析器是否声明了「无损·最高音质」能力（脚本 `meta.qualities` 含 `lossless`）
    static func parserDeclaresLossless(_ qualities: Set<String>) -> Bool {
        qualities.contains("lossless")
    }

    // MARK: - 可见档位（D-12：唯一权威入口）

    /// 面板可见档位：解析器参与解析且声明无损能力时多出「无损·最高音质」
    static func visibleTiers(parserAvailable: Bool) -> [AudioQualityTier] {
        parserAvailable ? [.auto, .dataSaver, .standard, .high, .losslessHQ] : AudioQualityTier.visibleTiers
    }

    /// 按解析器声明的能力集合驱动可见档位（含 lossless 时追加「无损 · 最高音质」）
    static func visibleTiers(declaredQualities: Set<String>) -> [AudioQualityTier] {
        var tiers: [AudioQualityTier] = [.auto, .dataSaver, .standard, .high]
        if declaredQualities.contains("lossless") {
            tiers.append(.losslessHQ)
        }
        return tiers
    }

    /// 切档时是否应触发当前章节重载（本地离线不重载；内置解析参与且声明了能力集合时允许重载）
    static func canReloadForTierChange(
        parserQualities: Set<String>,
        builtinParserResolved: Bool,
        isLocalOffline: Bool
    ) -> Bool {
        !isLocalOffline && builtinParserResolved && !parserQualities.isEmpty
    }

    // MARK: - 档位 ↔ 链码

    /// 该链是否原生支持此档位（`losslessHQ` 只有解析器链支持）
    static func isNative(_ tier: AudioQualityTier, chain: QualityChain) -> Bool {
        let t = tier.normalizedForSelection
        switch chain {
        case .bookSource:
            return [.auto, .dataSaver, .standard, .high].contains(t)
        case .builtinParser:
            return [.auto, .dataSaver, .standard, .high, .losslessHQ].contains(t)
        }
    }

    /// 该链不支持所选档位时：取最接近档，并列时向上
    static func nearestSupported(_ tier: AudioQualityTier, chain: QualityChain) -> AudioQualityTier {
        let t = tier.normalizedForSelection
        if isNative(t, chain: chain) { return t }
        return .high
    }

    /// 语义档位 → 指定链的码
    /// 修复 M-04：解析器链 `.auto` 档位与书源链保持一致，按网络类型区分（Wi-Fi 走 high，蜂窝走 standard）
    static func code(for tier: AudioQualityTier, chain: QualityChain, isOnWiFi: Bool) -> String {
        let effective = nearestSupported(tier, chain: chain)
        switch chain {
        case .bookSource:
            switch effective {
            case .auto: return isOnWiFi ? "M4A_128" : "M4A_64"
            case .dataSaver: return "M4A_24"
            case .standard: return "M4A_64"
            case .high, .lossless, .losslessHQ: return "M4A_128"
            }
        case .builtinParser:
            switch effective {
            case .auto: return isOnWiFi ? "high" : "standard"
            case .dataSaver: return "saver"
            case .standard: return "standard"
            case .high, .lossless: return "high"
            case .losslessHQ: return "lossless"
            }
        }
    }

    /// 该档位在某条链上是否发生了回落（用于日志与实测徽标提示）
    static func didFallback(_ tier: AudioQualityTier, chain: QualityChain) -> Bool {
        nearestSupported(tier, chain: chain) != tier.normalizedForSelection
    }
}
