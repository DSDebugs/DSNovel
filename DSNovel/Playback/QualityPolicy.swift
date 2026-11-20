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

    // MARK: - 解析器声明的能力（兼容代理）

    /// 解析器声明的能力里是否包含「最高档」（4 档体系为 `uhd`；兼容仍声明历史标记 `lossless` 的脚本）
    static func parserDeclaresMaxTier(_ qualities: Set<String>) -> Bool {
        qualities.contains("uhd") || qualities.contains("lossless")
    }

    // MARK: - 可见档位（4 档统一入口）

    /// 面板可见档位：统一返回 4 档（智能自适应 / 标准 / 高清 / 超清）
    static func visibleTiers(parserAvailable: Bool) -> [AudioQualityTier] {
        AudioQualityTier.visibleTiers
    }

    /// 按解析器声明的能力集合驱动可见档位（4 档体系下统一返回 4 个可见档位）
    static func visibleTiers(declaredQualities: Set<String>) -> [AudioQualityTier] {
        AudioQualityTier.visibleTiers
    }

    /// 单书独立覆写 + 全局默认合并解析：
    /// 若 `bookOverrideRaw` 非空且可解析为 `AudioQualityTier`，返回该档位，否则返回 `globalDefault`。
    static func effectiveTier(bookOverrideRaw: String?, globalDefault: AudioQualityTier) -> AudioQualityTier {
        if let raw = bookOverrideRaw, !raw.isEmpty, let parsed = AudioQualityTier(rawValue: raw) {
            return parsed
        }
        return globalDefault
    }

    /// 切档时是否应触发当前章节重载：仅对多音质书源且非本地离线返回 `true`
    static func canReloadForTierChange(sourceID: String, isLocalOffline: Bool) -> Bool {
        !isLocalOffline && sourceHasMultipleBitrates(sourceID: sourceID)
    }

    /// 兼容既有 3 参数调用签名：本地离线不重载，非离线时按内置解析参与状态判定
    static func canReloadForTierChange(
        parserQualities: Set<String>,
        builtinParserResolved: Bool,
        isLocalOffline: Bool
    ) -> Bool {
        !isLocalOffline && builtinParserResolved && !parserQualities.isEmpty
    }

    // MARK: - 档位 ↔ 链码

    /// 4 个档位在书源链与解析器链上均原生支持
    static func isNative(_ tier: AudioQualityTier, chain: QualityChain) -> Bool {
        true
    }

    /// 受支持档位（4 档体系下两条链均原生支持全部档位）
    static func nearestSupported(_ tier: AudioQualityTier, chain: QualityChain) -> AudioQualityTier {
        tier
    }

    /// 语义档位 → 指定链的码
    /// - 书源链：`.auto` Wi-Fi→`M4A_128` / 蜂窝→`M4A_24`；`.std`→`M4A_24`；`.hd`→`M4A_64`；`.uhd`→`M4A_128`
    /// - 解析器链：`.auto` Wi-Fi→`uhd` / 蜂窝→`std`；`.std`→`std`；`.hd`→`hd`；`.uhd`→`uhd`（脚本侧映射为 level 0/1/2）
    static func code(for tier: AudioQualityTier, chain: QualityChain, isOnWiFi: Bool) -> String {
        switch chain {
        case .bookSource:
            switch tier {
            case .auto: return isOnWiFi ? "M4A_128" : "M4A_24"
            case .std: return "M4A_24"
            case .hd: return "M4A_64"
            case .uhd: return "M4A_128"
            }
        case .builtinParser:
            switch tier {
            case .auto: return isOnWiFi ? "uhd" : "std"
            case .std: return "std"
            case .hd: return "hd"
            case .uhd: return "uhd"
            }
        }
    }

    /// 该档位在某条链上是否发生了回落
    static func didFallback(_ tier: AudioQualityTier, chain: QualityChain) -> Bool {
        false
    }
}
