import Foundation
import SwiftData

// MARK: - SwiftData 持久化实体

@Model
final class Book {
    @Attribute(.unique) var id: String // sourceID + "::" + bookURL
    var sourceID: String
    var bookURL: String
    var title: String
    var author: String
    var cover: String
    var intro: String
    /// 是否由用户主动加入「书架」（false 表示仅保存在「播放历史」中）
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
    var skipEnabled: Bool = false
    var skipIntroSec: Int
    var skipOutroSec: Int
    var speed: Double
    var isPinned: Bool
    var sourceUnavailable: Bool
    /// T3-03 新增轻量迁移字段（均带默认值）
    var hasUpdate: Bool = false
    var latestChapterCount: Int = 0
    var updateCheckedAt: Date? = nil

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
        skipEnabled: Bool = false,
        skipIntroSec: Int = 0,
        skipOutroSec: Int = 0,
        speed: Double = 1.0,
        isPinned: Bool = false,
        sourceUnavailable: Bool = false,
        hasUpdate: Bool = false,
        latestChapterCount: Int = 0,
        updateCheckedAt: Date? = nil
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
        self.skipEnabled = skipEnabled
        self.skipIntroSec = skipIntroSec
        self.skipOutroSec = skipOutroSec
        self.speed = speed
        self.isPinned = isPinned
        self.sourceUnavailable = sourceUnavailable
        self.hasUpdate = hasUpdate
        self.latestChapterCount = latestChapterCount
        self.updateCheckedAt = updateCheckedAt
    }

    var bookRef: BookRef {
        BookRef(
            id: id,
            sourceID: sourceID,
            bookURL: bookURL,
            title: title,
            author: author,
            cover: cover,
            intro: intro,
            chapterCount: max(totalChapters, latestChapterCount)
        )
    }

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

    private static let hhmmFormat = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current,
        calendar: .current
    )

    private static let mmddHHmmFormat = Date.VerbatimFormatStyle(
        format: "\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current,
        calendar: .current
    )

    var formattedLastPlayedAtText: String {
        guard let playedAt = lastPlayedAt else { return "尚未播放" }
        let interval = Date.now.timeIntervalSince(playedAt)
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else if Calendar.current.isDateInToday(playedAt) {
            return "今天 \(Self.hhmmFormat.format(playedAt))"
        } else if Calendar.current.isDateInYesterday(playedAt) {
            return "昨天 \(Self.hhmmFormat.format(playedAt))"
        } else {
            return Self.mmddHHmmFormat.format(playedAt)
        }
    }

    var playbackProgressSummary: String {
        if let chapter = lastChapterTitle, !chapter.isEmpty {
            if lastPositionMs > 0 {
                return "\(chapter) · \(formattedPositionText)"
            }
            return chapter
        }
        return "尚未收听"
    }

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

    var episodeAndTimeProgressText: String {
        let timePart = formattedPositionText
        if let title = lastChapterTitle, !title.isEmpty {
            return lastPositionMs > 0 ? "\(title) · \(timePart)" : title
        } else if lastChapterIndex > 0 && totalChapters > 0 {
            return "第 \(lastChapterIndex)/\(totalChapters) 章 · \(timePart)"
        } else if lastChapterIndex > 0 {
            return "第 \(lastChapterIndex) 章 · \(timePart)"
        } else if totalChapters > 0 {
            return "共 \(totalChapters) 章 · 尚未收听"
        }
        return "尚未收听"
    }
}

/// T3-02 章节收听进度 SwiftData 模型
@Model
final class ChapterProgress {
    @Attribute(.unique) var id: String // bookID + "::" + chapterID
    var bookID: String
    var chapterID: String
    var positionMs: Int
    var durationMs: Int
    var isFinished: Bool
    var updatedAt: Date

    init(
        id: String? = nil,
        bookID: String,
        chapterID: String,
        positionMs: Int,
        durationMs: Int = 0,
        isFinished: Bool = false,
        updatedAt: Date = .now
    ) {
        self.id = id ?? "\(bookID)::\(chapterID)"
        self.bookID = bookID
        self.chapterID = chapterID
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.isFinished = isFinished
        self.updatedAt = updatedAt
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
    /// 取值："queued" | "downloading" | "completed" | "failed" | "paused" | "waitingWiFi"
    var state: String
    var localPath: String
    var bytes: Int64
    var retryCount: Int
    var createdAt: Date
    /// 入队时的音质档位快照（`AudioQualityTier.rawValue`）
    ///
    /// E3：下载按"用户点下载时选择的档位"执行，避免排队到移动网络后档位漂移；
    /// 空串表示未快照（老记录 / 预缓存），此时回落到当前全局档位。
    var qualityTierSnapshot: String = ""
    /// 该条目的内容是否为"旧档位"，需要按当前档位重下（UI 角标 + 重下开关）
    var qualityIsStale: Bool = false
    /// 实际落盘所用的链码（QualityPolicy.code 的返回值；空串表示老记录，回落按档位标签）
    var qualityCodeSnapshot: String = ""
    /// 期望整集时长（秒；用于 A6 的"试听片段"校验，0 表示未知）
    var expectedDurationSec: Double = 0

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
        createdAt: Date = .now,
        qualityTierSnapshot: String = "",
        qualityIsStale: Bool = false,
        qualityCodeSnapshot: String = "",
        expectedDurationSec: Double = 0
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
        self.qualityTierSnapshot = qualityTierSnapshot
        self.qualityIsStale = qualityIsStale
        self.qualityCodeSnapshot = qualityCodeSnapshot
        self.expectedDurationSec = expectedDurationSec
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
    var lastCheckStatus: String = "untested"
    var lastLatencyMs: Int = -1
    var lastCheckMessage: String = ""
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

@Model
final class BuiltinParserRecord {
    @Attribute(.unique) var id: String
    var name: String
    var version: String
    var author: String
    var summary: String
    var targetHosts: String
    var targetSourceIDs: String
    var fileName: String
    var sha256: String
    var sizeBytes: Int
    var importedAt: Date
    var isEnabled: Bool
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

/// 保留旧测试兼容枚举（testBottomTabOrderIsDiscoverSearchShelfSettings）
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

/// T2-02 新外壳四标签枚举：书架 · 发现 · 我的 · 搜索（role: .search）
enum ShellTab: String, CaseIterable, Hashable, Sendable {
    case discover = "discover"
    case search = "search"
    case library = "library"
    case me = "me"

    var title: String {
        switch self {
        case .discover: return "发现"
        case .search: return "搜索"
        case .library: return "书籍"
        case .me: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .library: return "books.vertical"
        case .discover: return "safari"
        case .me: return "person.crop.circle"
        case .search: return "magnifyingglass"
        }
    }
}

enum SourceFocus: String, Hashable, Codable, Sendable {
    case builtinParser
}

enum Route: Hashable {
    case book(BookRef, preferDownloaded: Bool = false)
    case history
    case downloads
    case sourceList
    case sourceDetail(id: String, focus: SourceFocus? = nil)
    case sourceImport
    case playbackMore
    case about
    case pluginManager
    case downloadManager
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

    var discoverSubtitle: String {
        if chapterCount > 0 {
            return "共 \(chapterCount) 章"
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
    var resolvedBy: String = ""
    var expiresAt: Date? = nil
    var durationSec: Double? = nil
    var fileSize: Int64? = nil
    var isTrial: Bool = false
}

struct SourceConfigItem: Identifiable, Hashable, Codable, Sendable {
    var id: String { key }
    var key: String
    var title: String
    var defaultValue: String
    var summary: String
}
