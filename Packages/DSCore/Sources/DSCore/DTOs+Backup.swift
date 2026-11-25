import Foundation

/// 版本化书架与进度备份导出结构（拆分自 DTOs.swift 以确保单文件 ≤ 400 行）
public struct LibraryBackupPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public struct BackupShelfGroup: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let sortOrder: Int

        public init(id: String, name: String, sortOrder: Int) {
            self.id = id
            self.name = name
            self.sortOrder = sortOrder
        }
    }

    public struct BackupBook: Codable, Sendable, Equatable {
        public let id: String
        public let sourceID: String
        public let sourceName: String
        public let bookURL: String
        public let title: String
        public let author: String
        public let narrator: String
        public let coverURL: String
        public let inShelf: Bool
        public let isPinned: Bool
        /// 历史 JSON 键名兼容保留：实际存储的是 `BookEntity.shelfGroupID`（书架分组 ID，默认 `"default"`）
        public let shelfGroupName: String
        public let lastPlayedAt: Date?
        public let lastChapterID: String?
        public let lastChapterIndex: Int
        public let lastChapterTitle: String
        public let lastPositionMs: Int
        public let lastDurationMs: Int?
        public let skipConfig: SkipConfigDTO

        public init(
            id: String,
            sourceID: String,
            sourceName: String,
            bookURL: String,
            title: String,
            author: String,
            narrator: String,
            coverURL: String,
            inShelf: Bool,
            isPinned: Bool,
            shelfGroupName: String,
            lastPlayedAt: Date?,
            lastChapterID: String? = nil,
            lastChapterIndex: Int,
            lastChapterTitle: String,
            lastPositionMs: Int,
            lastDurationMs: Int? = nil,
            skipConfig: SkipConfigDTO
        ) {
            self.id = id
            self.sourceID = sourceID
            self.sourceName = sourceName
            self.bookURL = bookURL
            self.title = title
            self.author = author
            self.narrator = narrator
            self.coverURL = coverURL
            self.inShelf = inShelf
            self.isPinned = isPinned
            self.shelfGroupName = shelfGroupName
            self.lastPlayedAt = lastPlayedAt
            self.lastChapterID = lastChapterID
            self.lastChapterIndex = lastChapterIndex
            self.lastChapterTitle = lastChapterTitle
            self.lastPositionMs = lastPositionMs
            self.lastDurationMs = lastDurationMs
            self.skipConfig = skipConfig
        }
    }

    public let schemaVersion: Int
    public let exportedAt: Date
    public let appVersion: String
    public let books: [BackupBook]
    public let shelfGroups: [BackupShelfGroup]?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date = Date(),
        appVersion: String = "3.0.0",
        books: [BackupBook],
        shelfGroups: [BackupShelfGroup]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.books = books
        self.shelfGroups = shelfGroups
    }
}

/// 内置解析器自检结果（对应脚本 checkStatus() 返回结构）
public struct BuiltinParserStatusDTO: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public let latencyMs: Int
    public let nickname: String
    public let vipExpireAt: String
    public let maxLevelNote: String

    public init(
        ok: Bool,
        message: String,
        latencyMs: Int = 0,
        nickname: String = "",
        vipExpireAt: String = "",
        maxLevelNote: String = ""
    ) {
        self.ok = ok
        self.message = message
        self.latencyMs = latencyMs
        self.nickname = nickname
        self.vipExpireAt = vipExpireAt
        self.maxLevelNote = maxLevelNote
    }
}
