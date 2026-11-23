import Foundation

/// 跨包冻结契约：音频解析失败是否允许退避重试（解耦 DSDownloads 与 DSPluginKit）
public protocol AudioFailureClassifying: Error, Sendable {
    var isRetryableAudioFailure: Bool { get }
}

/// 跨包冻结契约：音频解析协议（DSPluginKit 实现，DSPlayback / DSDownloads 消费）
public protocol AudioResolving: Sendable {
    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool
    ) async throws -> AudioStreamDTO

    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool,
        bypassCache: Bool
    ) async throws -> AudioStreamDTO
}

public extension AudioResolving {
    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool,
        bypassCache: Bool
    ) async throws -> AudioStreamDTO {
        try await resolveAudio(
            sourceID: sourceID,
            bookID: bookID,
            chapter: chapter,
            preferredQuality: preferredQuality,
            forDownload: forDownload
        )
    }
}

/// 跨包冻结契约：章节目录缓存协议（DSStorage 实现）
public protocol ChapterCaching: Sendable {
    func loadChapters(bookID: String) async -> [ChapterDTO]?
    func saveChapters(_ chapters: [ChapterDTO], bookID: String) async throws
    func removeChapters(bookID: String) async
    func clearAll() async
}

/// 跨包冻结契约：下载记录持久化同步（DSStorage 实现，DSDownloads 消费）
public struct DownloadRecordSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let bookID: String
    public let bookTitle: String
    public let coverURL: String
    public let sourceID: String
    public let chapterID: String
    public let chapterIndex: Int
    public let chapterTitle: String
    public let chapterURL: String
    public var kind: DownloadKind
    public var state: DownloadState
    public var qualityTier: AudioQualityTier
    public var retryCount: Int
    public var retryNotBefore: Date?
    public var localRelPath: String?
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var errorMessage: String?
    public let createdAt: Date

    public init(
        id: String,
        bookID: String,
        bookTitle: String,
        coverURL: String = "",
        sourceID: String,
        chapterID: String,
        chapterIndex: Int,
        chapterTitle: String,
        chapterURL: String,
        kind: DownloadKind,
        state: DownloadState = .queued,
        qualityTier: AudioQualityTier = .standard,
        retryCount: Int = 0,
        retryNotBefore: Date? = nil,
        localRelPath: String? = nil,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.coverURL = coverURL
        self.sourceID = sourceID
        self.chapterID = chapterID
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.chapterURL = chapterURL
        self.kind = kind
        self.state = state
        self.qualityTier = qualityTier
        self.retryCount = retryCount
        self.retryNotBefore = retryNotBefore
        self.localRelPath = localRelPath
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }

    /// 固定磁盘相对路径：md5(bookID)/md5(chapterID).ext（AUD-35：仅保留 ASCII 字母数字且限长 8 位）
    public static func canonicalRelativePath(bookID: String, chapterID: String, ext: String = "m4a") -> String {
        let cleanExt = String(ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        let finalExt = cleanExt.isEmpty ? "m4a" : cleanExt
        return "\(DSCrypto.md5Hex(bookID))/\(DSCrypto.md5Hex(chapterID)).\(finalExt)"
    }
}

/// 跨包冻结契约：离线音频查询（DSDownloads 实现，DSPlayback 消费）
public protocol OfflineAudioLocating: Sendable {
    func localAudioURL(bookID: String, chapterID: String) async -> URL?
    func isDownloaded(bookID: String, chapterID: String) async -> Bool
}

/// 跨包冻结契约：单本进度持久化（DSStorage 实现，DSPlayback 消费）
public protocol PlaybackProgressPersisting: Sendable {
    func saveProgress(
        book: BookSummaryDTO,
        chapter: ChapterDTO,
        positionMs: Int,
        durationMs: Int,
        isFinished: Bool,
        overrideFinished: Bool
    ) async
    func loadChapterProgress(bookID: String, chapterID: String) async -> (positionMs: Int, durationMs: Int, isFinished: Bool)?
    func loadBookSkipConfig(bookID: String) async -> SkipConfigDTO
    func saveBookSkipConfig(bookID: String, config: SkipConfigDTO) async
}
