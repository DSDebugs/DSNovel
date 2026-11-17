import Foundation
import SwiftData

// MARK: - SwiftData 持久化实体（含「书架」与「最近播放」分离标识及书源测速字段）

@Model
final class Book {
    @Attribute(.unique) var id: String // sourceID + "::" + bookURL
    var sourceID: String
    var bookURL: String
    var title: String
    var author: String
    var cover: String
    var intro: String
    /// 是否由用户主动加入「书架」（false 表示仅保存在「最近播放」历史记录中）
    var inShelf: Bool = true
    var addedAt: Date
    var categoryID: String?
    var lastChapterID: String?
    var lastChapterTitle: String?
    /// 最后播放章节序号（1-based，0 表示未知）
    var lastChapterIndex: Int = 0
    /// 书籍总章节数（0 表示未知）
    var totalChapters: Int = 0
    var lastPositionMs: Int
    var lastPlayedAt: Date?
    var volume: Double
    var skipIntroSec: Int
    var skipOutroSec: Int
    var speed: Double
    var isPinned: Bool
    var sourceUnavailable: Bool

    init(
        id: String,
        sourceID: String,
        bookURL: String,
        title: String,
        author: String = "",
        cover: String = "",
        intro: String = "",
        inShelf: Bool = true,
        addedAt: Date = .now,
        categoryID: String? = nil,
        lastChapterID: String? = nil,
        lastChapterTitle: String? = nil,
        lastChapterIndex: Int = 0,
        totalChapters: Int = 0,
        lastPositionMs: Int = 0,
        lastPlayedAt: Date? = nil,
        volume: Double = 1.0,
        skipIntroSec: Int = 0,
        skipOutroSec: Int = 0,
        speed: Double = 1.0,
        isPinned: Bool = false,
        sourceUnavailable: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.bookURL = bookURL
        self.title = title
        self.author = author
        self.cover = cover
        self.intro = intro
        self.inShelf = inShelf
        self.addedAt = addedAt
        self.categoryID = categoryID
        self.lastChapterID = lastChapterID
        self.lastChapterTitle = lastChapterTitle
        self.lastChapterIndex = lastChapterIndex
        self.totalChapters = totalChapters
        self.lastPositionMs = lastPositionMs
        self.lastPlayedAt = lastPlayedAt
        self.volume = volume
        self.skipIntroSec = skipIntroSec
        self.skipOutroSec = skipOutroSec
        self.speed = speed
        self.isPinned = isPinned
        self.sourceUnavailable = sourceUnavailable
    }

    var bookRef: BookRef {
        BookRef(
            id: id,
            sourceID: sourceID,
            bookURL: bookURL,
            title: title,
            author: author,
            cover: cover,
            intro: intro
        )
    }

    /// 格式化收听进度位置（如 08:42）
    var formattedPositionText: String {
        guard lastPositionMs > 0 else { return "00:00" }
        let totalSec = max(0, lastPositionMs / 1000)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// 格式化最后播放时间点（支持相对时间与日期时间展示）
    var formattedLastPlayedAtText: String {
        guard let playedAt = lastPlayedAt else { return "尚未播放" }
        let interval = Date.now.timeIntervalSince(playedAt)
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else if Calendar.current.isDateInToday(playedAt) {
            let f = DateFormatter()
            f.dateFormat = "今天 HH:mm"
            return f.string(from: playedAt)
        } else if Calendar.current.isDateInYesterday(playedAt) {
            let f = DateFormatter()
            f.dateFormat = "昨天 HH:mm"
            return f.string(from: playedAt)
        } else {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            return f.string(from: playedAt)
        }
    }

    /// 汇总展示最后播放章节与进度时间
    var playbackProgressSummary: String {
        if let chapter = lastChapterTitle, !chapter.isEmpty {
            if lastPositionMs > 0 {
                return "\(chapter) · \(formattedPositionText)"
            }
            return chapter
        }
        return "尚未收听"
    }

    /// 书架/最近播放卡片第二行：演播/作者 · 书源名称（无作者时仅展示书源名称）
    func authorAndSourceSubtitle(sourceName: String) -> String {
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanAuthor.isEmpty || cleanAuthor == "未知作者" {
            return sourceName
        }
        if cleanAuthor.contains(sourceName) {
            return cleanAuthor
        }
        return "\(cleanAuthor) · \(sourceName)"
    }

    /// 书架/最近播放卡片第三行：精确展示「第 102/2059 集 · 02:45」
    var episodeAndTimeProgressText: String {
        let timePart = formattedPositionText
        if lastChapterIndex > 0 && totalChapters > 0 {
            return "第 \(lastChapterIndex)/\(totalChapters) 集 · \(timePart)"
        } else if lastChapterIndex > 0 {
            return "第 \(lastChapterIndex) 集 · \(timePart)"
        } else if let title = lastChapterTitle, !title.isEmpty {
            return "\(title) · \(timePart)"
        } else if totalChapters > 0 {
            return "共 \(totalChapters) 集 · 尚未收听"
        }
        return "尚未收听"
    }
}

@Model
final class ShelfCategory {
    @Attribute(.unique) var id: String
    var name: String
    var order: Int

    init(id: String = UUID().uuidString, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }
}

@Model
final class DownloadItem {
    @Attribute(.unique) var id: String // bookID + "::" + chapterID
    var bookID: String
    var bookTitle: String
    var chapterID: String
    var chapterTitle: String
    var sourceID: String
    var kind: String // "manual" | "precache"
    var state: String // "queued" | "downloading" | "completed" | "failed" | "paused"
    var localPath: String
    var bytes: Int64
    var retryCount: Int
    var createdAt: Date

    init(
        id: String,
        bookID: String,
        bookTitle: String,
        chapterID: String,
        chapterTitle: String,
        sourceID: String,
        kind: String = "manual",
        state: String = "queued",
        localPath: String = "",
        bytes: Int64 = 0,
        retryCount: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.sourceID = sourceID
        self.kind = kind
        self.state = state
        self.localPath = localPath
        self.bytes = bytes
        self.retryCount = retryCount
        self.createdAt = createdAt
    }
}

@Model
final class PluginRecord {
    @Attribute(.unique) var id: String
    var packageID: String
    var name: String
    var version: String
    var author: String
    var siteURL: String
    var summary: String
    var groupID: String?
    var order: Int
    var isPinned: Bool
    var isEnabled: Bool
    var searchable: Bool
    var discoverable: Bool
    var requiresLogin: Bool
    var loginURL: String
    var loggedIn: Bool
    var settingsJSON: String
    /// 书源最近一次检测状态："untested" | "healthy" | "slow" | "needAuth" | "unavailable"
    var lastCheckStatus: String = "untested"
    /// 书源最近一次检测响应延迟（毫秒），未检测时为 -1
    var lastLatencyMs: Int = -1
    /// 书源最近一次检测结果说明
    var lastCheckMessage: String = ""
    /// 书源最近一次检测时间
    var lastCheckedAt: Date? = nil

    init(
        id: String,
        packageID: String,
        name: String,
        version: String,
        author: String = "",
        siteURL: String = "",
        summary: String = "",
        groupID: String? = nil,
        order: Int = 0,
        isPinned: Bool = false,
        isEnabled: Bool = true,
        searchable: Bool = true,
        discoverable: Bool = true,
        requiresLogin: Bool = false,
        loginURL: String = "",
        loggedIn: Bool = false,
        settingsJSON: String = "{}",
        lastCheckStatus: String = "untested",
        lastLatencyMs: Int = -1,
        lastCheckMessage: String = "",
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.packageID = packageID
        self.name = name
        self.version = version
        self.author = author
        self.siteURL = siteURL
        self.summary = summary
        self.groupID = groupID
        self.order = order
        self.isPinned = isPinned
        self.isEnabled = isEnabled
        self.searchable = searchable
        self.discoverable = discoverable
        self.requiresLogin = requiresLogin
        self.loginURL = loginURL
        self.loggedIn = loggedIn
        self.settingsJSON = settingsJSON
        self.lastCheckStatus = lastCheckStatus
        self.lastLatencyMs = lastLatencyMs
        self.lastCheckMessage = lastCheckMessage
        self.lastCheckedAt = lastCheckedAt
    }

    var healthState: SourceHealthState {
        SourceHealthState(rawValue: lastCheckStatus) ?? .untested
    }

    var isHealthyOrSlow: Bool {
        lastCheckStatus == SourceHealthState.healthy.rawValue || lastCheckStatus == SourceHealthState.slow.rawValue
    }

    var latencyBadgeText: String {
        switch healthState {
        case .untested:
            return "检测"
        case .healthy, .slow:
            return lastLatencyMs > 0 ? "\(lastLatencyMs)ms" : "可用"
        case .needAuth:
            return "需验证"
        case .unavailable:
            return "不可用"
        }
    }

    /// 用于并发搜索与智能排序的优先级分值（越小越优先）
    var searchPriorityScore: Int {
        var score = order
        if isPinned { score -= 10000 }
        switch healthState {
        case .healthy:
            score -= 5000
            if lastLatencyMs > 0 {
                score += min(lastLatencyMs / 10, 400)
            }
        case .slow:
            score -= 1000
            if lastLatencyMs > 0 {
                score += min(lastLatencyMs / 10, 800)
            }
        case .untested:
            break
        case .needAuth:
            score += 3000
        case .unavailable:
            score += 8000
        }
        return score
    }
}

@Model
final class PluginGroup {
    @Attribute(.unique) var id: String
    var name: String
    var order: Int
    var isCollapsed: Bool

    init(id: String = UUID().uuidString, name: String, order: Int, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.order = order
        self.isCollapsed = isCollapsed
    }
}

@Model
final class SearchHistory {
    @Attribute(.unique) var keyword: String
    var updatedAt: Date

    init(keyword: String, updatedAt: Date = .now) {
        self.keyword = keyword
        self.updatedAt = updatedAt
    }
}

/// 内置解析脚本记录（仅用于「书源管理 → 内置解析」展示与管理）
///
/// 注意：解析链路不读这张表 —— `BuiltinParserRuntime` 直接扫盘读取
/// `Application Support/BuiltinParsers/<parserID>/`，因此即使 SwiftData 记录缺失，
/// 已安装的解析器依然可用（两者由安装/删除流程同步写入）。
@Model
final class BuiltinParserRecord {
    @Attribute(.unique) var id: String
    var name: String
    var version: String
    var author: String
    var summary: String
    /// 目标书源 host（逗号分隔）
    var targetHosts: String
    /// 目标书源 sourceID（逗号分隔，兜底匹配用）
    var targetSourceIDs: String
    var fileName: String
    var sha256: String
    var sizeBytes: Int
    var importedAt: Date
    var isEnabled: Bool
    /// "untested" | "ok" | "failed"
    var lastCheckStatus: String = "untested"
    var lastCheckMessage: String = ""
    var lastLatencyMs: Int = -1
    var lastCheckedAt: Date? = nil
    var lastAccountNickname: String = ""
    var lastAccountExpireAt: String = ""

    init(
        id: String,
        name: String,
        version: String,
        author: String = "",
        summary: String = "",
        targetHosts: String = "",
        targetSourceIDs: String = "",
        fileName: String = "",
        sha256: String = "",
        sizeBytes: Int = 0,
        importedAt: Date = .now,
        isEnabled: Bool = true,
        lastCheckStatus: String = "untested",
        lastCheckMessage: String = "",
        lastLatencyMs: Int = -1,
        lastCheckedAt: Date? = nil,
        lastAccountNickname: String = "",
        lastAccountExpireAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.targetHosts = targetHosts
        self.targetSourceIDs = targetSourceIDs
        self.fileName = fileName
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.importedAt = importedAt
        self.isEnabled = isEnabled
        self.lastCheckStatus = lastCheckStatus
        self.lastCheckMessage = lastCheckMessage
        self.lastLatencyMs = lastLatencyMs
        self.lastCheckedAt = lastCheckedAt
        self.lastAccountNickname = lastAccountNickname
        self.lastAccountExpireAt = lastAccountExpireAt
    }

    /// 由磁盘扫描结果同步展示字段（不改动用户开关与自检结果）
    func applyDiskState(_ parser: InstalledBuiltinParser) {
        name = parser.meta.name
        version = parser.meta.version
        author = parser.meta.author
        summary = parser.meta.summary
        targetHosts = parser.meta.targets.hosts.joined(separator: ",")
        targetSourceIDs = parser.meta.targets.sourceIDs.joined(separator: ",")
        fileName = parser.fileName
        sha256 = parser.sha256
        sizeBytes = parser.sizeBytes
        importedAt = parser.importedAt
    }

    var targetHostList: [String] {
        targetHosts.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var targetSourceIDList: [String] {
        targetSourceIDs.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var formattedSize: String {
        if sizeBytes <= 0 { return "—" }
        if sizeBytes < 1024 { return "\(sizeBytes) B" }
        return String(format: "%.1f KB", Double(sizeBytes) / 1024.0)
    }
}

// MARK: - 轻量值类型 DTO 与路由枚举

/// 底部主导航标签：固定顺序为「发现 · 搜索 · 书架 · 设置」
enum AppTab: Int, CaseIterable, Hashable {
    case discover = 0
    case search = 1
    case shelf = 2
    case settings = 3

    var title: String {
        switch self {
        case .discover: return "发现"
        case .search: return "搜索"
        case .shelf: return "书架"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .discover: return "safari"
        case .search: return "magnifyingglass"
        case .shelf: return "books.vertical"
        case .settings: return "gearshape"
        }
    }
}

/// 书架页顶部三栏切换：「书架 · 最近播放 · 已下载」（已完整移除书签）
enum ShelfSectionMode: String, CaseIterable, Identifiable {
    case shelf = "shelf"
    case recent = "recent"
    case downloaded = "downloaded"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .shelf: return "书架"
        case .recent: return "最近播放"
        case .downloaded: return "已下载"
        }
    }
}

enum Route: Hashable {
    case book(BookRef, alternatives: [BookRef] = [])
    case pluginManager
    case downloadManager
    case skipSettings
}

enum SourceHealthState: String, Codable, CaseIterable, Sendable {
    case untested
    case healthy
    case slow
    case needAuth
    case unavailable

    var displayTitle: String {
        switch self {
        case .untested: return "未检测"
        case .healthy: return "正常"
        case .slow: return "响应较慢"
        case .needAuth: return "需登录/验证"
        case .unavailable: return "不可用"
        }
    }
}

struct SourceHealthCheckResult: Hashable, Sendable {
    let sourceID: String
    let state: SourceHealthState
    let latencyMs: Int
    let message: String
    let sampleCount: Int
    let checkedAt: Date
}

struct BookRef: Identifiable, Hashable, Codable, Sendable {
    var id: String // sourceID + "::" + bookURL
    var sourceID: String
    var bookURL: String
    var title: String
    var author: String
    var cover: String
    var intro: String
    var chapterCount: Int

    init(
        id: String? = nil,
        sourceID: String,
        bookURL: String,
        title: String,
        author: String = "",
        cover: String = "",
        intro: String = "",
        chapterCount: Int = 0
    ) {
        self.id = id ?? "\(sourceID)::\(bookURL)"
        self.sourceID = sourceID
        self.bookURL = bookURL
        self.title = title
        self.author = author
        self.cover = cover
        self.intro = intro
        self.chapterCount = chapterCount
    }

    /// 发现页网格与列表卡片的智能副标题：优先展示「共 X 章 / X 集」，其次展示作者或状态简介，彻底消除生硬的「未知作者」
    var discoverSubtitle: String {
        if chapterCount > 0 {
            return "共 \(chapterCount) 章"
        }
        let combined = [intro, author].joined(separator: " ")
        if let range = combined.range(of: #"共\s*\d+\s*[章集回讲]"#, options: .regularExpression) {
            return String(combined[range]).replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "共", with: "共 ")
                .replacingOccurrences(of: "章", with: " 章")
                .replacingOccurrences(of: "集", with: " 集")
                .replacingOccurrences(of: "回", with: " 回")
                .replacingOccurrences(of: "讲", with: " 讲")
        }
        if let range = combined.range(of: #"\d+\s*[章集回讲]"#, options: .regularExpression) {
            let numPart = String(combined[range]).trimmingCharacters(in: .whitespaces)
            return "共 \(numPart)"
        }
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanAuthor.isEmpty {
            return cleanAuthor
        }
        let cleanIntro = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIntro.isEmpty {
            return cleanIntro
        }
        return "有声读物"
    }

    var normalizedKey: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanAuthor = author
            .components(separatedBy: "·").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if cleanAuthor.isEmpty {
            return cleanTitle
        }
        return "\(cleanTitle)|\(cleanAuthor)"
    }
}

struct ChapterDTO: Identifiable, Hashable, Codable, Sendable {
    var id: String // url
    var index: Int
    var title: String
    var url: String
    var durationSec: Int?

    init(index: Int, title: String, url: String, durationSec: Int? = nil) {
        self.id = url
        self.index = index
        self.title = title
        self.url = url
        self.durationSec = durationSec
    }
}

extension ChapterDTO {
    /// 插件返回的章节时长单位并不统一（有的给秒，有的给毫秒）。
    /// 单章超过 10 小时(36000 秒)几乎不可能，此时按毫秒折算；仍不合理则视为未知。
    /// 仅用于列表展示与起播前的占位时长，真实时长始终以 AVPlayerItem 为准。
    var normalizedDurationSec: Int? {
        guard let raw = durationSec, raw > 0 else { return nil }
        if raw <= 36_000 { return raw }
        let asSeconds = raw / 1000
        return (1...36_000).contains(asSeconds) ? asSeconds : nil
    }

    var hintDurationSec: Double {
        Double(normalizedDurationSec ?? 0)
    }
}

struct BookDetailDTO: Hashable, Codable, Sendable {
    var title: String
    var author: String
    var coverURL: String
    var intro: String
    var status: String
    var chapters: [ChapterDTO]
}

struct DiscoverTabDTO: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(title)_\(url)" }
    var title: String
    var url: String
}

struct DiscoverSectionDTO: Identifiable, Hashable, Codable, Sendable {
    var id: String { title }
    var title: String
    var tabs: [DiscoverTabDTO]
}

struct DiscoverPageDTO: Hashable, Codable, Sendable {
    var books: [BookRef]
    var nextPageURL: String?
    var totalPage: Int?
}

struct MergedSearchItem: Identifiable, Hashable, Sendable {
    var id: String { primary.id }
    var primary: BookRef
    var alternatives: [BookRef]
}

enum StreamKind: String, Codable, Sendable {
    case onDemand
    case hls
    case live
}

struct PlayStreamInfo: Hashable, Codable, Sendable {
    var url: String
    var headers: [String: String]
    var kind: StreamKind
    /// 该地址的来源："" = 书源自己解析；"builtinParser" = 内置解析
    var resolvedBy: String = ""
    /// 直链有效期（内置解析会给出；过期后需要重新解析）
    var expiresAt: Date? = nil
}

struct SourceConfigItem: Identifiable, Hashable, Codable, Sendable {
    var id: String { key }
    var key: String
    var title: String
    var defaultValue: String
    var summary: String
}
