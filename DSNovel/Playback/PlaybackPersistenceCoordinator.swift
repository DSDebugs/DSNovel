import Foundation
import SwiftData

/// 播放进度与单书配置持久化协调器：
/// - 合并 `ChapterProgress` 与 `Book` 写入为单次 `ctx.save()` 事务，降低 SQLite fsync 频率
/// - 统一封装单书偏好读写、下载项查询与章节队列签名缓存
@MainActor
enum PlaybackPersistenceCoordinator {
    struct BookPlaybackSettings {
        let speed: Double
        let skipConfig: BookSkipConfig
        let bookVolume: Double
    }

    static func fetchBookPreferredAudioQualityRaw(for bookID: String, modelContext: ModelContext?) -> String? {
        if let ctx = modelContext {
            let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
            if let saved = try? ctx.fetch(descriptor).first {
                return saved.preferredAudioQualityRaw
            }
        }
        return LibraryStore.shared.book(for: bookID, fallbackContext: modelContext)?.preferredAudioQualityRaw
    }

    static func fetchDownloadItem(
        bookID: String,
        chapterID: String,
        modelContext: ModelContext?
    ) -> DownloadItem? {
        guard let ctx = modelContext ?? DownloadManager.shared.modelContext else { return nil }
        let itemID = "\(bookID)::\(chapterID)"
        let descriptor = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        return try? ctx.fetch(descriptor).first
    }

    static func loadBookPlaybackSettings(
        for bookID: String,
        modelContext: ModelContext?,
        settings: AppSettingsStore = .shared
    ) -> BookPlaybackSettings {
        guard let ctx = modelContext else {
            return BookPlaybackSettings(
                speed: settings.defaultSpeed,
                skipConfig: .unset,
                bookVolume: 1.0
            )
        }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            let resolvedSpeed = saved.speed > 0 ? saved.speed : settings.defaultSpeed
            let resolvedSkip = BookSkipConfig(
                enabled: saved.skipEnabled,
                introSec: saved.skipIntroSec,
                outroSec: saved.skipOutroSec
            ).normalized
            let resolvedVolume = settings.rememberBookVolume ? min(max(saved.volume, 0.0), 2.0) : 1.0
            return BookPlaybackSettings(
                speed: resolvedSpeed,
                skipConfig: resolvedSkip,
                bookVolume: resolvedVolume
            )
        }
        return BookPlaybackSettings(
            speed: settings.defaultSpeed,
            skipConfig: .unset,
            bookVolume: 1.0
        )
    }

    static func ensureBookRow(
        for book: BookRef,
        totalChapters: Int,
        volume: Double,
        skip: BookSkipConfig,
        speed: Double,
        in ctx: ModelContext
    ) -> Book {
        let bookID = book.id
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let existing = try? ctx.fetch(descriptor).first {
            return existing
        }
        let historyBook = Book(
            id: book.id,
            sourceID: book.sourceID,
            bookURL: book.bookURL,
            title: book.title,
            author: book.author,
            cover: book.cover,
            intro: book.intro,
            inShelf: false,
            addedAt: .now,
            totalChapters: totalChapters,
            lastPlayedAt: .now,
            volume: volume,
            skipEnabled: skip.enabled,
            skipIntroSec: skip.introSec,
            skipOutroSec: skip.outroSec,
            speed: speed
        )
        ctx.insert(historyBook)
        return historyBook
    }

    static func saveBookPreferredAudioQuality(
        _ tier: AudioQualityTier,
        for book: BookRef,
        totalChapters: Int,
        volume: Double,
        skip: BookSkipConfig,
        speed: Double,
        modelContext: ModelContext?
    ) {
        if let ctx = modelContext {
            let saved = ensureBookRow(
                for: book,
                totalChapters: totalChapters,
                volume: volume,
                skip: skip,
                speed: speed,
                in: ctx
            )
            saved.preferredAudioQualityRaw = tier.rawValue
            try? ctx.save()
        } else if let saved = LibraryStore.shared.book(for: book.id) {
            saved.preferredAudioQualityRaw = tier.rawValue
            try? LibraryStore.shared.modelContext?.save()
        }
    }

    static func saveBookAudioSettings(
        for book: BookRef,
        totalChapters: Int,
        speed: Double,
        volume: Double,
        skip: BookSkipConfig,
        in ctx: ModelContext
    ) {
        let saved = ensureBookRow(
            for: book,
            totalChapters: totalChapters,
            volume: volume,
            skip: skip,
            speed: speed,
            in: ctx
        )
        saved.speed = speed
        saved.volume = volume
        saved.skipEnabled = skip.enabled
        saved.skipIntroSec = skip.introSec
        saved.skipOutroSec = skip.outroSec
        try? ctx.save()
    }

    /// 单次事务合并写入 `ChapterProgress` 与 `Book` 记录
    static func persistPlaybackProgress(
        book: BookRef,
        chapter: ChapterDTO,
        chapterIndexOneBased: Int,
        totalChapters: Int,
        positionMs: Int,
        durationMs: Int,
        volume: Double,
        skip: BookSkipConfig,
        speed: Double,
        in ctx: ModelContext
    ) {
        let bookID = book.id
        let now = Date.now

        // 先在同一 ModelContext 中暂存 ChapterProgress（saveContext: false），随后与 Book 合并为单次 ctx.save()
        ChapterProgressCache.shared.update(
            bookID: bookID,
            chapterID: chapter.id,
            positionMs: positionMs,
            durationMs: durationMs,
            forceFlush: true,
            now: now,
            contextOverride: ctx,
            saveContext: false
        )

        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            saved.lastChapterID = chapter.id
            saved.lastChapterTitle = chapter.title
            if chapterIndexOneBased > 0 { saved.lastChapterIndex = chapterIndexOneBased }
            if totalChapters > 0 { saved.totalChapters = totalChapters }
            saved.lastPositionMs = positionMs
            saved.lastPlayedAt = now
            if !book.cover.isEmpty && saved.cover.isEmpty {
                saved.cover = book.cover
            }
            if !book.author.isEmpty && saved.author.isEmpty {
                saved.author = book.author
            }
        } else {
            let historyBook = Book(
                id: book.id,
                sourceID: book.sourceID,
                bookURL: book.bookURL,
                title: book.title,
                author: book.author,
                cover: book.cover,
                intro: book.intro,
                inShelf: false,
                addedAt: now,
                lastChapterID: chapter.id,
                lastChapterTitle: chapter.title,
                lastChapterIndex: chapterIndexOneBased,
                totalChapters: totalChapters,
                lastPositionMs: positionMs,
                lastPlayedAt: now,
                volume: volume,
                skipEnabled: skip.enabled,
                skipIntroSec: skip.introSec,
                skipOutroSec: skip.outroSec,
                speed: speed
            )
            ctx.insert(historyBook)
        }

        try? ctx.save()
    }

    static func saveChapterQueueIfNeeded(
        chapters: [ChapterDTO],
        for bookID: String,
        savedQueueSignature: inout String?
    ) {
        guard !chapters.isEmpty else { return }
        let signature = "\(bookID)#\(chapters.count)#\(chapters.first?.id ?? "")#\(chapters.last?.id ?? "")"
        guard signature != savedQueueSignature else { return }
        savedQueueSignature = signature
        let queue = chapters
        Task.detached(priority: .utility) {
            ChapterCacheStore.saveChapters(queue, for: bookID)
        }
    }
}
