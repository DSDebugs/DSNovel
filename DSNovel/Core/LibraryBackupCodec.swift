import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 书架与进度备份数据模型（Schema v1）

struct LibraryBackupBook: Codable, Sendable, Equatable {
    var id: String
    var sourceID: String
    var bookURL: String
    var title: String
    var author: String
    var cover: String
    var intro: String
    var inShelf: Bool
    var addedAt: Date
    var categoryID: String?
    var lastChapterID: String?
    var lastChapterTitle: String?
    var lastChapterIndex: Int
    var totalChapters: Int
    var lastPositionMs: Int
    var lastPlayedAt: Date?
    var volume: Double
    var skipEnabled: Bool
    var skipIntroSec: Int
    var skipOutroSec: Int
    var speed: Double
    var isPinned: Bool
    var preferredAudioQualityRaw: String? = nil

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
        preferredAudioQualityRaw: String? = nil
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
        self.preferredAudioQualityRaw = preferredAudioQualityRaw
    }

    init(book: Book) {
        self.id = book.id
        self.sourceID = book.sourceID
        self.bookURL = book.bookURL
        self.title = book.title
        self.author = book.author
        self.cover = book.cover
        self.intro = book.intro
        self.inShelf = book.inShelf
        self.addedAt = book.addedAt
        self.categoryID = book.categoryID
        self.lastChapterID = book.lastChapterID
        self.lastChapterTitle = book.lastChapterTitle
        self.lastChapterIndex = book.lastChapterIndex
        self.totalChapters = book.totalChapters
        self.lastPositionMs = book.lastPositionMs
        self.lastPlayedAt = book.lastPlayedAt
        self.volume = book.volume
        self.skipEnabled = book.skipEnabled
        self.skipIntroSec = book.skipIntroSec
        self.skipOutroSec = book.skipOutroSec
        self.speed = book.speed
        self.isPinned = book.isPinned
        self.preferredAudioQualityRaw = book.preferredAudioQualityRaw.isEmpty ? nil : book.preferredAudioQualityRaw
    }
}

struct LibraryBackupChapterProgress: Codable, Sendable, Equatable {
    var id: String
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

    init(progress: ChapterProgress) {
        self.id = progress.id
        self.bookID = progress.bookID
        self.chapterID = progress.chapterID
        self.positionMs = progress.positionMs
        self.durationMs = progress.durationMs
        self.isFinished = progress.isFinished
        self.updatedAt = progress.updatedAt
    }
}

struct LibraryBackupPayload: Codable, Sendable, Equatable {
    static let currentSchemaVersion: Int = 1

    var schemaVersion: Int
    var exportedAt: Date
    var books: [LibraryBackupBook]
    var chapterProgress: [LibraryBackupChapterProgress]

    init(
        schemaVersion: Int = LibraryBackupPayload.currentSchemaVersion,
        exportedAt: Date = .now,
        books: [LibraryBackupBook],
        chapterProgress: [LibraryBackupChapterProgress]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.books = books
        self.chapterProgress = chapterProgress
    }
}

struct LibraryBackupExportResult: Sendable {
    let document: LibraryBackupDocument
    let bookCount: Int
    let progressCount: Int
    let defaultFilename: String
}

struct LibraryBackupImportSummary: Sendable, Equatable {
    let importedBookCount: Int
    let updatedBookCount: Int
    let skippedBookCount: Int
    let importedProgressCount: Int

    var totalBookCount: Int {
        importedBookCount + updatedBookCount + skippedBookCount
    }
}

enum LibraryBackupError: LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case unreadableFile
    case payloadTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "不支持的备份文件版本（v\(version)），请升级 DSNovel 后再试。"
        case .unreadableFile:
            return "无法读取备份文件内容，请确认选择的是有效的 JSON 备份文件。"
        case .payloadTooLarge(let maxBytes):
            return "备份文件过大（超过 \(maxBytes / (1024 * 1024)) MB 上限），已拒绝导入。"
        }
    }
}

// MARK: - 编解码与幂等合并引擎

enum LibraryBackupCodec {
    static let maxImportBytes: Int = 20 * 1024 * 1024

    private static func clampedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.5), 3.0)
    }

    private static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.0), 2.0)
    }

    private static func clampedSkipSec(_ value: Int) -> Int {
        min(max(value, 0), 600)
    }

    private static func validatedQualityRaw(_ raw: String?) -> String? {
        guard let raw, let tier = AudioQualityTier(rawValue: raw) else { return nil }
        return tier.rawValue
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func defaultFilename(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "DSNovel-Backup-\(formatter.string(from: now))"
    }

    static func buildPayload(context: ModelContext, now: Date = .now) throws -> LibraryBackupPayload {
        let bookDescriptor = FetchDescriptor<Book>(
            sortBy: [SortDescriptor(\Book.addedAt, order: .reverse)]
        )
        let books = try context.fetch(bookDescriptor)

        let progressDescriptor = FetchDescriptor<ChapterProgress>(
            sortBy: [SortDescriptor(\ChapterProgress.updatedAt, order: .reverse)]
        )
        let progresses = try context.fetch(progressDescriptor)

        return LibraryBackupPayload(
            schemaVersion: LibraryBackupPayload.currentSchemaVersion,
            exportedAt: now,
            books: books.map(LibraryBackupBook.init(book:)),
            chapterProgress: progresses.map(LibraryBackupChapterProgress.init(progress:))
        )
    }

    static func exportJSON(context: ModelContext) throws -> Data {
        let payload = try buildPayload(context: context)
        return try makeEncoder().encode(payload)
    }

    static func exportDocument(context: ModelContext, now: Date = .now) throws -> LibraryBackupExportResult {
        let payload = try buildPayload(context: context, now: now)
        let data = try makeEncoder().encode(payload)
        return LibraryBackupExportResult(
            document: LibraryBackupDocument(data: data),
            bookCount: payload.books.count,
            progressCount: payload.chapterProgress.count,
            defaultFilename: defaultFilename(now: now)
        )
    }

    static func importJSON(_ data: Data, into context: ModelContext) throws -> LibraryBackupImportSummary {
        guard data.count <= maxImportBytes else {
            throw LibraryBackupError.payloadTooLarge(maxImportBytes)
        }
        let payload = try makeDecoder().decode(LibraryBackupPayload.self, from: data)
        guard payload.schemaVersion >= 1 && payload.schemaVersion <= LibraryBackupPayload.currentSchemaVersion else {
            throw LibraryBackupError.unsupportedSchemaVersion(payload.schemaVersion)
        }

        let existingBooks = try context.fetch(FetchDescriptor<Book>())
        var booksByID: [String: Book] = [:]
        booksByID.reserveCapacity(existingBooks.count)
        for book in existingBooks {
            booksByID[book.id] = book
        }

        var importedBooks = 0
        var updatedBooks = 0
        var skippedBooks = 0

        for item in payload.books {
            guard !item.id.isEmpty, !item.sourceID.isEmpty, !item.bookURL.isEmpty, !item.title.isEmpty else {
                continue
            }

            if let existing = booksByID[item.id] {
                if mergeBook(from: item, into: existing) {
                    updatedBooks += 1
                } else {
                    skippedBooks += 1
                }
            } else {
                let inserted = Book(
                    id: item.id,
                    sourceID: item.sourceID,
                    bookURL: item.bookURL,
                    title: item.title,
                    author: item.author,
                    cover: item.cover,
                    intro: item.intro,
                    inShelf: item.inShelf,
                    addedAt: item.addedAt,
                    categoryID: item.categoryID,
                    lastChapterID: item.lastChapterID,
                    lastChapterTitle: item.lastChapterTitle,
                    lastChapterIndex: max(0, item.lastChapterIndex),
                    totalChapters: max(0, item.totalChapters),
                    lastPositionMs: max(0, item.lastPositionMs),
                    lastPlayedAt: item.lastPlayedAt,
                    volume: clampedVolume(item.volume),
                    skipEnabled: item.skipEnabled,
                    skipIntroSec: clampedSkipSec(item.skipIntroSec),
                    skipOutroSec: clampedSkipSec(item.skipOutroSec),
                    speed: clampedSpeed(item.speed),
                    isPinned: item.isPinned,
                    preferredAudioQualityRaw: validatedQualityRaw(item.preferredAudioQualityRaw) ?? ""
                )
                context.insert(inserted)
                booksByID[item.id] = inserted
                importedBooks += 1
            }
        }

        let existingProgresses = try context.fetch(FetchDescriptor<ChapterProgress>())
        var progressByID: [String: ChapterProgress] = [:]
        progressByID.reserveCapacity(existingProgresses.count)
        for progress in existingProgresses {
            progressByID[progress.id] = progress
        }

        var importedProgresses = 0
        for item in payload.chapterProgress {
            guard !item.bookID.isEmpty, !item.chapterID.isEmpty else { continue }
            let pid = item.id.isEmpty ? "\(item.bookID)::\(item.chapterID)" : item.id

            if let existing = progressByID[pid] {
                if mergeChapterProgress(from: item, into: existing) {
                    importedProgresses += 1
                }
            } else {
                let inserted = ChapterProgress(
                    id: pid,
                    bookID: item.bookID,
                    chapterID: item.chapterID,
                    positionMs: max(0, item.positionMs),
                    durationMs: max(0, item.durationMs),
                    isFinished: item.isFinished,
                    updatedAt: item.updatedAt
                )
                context.insert(inserted)
                progressByID[pid] = inserted
                importedProgresses += 1
            }
        }

        try context.save()

        return LibraryBackupImportSummary(
            importedBookCount: importedBooks,
            updatedBookCount: updatedBooks,
            skippedBookCount: skippedBooks,
            importedProgressCount: importedProgresses
        )
    }

    private static func mergeBook(from backup: LibraryBackupBook, into existing: Book) -> Bool {
        var changed = false

        if backup.inShelf && !existing.inShelf {
            existing.inShelf = true
            changed = true
        }
        if backup.isPinned && !existing.isPinned {
            existing.isPinned = true
            changed = true
        }
        if existing.author.isEmpty && !backup.author.isEmpty {
            existing.author = backup.author
            changed = true
        }
        if existing.cover.isEmpty && !backup.cover.isEmpty {
            existing.cover = backup.cover
            changed = true
        }
        if existing.intro.isEmpty && !backup.intro.isEmpty {
            existing.intro = backup.intro
            changed = true
        }
        if existing.categoryID == nil, let categoryID = backup.categoryID, !categoryID.isEmpty {
            existing.categoryID = categoryID
            changed = true
        }
        if backup.totalChapters > existing.totalChapters {
            existing.totalChapters = backup.totalChapters
            changed = true
        }

        if shouldAdoptProgress(backup: backup, local: existing) {
            existing.lastChapterID = backup.lastChapterID
            existing.lastChapterTitle = backup.lastChapterTitle
            existing.lastChapterIndex = max(0, backup.lastChapterIndex)
            existing.lastPositionMs = max(0, backup.lastPositionMs)
            existing.lastPlayedAt = backup.lastPlayedAt
            changed = true
        }

        if !existing.skipEnabled && backup.skipEnabled {
            existing.skipEnabled = true
            existing.skipIntroSec = clampedSkipSec(backup.skipIntroSec)
            existing.skipOutroSec = clampedSkipSec(backup.skipOutroSec)
            changed = true
        }
        let safeSpeed = clampedSpeed(backup.speed)
        if existing.speed == 1.0 && safeSpeed != 1.0 {
            existing.speed = safeSpeed
            changed = true
        }
        let safeVolume = clampedVolume(backup.volume)
        if existing.volume == 1.0 && safeVolume != 1.0 {
            existing.volume = safeVolume
            changed = true
        }
        if existing.preferredAudioQualityRaw.isEmpty,
           let validQuality = validatedQualityRaw(backup.preferredAudioQualityRaw) {
            existing.preferredAudioQualityRaw = validQuality
            changed = true
        }

        return changed
    }

    private static func shouldAdoptProgress(backup: LibraryBackupBook, local: Book) -> Bool {
        if let backupPlayed = backup.lastPlayedAt {
            if let localPlayed = local.lastPlayedAt {
                return backupPlayed > localPlayed
            }
            return true
        }
        let localHasNoProgress = local.lastPlayedAt == nil
            && local.lastChapterID == nil
            && local.lastChapterIndex == 0
            && local.lastPositionMs == 0
        let backupHasProgress = backup.lastChapterID != nil
            || backup.lastChapterIndex > 0
            || backup.lastPositionMs > 0
        return localHasNoProgress && backupHasProgress
    }

    private static func mergeChapterProgress(
        from backup: LibraryBackupChapterProgress,
        into existing: ChapterProgress
    ) -> Bool {
        if backup.updatedAt > existing.updatedAt {
            existing.positionMs = max(0, backup.positionMs)
            existing.durationMs = max(existing.durationMs, max(0, backup.durationMs))
            existing.isFinished = existing.isFinished || backup.isFinished
            existing.updatedAt = backup.updatedAt
            return true
        }
        if backup.isFinished && !existing.isFinished {
            existing.isFinished = true
            existing.durationMs = max(existing.durationMs, max(0, backup.durationMs))
            return true
        }
        return false
    }
}

// MARK: - SwiftUI FileDocument 包装

struct LibraryBackupDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else {
            throw LibraryBackupError.unreadableFile
        }
        self.data = raw
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
