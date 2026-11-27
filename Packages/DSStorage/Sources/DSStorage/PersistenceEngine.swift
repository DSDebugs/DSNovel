import DSCore
import Foundation
import os
import SwiftData

/// 统一后台持久化 Actor（@ModelActor 串行隔离，零主线程数据库 I/O）
@ModelActor
public actor PersistenceEngine: PlaybackProgressPersisting {
    internal static let logger = Logger(subsystem: "com.dsnovel.app", category: DSLogCategory.storage.rawValue)

    /// 在后台队列构造 @ModelActor，确保 DefaultSerialModelExecutor 绝不绑定到主线程
    public static func makeOffMain(modelContainer: ModelContainer) -> PersistenceEngine {
        if !Thread.isMainThread {
            return PersistenceEngine(modelContainer: modelContainer)
        }
        return DispatchQueue.global(qos: .userInitiated).sync {
            PersistenceEngine(modelContainer: modelContainer)
        }
    }

    internal func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Book & Shelf / History（书架与历史彻底解耦）

    private func upsertBookEntity(_ summary: BookSummaryDTO, addToShelf: Bool? = nil) throws -> BookEntity {
        let targetID = summary.id
        let pred = #Predicate<BookEntity> { $0.id == targetID }
        var descriptor = FetchDescriptor<BookEntity>(predicate: pred)
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            if !summary.bookURL.isEmpty { existing.bookURL = summary.bookURL }
            if !summary.title.isEmpty { existing.title = summary.title }
            if !summary.author.isEmpty { existing.author = summary.author }
            if !summary.narrator.isEmpty { existing.narrator = summary.narrator }
            if !summary.coverURL.isEmpty { existing.coverURL = summary.coverURL }
            if !summary.intro.isEmpty { existing.intro = summary.intro }
            if !summary.latestChapter.isEmpty { existing.latestChapter = summary.latestChapter }
            if summary.totalChapters > 0 { existing.totalChapters = summary.totalChapters }
            if !summary.sourceName.isEmpty { existing.sourceName = summary.sourceName }
            if let add = addToShelf {
                existing.inShelf = add
                if add && existing.addedToShelfAt == nil {
                    existing.addedToShelfAt = Date()
                } else if !add {
                    existing.isPinned = false
                }
            }
            return existing
        } else {
            let entity = BookEntity(
                id: summary.id,
                sourceID: summary.sourceID,
                sourceName: summary.sourceName,
                bookURL: summary.bookURL,
                title: summary.title,
                author: summary.author,
                narrator: summary.narrator,
                coverURL: summary.coverURL,
                intro: summary.intro,
                latestChapter: summary.latestChapter,
                totalChapters: summary.totalChapters,
                inShelf: addToShelf ?? false,
                addedToShelfAt: (addToShelf ?? false) ? Date() : nil
            )
            modelContext.insert(entity)
            return entity
        }
    }

    public func upsertBook(_ summary: BookSummaryDTO, addToShelf: Bool? = nil) throws {
        _ = try upsertBookEntity(summary, addToShelf: addToShelf)
        try saveOrRollback()
    }

    /// AUD-40：按 bookID 精确查询单本摘要（供离线详情页等场景直查）
    public func fetchBook(id: String) throws -> BookSummaryDTO? {
        let targetID = id
        var desc = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == targetID })
        desc.fetchLimit = 1
        return try modelContext.fetch(desc).first?.toSummaryDTO()
    }

    /// 详情页拉取完整元数据后静默回写已有本地记录（不改变书架收藏状态，闭合简介与目录 TTL 缓存）
    public func updateExistingBookMetadata(_ summary: BookSummaryDTO) throws {
        let targetID = summary.id
        var desc = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == targetID })
        desc.fetchLimit = 1
        guard let existing = try modelContext.fetch(desc).first else { return }
        if !summary.title.isEmpty { existing.title = summary.title }
        if !summary.author.isEmpty { existing.author = summary.author }
        if !summary.narrator.isEmpty { existing.narrator = summary.narrator }
        if !summary.coverURL.isEmpty { existing.coverURL = summary.coverURL }
        if !summary.intro.isEmpty { existing.intro = summary.intro }
        if !summary.latestChapter.isEmpty { existing.latestChapter = summary.latestChapter }
        if summary.totalChapters > 0 { existing.totalChapters = summary.totalChapters }
        try saveOrRollback()
    }

    public func setInShelf(bookID: String, inShelf: Bool) throws {
        let pred = #Predicate<BookEntity> { $0.id == bookID }
        var desc = FetchDescriptor<BookEntity>(predicate: pred)
        desc.fetchLimit = 1
        if let book = try modelContext.fetch(desc).first {
            book.inShelf = inShelf
            if inShelf {
                book.addedToShelfAt = book.addedToShelfAt ?? Date()
            } else {
                book.isPinned = false
            }
            try saveOrRollback()
        }
    }

    public func clearAllHistory() throws {
        let pred = #Predicate<BookEntity> { $0.lastPlayedAt != nil }
        let items = try modelContext.fetch(FetchDescriptor<BookEntity>(predicate: pred))
        for book in items {
            book.lastPlayedAt = nil
        }
        try saveOrRollback()
    }

    public func clearHistory(bookID: String) throws {
        let pred = #Predicate<BookEntity> { $0.id == bookID }
        var desc = FetchDescriptor<BookEntity>(predicate: pred)
        desc.fetchLimit = 1
        if let book = try modelContext.fetch(desc).first {
            book.lastPlayedAt = nil
            try saveOrRollback()
        }
    }

    public func togglePin(bookID: String) throws {
        let pred = #Predicate<BookEntity> { $0.id == bookID }
        var desc = FetchDescriptor<BookEntity>(predicate: pred)
        desc.fetchLimit = 1
        if let book = try modelContext.fetch(desc).first {
            guard book.inShelf else { return }
            book.isPinned.toggle()
            try saveOrRollback()
        }
    }

    public func fetchShelfBooks() throws -> [BookSummaryDTO] {
        let pred = #Predicate<BookEntity> { $0.inShelf == true }
        let sort = [
            SortDescriptor<BookEntity>(\.lastPlayedAt, order: .reverse),
            SortDescriptor<BookEntity>(\.addedToShelfAt, order: .reverse)
        ]
        let desc = FetchDescriptor<BookEntity>(predicate: pred, sortBy: sort)
        let rows = try modelContext.fetch(desc)
        let pinned = rows.filter(\.isPinned)
        let unpinned = rows.filter { !$0.isPinned }
        return (pinned + unpinned).map { $0.toSummaryDTO() }
    }

    public func fetchHistoryBooks(limit: Int = 200) throws -> [BookSummaryDTO] {
        let pred = #Predicate<BookEntity> { $0.lastPlayedAt != nil }
        var desc = FetchDescriptor<BookEntity>(
            predicate: pred,
            sortBy: [SortDescriptor<BookEntity>(\.lastPlayedAt, order: .reverse)]
        )
        desc.fetchLimit = max(1, limit)
        return try modelContext.fetch(desc).map { $0.toSummaryDTO() }
    }

    // MARK: - PlaybackProgressPersisting

    public func saveProgress(
        book: BookSummaryDTO,
        chapter: ChapterDTO,
        positionMs: Int,
        durationMs: Int,
        isFinished: Bool,
        overrideFinished: Bool
    ) async {
        do {
            let entity = try upsertBookEntity(book, addToShelf: nil)
            entity.lastPlayedAt = Date()
            entity.lastChapterID = chapter.id
            entity.lastChapterIndex = chapter.index
            entity.lastChapterTitle = chapter.title
            entity.lastPositionMs = max(0, positionMs)
            if durationMs > 0 {
                entity.lastDurationMs = durationMs
            }

            let key = "\(book.id)::\(chapter.id)"
            var progDesc = FetchDescriptor<ChapterProgressEntity>(predicate: #Predicate { $0.compositeKey == key })
            progDesc.fetchLimit = 1
            if let existing = try modelContext.fetch(progDesc).first {
                existing.chapterIndex = chapter.index
                existing.positionMs = max(0, positionMs)
                if durationMs > 0 {
                    existing.durationMs = durationMs
                }
                if overrideFinished {
                    existing.isFinished = isFinished
                } else if isFinished {
                    existing.isFinished = true
                }
                existing.updatedAt = Date()
            } else {
                let record = ChapterProgressEntity(
                    bookID: book.id,
                    chapterID: chapter.id,
                    chapterIndex: chapter.index,
                    positionMs: max(0, positionMs),
                    durationMs: max(0, durationMs),
                    isFinished: isFinished
                )
                modelContext.insert(record)
            }
            try saveOrRollback()
        } catch {
            modelContext.rollback()
            Self.logger.error("saveProgress failed for book=\(book.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadChapterProgress(bookID: String, chapterID: String) async -> (positionMs: Int, durationMs: Int, isFinished: Bool)? {
        let key = "\(bookID)::\(chapterID)"
        var desc = FetchDescriptor<ChapterProgressEntity>(predicate: #Predicate { $0.compositeKey == key })
        desc.fetchLimit = 1
        do {
            guard let item = try modelContext.fetch(desc).first else { return nil }
            return (item.positionMs, item.durationMs, item.isFinished)
        } catch {
            Self.logger.error("loadChapterProgress failed for book=\(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func loadBookSkipConfig(bookID: String) async -> SkipConfigDTO {
        var desc = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == bookID })
        desc.fetchLimit = 1
        do {
            guard let book = try modelContext.fetch(desc).first else { return SkipConfigDTO() }
            return SkipConfigDTO(introSeconds: book.skipIntroSeconds, outroSeconds: book.skipOutroSeconds)
        } catch {
            Self.logger.error("loadBookSkipConfig failed for book=\(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return SkipConfigDTO()
        }
    }

    public func saveBookSkipConfig(bookID: String, config: SkipConfigDTO) async {
        do {
            var desc = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == bookID })
            desc.fetchLimit = 1
            if let book = try modelContext.fetch(desc).first {
                book.skipIntroSeconds = config.introSeconds
                book.skipOutroSeconds = config.outroSeconds
                try saveOrRollback()
            }
        } catch {
            modelContext.rollback()
            Self.logger.error("saveBookSkipConfig failed for book=\(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 后台历史裁剪（P1-8 / AUD-40：按 bookID 确定性排序分组保留每本书最新 N 条，优先保留 isFinished 完听标记）
    public func pruneOldChapterProgress(keepLatestPerBook: Int = 500) throws -> Int {
        let keepLimit = max(0, keepLatestPerBook)
        let desc = FetchDescriptor<ChapterProgressEntity>(
            sortBy: [SortDescriptor<ChapterProgressEntity>(\.updatedAt, order: .reverse)]
        )
        let all = try modelContext.fetch(desc)
        let grouped = Dictionary(grouping: all, by: \.bookID)
        var deleted = 0
        for bookID in grouped.keys.sorted() {
            guard let rows = grouped[bookID], rows.count > keepLimit else { continue }
            let candidates = rows.dropFirst(keepLimit).filter { !$0.isFinished }
            for item in candidates {
                modelContext.delete(item)
                deleted += 1
                if deleted >= 200 { break }
            }
            if deleted >= 200 { break }
        }
        if deleted > 0 { try saveOrRollback() }
        return deleted
    }
}
