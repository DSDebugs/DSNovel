import Foundation

/// 音频质量档位（与内置解析脚本 4 档声明 auto / std / hd / uhd 严格对齐）
public enum AudioQualityTier: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case saver
    case standard
    case high

    public var id: String { rawValue }

    /// 对应内置解析脚本的新版档位标识（auto / std / hd / uhd）
    /// 根据是否已解锁内置解析返回开放的音质档位（未解锁隐藏超清）
    public static func availableTiers(builtinParserUnlocked: Bool) -> [AudioQualityTier] {
        builtinParserUnlocked ? [.auto, .saver, .standard, .high] : [.auto, .saver, .standard]
    }

    /// 将自适应档位按当前网络与内置解析解锁状态细化为物理档位：
    /// - 已解锁：Wi-Fi → 超清(.high / uhd)，蜂窝 → 标清(.saver / std)
    /// - 未解锁：Wi-Fi → 高清(.standard / hd)，蜂窝 → 标清(.saver / std)，且 .high 自动钳制为 .standard
    public func resolved(isOnWiFi: Bool, allowUltraHigh: Bool = true) -> AudioQualityTier {
        if self == .auto {
            return isOnWiFi ? (allowUltraHigh ? .high : .standard) : .saver
        }
        if self == .high && !allowUltraHigh {
            return .standard
        }
        return self
    }

    public func badgeLabel(allowUltraHigh: Bool) -> String {
        if self == .auto {
            return allowUltraHigh ? "Wi-Fi 超清 · 蜂窝标准" : "Wi-Fi 高清 · 蜂窝标准"
        }
        if self == .high && !allowUltraHigh {
            return AudioQualityTier.standard.badgeLabel(allowUltraHigh: false)
        }
        return badgeLabel
    }

    public var parserToken: String {
        switch self {
        case .auto: return "auto"
        case .saver: return "std"
        case .standard: return "hd"
        case .high: return "uhd"
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "自适应"
        case .saver: return "标准"
        case .standard: return "高清"
        case .high: return "超清"
        }
    }

    public var badgeLabel: String {
        switch self {
        case .auto: return "Wi-Fi 超清 · 蜂窝标准"
        case .saver: return "标准"
        case .standard: return "高清"
        case .high: return "超清"
        }
    }

    /// 根据音轨实测码率（kbps）映射为简洁中文档位（供固定音质书源与离线文件展示）
    public static func fromBitrateKbps(_ kbps: Int) -> AudioQualityTier {
        if kbps >= 90 { return .high }
        if kbps >= 42 { return .standard }
        if kbps > 0 { return .saver }
        return .standard
    }

    /// 兼容解析器新旧档位标识（auto / std / hd / uhd / saver / standard / high / lossless / M4A_* / FLAC_* / ATMOS_*）
    public static func fromParserToken(_ raw: String) -> AudioQualityTier? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = AudioQualityTier(rawValue: key) { return exact }
        switch key {
        case "std", "m4a_24", "m4a_32": return .saver
        case "hd", "m4a_48", "m4a_64": return .standard
        case "uhd", "m4a_96", "m4a_128", "lossless", "ultra", "flac_16", "flac_24", "atmos", "atmos_24": return .high
        default: return nil
        }
    }
}

/// 书源权限模式（Q5 决策固化）
public enum SourcePermissionMode: String, Codable, Sendable, Equatable {
    /// 声明了 hosts 白名单，按声明域严格收敛
    case declaredHosts
    /// 第三方书源未声明 hosts，导入时经用户弹窗确认后兼容放行（仍受宿主 SSRF 与 302 Cookie 剥离约束）
    case compatApproved
}

/// 单本跳过片头/片尾配置（规则 #17：仅单本生效，无全局默认跳过）
public struct SkipConfigDTO: Codable, Sendable, Equatable, Hashable {
    public var introSeconds: Int {
        didSet {
            let clamped = max(0, min(600, introSeconds))
            if introSeconds != clamped { introSeconds = clamped }
        }
    }
    public var outroSeconds: Int {
        didSet {
            let clamped = max(0, min(600, outroSeconds))
            if outroSeconds != clamped { outroSeconds = clamped }
        }
    }

    public init(introSeconds: Int = 0, outroSeconds: Int = 0) {
        self.introSeconds = max(0, min(600, introSeconds))
        self.outroSeconds = max(0, min(600, outroSeconds))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let intro = (try? c.decode(Int.self, forKey: .introSeconds)) ?? 0
        let outro = (try? c.decode(Int.self, forKey: .outroSeconds)) ?? 0
        self.init(introSeconds: intro, outroSeconds: outro)
    }

    public var isEnabled: Bool { introSeconds > 0 || outroSeconds > 0 }
}

/// 书籍摘要值对象（零 SwiftData 耦合，跨线程 Sendable）
public struct BookSummaryDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let sourceID: String
    public let sourceName: String
    public let bookURL: String
    public let title: String
    public let author: String
    public let narrator: String
    public let coverURL: String
    public let intro: String
    public let latestChapter: String
    public let statusText: String
    public let totalChapters: Int

    public init(
        id: String,
        sourceID: String,
        sourceName: String = "",
        bookURL: String,
        title: String,
        author: String = "",
        narrator: String = "",
        coverURL: String = "",
        intro: String = "",
        latestChapter: String = "",
        statusText: String = "",
        totalChapters: Int = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.bookURL = bookURL
        self.title = title
        self.author = author
        self.narrator = narrator
        self.coverURL = coverURL
        self.intro = intro
        self.latestChapter = latestChapter
        self.statusText = statusText
        self.totalChapters = max(0, totalChapters)
    }
}

/// 章节值对象
public struct ChapterDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let index: Int
    public let title: String
    public let url: String
    public let durationMs: Int
    public let isVIP: Bool

    public init(
        id: String,
        index: Int,
        title: String,
        url: String,
        durationMs: Int = 0,
        isVIP: Bool = false
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.url = url
        self.durationMs = max(0, durationMs)
        self.isVIP = isVIP
    }
}

/// 书籍详情值对象
public struct BookDetailDTO: Codable, Sendable, Equatable {
    public let summary: BookSummaryDTO
    public let chapters: [ChapterDTO]
    public let tags: [String]
    public let updateTime: String

    public init(
        summary: BookSummaryDTO,
        chapters: [ChapterDTO],
        tags: [String] = [],
        updateTime: String = ""
    ) {
        self.summary = summary
        self.chapters = chapters
        self.tags = tags
        self.updateTime = updateTime
    }
}

/// 音频解析结果
public struct AudioStreamDTO: Codable, Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public let qualityTier: AudioQualityTier
    public let bitrateKbps: Int?
    public let isHLS: Bool
    public let isTrial: Bool
    public let isCappedFallback: Bool
    public let mimeType: String?
    public let resolvedAt: Date

    public init(
        url: URL,
        headers: [String: String] = [:],
        qualityTier: AudioQualityTier = .standard,
        bitrateKbps: Int? = nil,
        isHLS: Bool = false,
        isTrial: Bool = false,
        isCappedFallback: Bool = false,
        mimeType: String? = nil,
        resolvedAt: Date = Date()
    ) {
        self.url = url
        self.headers = headers
        self.qualityTier = qualityTier
        self.bitrateKbps = bitrateKbps
        self.isHLS = isHLS
        self.isTrial = isTrial
        self.isCappedFallback = isCappedFallback
        self.mimeType = mimeType
        self.resolvedAt = resolvedAt
    }

    public var displayBitrateBadge: String {
        if qualityTier == .auto, let kbps = bitrateKbps, kbps > 0 {
            return AudioQualityTier.fromBitrateKbps(kbps).displayName
        }
        return qualityTier.displayName
    }
}

/// 发现分类 Tab（支持 1 级 / 2 级 / 3 级层级：groupTitle → subGroupTitle → title）
public struct DiscoverCategoryDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let groupTitle: String
    public let subGroupTitle: String

    public init(id: String, title: String, url: String, groupTitle: String = "", subGroupTitle: String = "") {
        self.id = id
        self.title = title
        self.url = url
        self.groupTitle = groupTitle
        self.subGroupTitle = subGroupTitle
    }

    private enum CodingKeys: String, CodingKey { case id, title, url, groupTitle, subGroupTitle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        groupTitle = try c.decodeIfPresent(String.self, forKey: .groupTitle) ?? ""
        subGroupTitle = try c.decodeIfPresent(String.self, forKey: .subGroupTitle) ?? ""
    }
}

/// 书源元数据
public struct SourceMetaDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let author: String
    public let summary: String
    public let declaredHosts: [String]
    public let permissionMode: SourcePermissionMode
    public let methods: [String]
    public let isEnabled: Bool
    public let isPinned: Bool
    public let groupName: String
    public let sortOrder: Int
    public let loginURL: String?

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        author: String = "",
        summary: String = "",
        declaredHosts: [String] = [],
        permissionMode: SourcePermissionMode = .declaredHosts,
        methods: [String] = [],
        isEnabled: Bool = true,
        isPinned: Bool = false,
        groupName: String = "默认分组",
        sortOrder: Int = 0,
        loginURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.declaredHosts = declaredHosts
        self.permissionMode = permissionMode
        self.methods = methods
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.groupName = groupName
        self.sortOrder = sortOrder
        self.loginURL = loginURL
    }

    public var hasDeclaredHosts: Bool { !declaredHosts.isEmpty }
}
