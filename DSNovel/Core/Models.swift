import Foundation
import SwiftData

// MARK: - SwiftData 持久化实体（严格对齐报告 4.1 节）

@Model
final class Book {
    @Attribute(.unique) var id: String // sourceID + "::" + bookURL
    var sourceID: String
    var bookURL: String
    var title: String
    var author: String
    var cover: String
    var intro: String
    var addedAt: Date
    var categoryID: String?
    var lastChapterID: String?
    var lastChapterTitle: String?
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
        addedAt: Date = .now,
        categoryID: String? = nil,
        lastChapterID: String? = nil,
        lastChapterTitle: String? = nil,
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
        self.addedAt = addedAt
        self.categoryID = categoryID
        self.lastChapterID = lastChapterID
        self.lastChapterTitle = lastChapterTitle
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
final class Bookmark {
    @Attribute(.unique) var id: String
    var bookID: String
    var chapterID: String
    var chapterTitle: String
    var positionMs: Int
    var note: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        bookID: String,
        chapterID: String,
        chapterTitle: String,
        positionMs: Int,
        note: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.positionMs = positionMs
        self.note = note
        self.createdAt = createdAt
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
        settingsJSON: String = "{}"
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

// MARK: - 轻量值类型 DTO 与路由枚举

enum AppTab: Int, CaseIterable, Hashable {
    case discover = 0
    case shelf = 1
    case search = 2
    case settings = 3

    var title: String {
        switch self {
        case .discover: return "发现"
        case .shelf: return "书架"
        case .search: return "搜索"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .discover: return "safari"
        case .shelf: return "books.vertical"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

enum Route: Hashable {
    case book(BookRef, alternatives: [BookRef] = [])
    case pluginManager
    case downloadManager
    case skipSettings
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

    var normalizedKey: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
}

struct SourceConfigItem: Identifiable, Hashable, Codable, Sendable {
    var id: String { key }
    var key: String
    var title: String
    var defaultValue: String
    var summary: String
}
