import DSCore
import Foundation
import SwiftData

/// 书籍实体（SwiftData v3 绿地模型：书架与历史彻底分字段隔离，内聚单本跳片头片尾与音效偏好）
@Model
public final class BookEntity {
    #Index<BookEntity>([\.inShelf, \.isPinned, \.lastPlayedAt], [\.lastPlayedAt])

    @Attribute(.unique) public var id: String
    public var sourceID: String
    public var sourceName: String
    public var bookURL: String
    public var title: String
    public var author: String
    public var narrator: String
    public var coverURL: String
    public var intro: String
    public var latestChapter: String
    public var totalChapters: Int

    // 书架维度
    public var inShelf: Bool
    public var isPinned: Bool
    public var shelfGroupID: String
    public var addedToShelfAt: Date?

    // 播放历史维度（与 inShelf 彻底独立）
    public var lastPlayedAt: Date?
    public var lastChapterID: String
    public var lastChapterIndex: Int
    public var lastChapterTitle: String
    public var lastPositionMs: Int
    public var lastDurationMs: Int

    // 单本音频偏好（规则 #17：仅单本，无全局默认）
    public var skipIntroSeconds: Int
    public var skipOutroSeconds: Int
    public var eqPresetRaw: String

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
        totalChapters: Int = 0,
        inShelf: Bool = false,
        isPinned: Bool = false,
        shelfGroupID: String = "default",
        addedToShelfAt: Date? = nil,
        lastPlayedAt: Date? = nil,
        lastChapterID: String = "",
        lastChapterIndex: Int = 0,
        lastChapterTitle: String = "",
        lastPositionMs: Int = 0,
        lastDurationMs: Int = 0,
        skipIntroSeconds: Int = 0,
        skipOutroSeconds: Int = 0,
        eqPresetRaw: String = "flat"
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
        self.totalChapters = totalChapters
        self.inShelf = inShelf
        self.isPinned = isPinned
        self.shelfGroupID = shelfGroupID
        self.addedToShelfAt = addedToShelfAt
        self.lastPlayedAt = lastPlayedAt
        self.lastChapterID = lastChapterID
        self.lastChapterIndex = lastChapterIndex
        self.lastChapterTitle = lastChapterTitle
        self.lastPositionMs = lastPositionMs
        self.lastDurationMs = lastDurationMs
        self.skipIntroSeconds = skipIntroSeconds
        self.skipOutroSeconds = skipOutroSeconds
        self.eqPresetRaw = eqPresetRaw
    }

    public func toSummaryDTO() -> BookSummaryDTO {
        BookSummaryDTO(
            id: id,
            sourceID: sourceID,
            sourceName: sourceName,
            bookURL: bookURL,
            title: title,
            author: author,
            narrator: narrator,
            coverURL: coverURL,
            intro: intro,
            latestChapter: latestChapter,
            totalChapters: totalChapters
        )
    }
}

/// 章节级播放进度实体（复合索引加速单本查询与历史裁剪）
@Model
public final class ChapterProgressEntity {
    #Index<ChapterProgressEntity>([\.bookID, \.updatedAt])

    @Attribute(.unique) public var compositeKey: String
    public var bookID: String
    public var chapterID: String
    public var chapterIndex: Int
    public var positionMs: Int
    public var durationMs: Int
    public var isFinished: Bool
    public var updatedAt: Date

    public init(
        bookID: String,
        chapterID: String,
        chapterIndex: Int,
        positionMs: Int,
        durationMs: Int,
        isFinished: Bool,
        updatedAt: Date = Date()
    ) {
        self.compositeKey = "\(bookID)::\(chapterID)"
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterIndex = chapterIndex
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.isFinished = isFinished
        self.updatedAt = updatedAt
    }
}

/// 后台下载记录实体（复合索引支持 manual/precache 双池调度与按类型时间排序）
@Model
public final class DownloadRecord {
    #Index<DownloadRecord>([\.stateRaw, \.kindRaw, \.createdAt], [\.kindRaw, \.createdAt])

    @Attribute(.unique) public var id: String
    public var bookID: String
    public var bookTitle: String
    public var coverURL: String
    public var sourceID: String
    public var chapterID: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var chapterURL: String
    public var kindRaw: String
    public var stateRaw: String
    public var qualityTierRaw: String
    public var retryCount: Int
    public var retryNotBefore: Date?
    public var localRelPath: String?
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(snapshot: DownloadRecordSnapshot) {
        self.id = snapshot.id
        self.bookID = snapshot.bookID
        self.bookTitle = snapshot.bookTitle
        self.coverURL = snapshot.coverURL
        self.sourceID = snapshot.sourceID
        self.chapterID = snapshot.chapterID
        self.chapterIndex = snapshot.chapterIndex
        self.chapterTitle = snapshot.chapterTitle
        self.chapterURL = snapshot.chapterURL
        self.kindRaw = snapshot.kind.rawValue
        self.stateRaw = snapshot.state.rawValue
        self.qualityTierRaw = snapshot.qualityTier.rawValue
        self.retryCount = snapshot.retryCount
        self.retryNotBefore = snapshot.retryNotBefore
        self.localRelPath = snapshot.localRelPath
        self.totalBytes = snapshot.totalBytes
        self.downloadedBytes = snapshot.downloadedBytes
        self.errorMessage = snapshot.errorMessage
        self.createdAt = snapshot.createdAt
        self.updatedAt = Date()
    }

    public func toSnapshot() -> DownloadRecordSnapshot {
        DownloadRecordSnapshot(
            id: id,
            bookID: bookID,
            bookTitle: bookTitle,
            coverURL: coverURL,
            sourceID: sourceID,
            chapterID: chapterID,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            chapterURL: chapterURL,
            kind: DownloadKind(rawValue: kindRaw) ?? .manual,
            state: DownloadState(rawValue: stateRaw) ?? .queued,
            qualityTier: AudioQualityTier.fromParserToken(qualityTierRaw) ?? .standard,
            retryCount: retryCount,
            retryNotBefore: retryNotBefore,
            localRelPath: localRelPath,
            totalBytes: totalBytes,
            downloadedBytes: downloadedBytes,
            errorMessage: errorMessage,
            createdAt: createdAt
        )
    }
}
