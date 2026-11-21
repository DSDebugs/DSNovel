import Foundation
import SwiftData

/// S8 / R3-4 / M-P0-5：基于 SwiftData `@ModelActor` 的后台持久化执行器，
/// 封装独立后台 `ModelContext` 的分片批量写入、状态更新、清理、播放进度落盘与分批容量边界治理，
/// 供 `AppDependencies` 与核心业务模块按需调用，减少主线程 SQLite 写入阻塞。
@ModelActor
actor PersistenceActor {
    static let fetchChunkSize = 200
    static let defaultBoundsBatchLimit = 200

    struct DownloadItemStatePatch: Sendable {
        let itemID: String
        let state: String?
        let lastErrorMessage: String?
        let retryCount: Int?
        let localPath: String?
        let bytes: Int64?
        let qualityIsStale: Bool?
        let actualDurationSec: Double?
        let actualBitrateKbps: Int?
        let onlyIfActualBitrateUnset: Bool

        init(
            itemID: String,
            state: String? = nil,
            lastErrorMessage: String? = nil,
            retryCount: Int? = nil,
            localPath: String? = nil,
            bytes: Int64? = nil,
            qualityIsStale: Bool? = nil,
            actualDurationSec: Double? = nil,
            actualBitrateKbps: Int? = nil,
            onlyIfActualBitrateUnset: Bool = false
        ) {
            self.itemID = itemID
            self.state = state
            self.lastErrorMessage = lastErrorMessage
            self.retryCount = retryCount
            self.localPath = localPath
            self.bytes = bytes
            self.qualityIsStale = qualityIsStale
            self.actualDurationSec = actualDurationSec
            self.actualBitrateKbps = actualBitrateKbps
            self.onlyIfActualBitrateUnset = onlyIfActualBitrateUnset
        }
    }

    struct ChapterProgressPatch: Sendable {
        let bookID: String
        let chapterID: String
        let positionMs: Int
        let durationMs: Int
        let isFinished: Bool
        let updatedAt: Date

        init(
            bookID: String,
            chapterID: String,
            positionMs: Int,
            durationMs: Int = 0,
            isFinished: Bool = false,
            updatedAt: Date = .now
        ) {
            self.bookID = bookID
            self.chapterID = chapterID
            self.positionMs = positionMs
            self.durationMs = durationMs
            self.isFinished = isFinished
            self.updatedAt = updatedAt
        }
    }

    struct DownloadItemStateSnapshot: Sendable, Equatable {
        let itemID: String
        let state: String
        let lastErrorMessage: String
        let retryCount: Int
        let localPath: String
        let bytes: Int64
    }

    // MARK: - 分片主键查询（消除全表扫描）

    private func fetchDownloadItems(byIDs ids: [String]) throws -> [DownloadItem] {
        guard !ids.isEmpty else { return [] }
        if ids.count == 1, let targetID = ids.first {
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == targetID })
            return try modelContext.fetch(desc)
        }
        var results: [DownloadItem] = []
        results.reserveCapacity(ids.count)
        var start = 0
        while start < ids.count {
            let end = min(start + Self.fetchChunkSize, ids.count)
            let chunk = Array(ids[start..<end])
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { chunk.contains($0.id) })
            let batch = try modelContext.fetch(desc)
            results.append(contentsOf: batch)
            start = end
        }
        return results
    }

    private func fetchChapterProgress(byIDs ids: [String]) throws -> [ChapterProgress] {
        guard !ids.isEmpty else { return [] }
        if ids.count == 1, let targetID = ids.first {
            let desc = FetchDescriptor<ChapterProgress>(predicate: #Predicate<ChapterProgress> { $0.id == targetID })
            return try modelContext.fetch(desc)
        }
        var results: [ChapterProgress] = []
        results.reserveCapacity(ids.count)
        var start = 0
        while start < ids.count {
            let end = min(start + Self.fetchChunkSize, ids.count)
            let chunk = Array(ids[start..<end])
            let desc = FetchDescriptor<ChapterProgress>(predicate: #Predicate<ChapterProgress> { chunk.contains($0.id) })
            let batch = try modelContext.fetch(desc)
            results.append(contentsOf: batch)
            start = end
        }
        return results
    }

    // MARK: - 下载条目后台批量写库

    /// 批量更新下载条目状态、错误原因、文件或实测音质字段（按 200 条分片查询）
    @discardableResult
    func updateDownloadItems(_ patches: [DownloadItemStatePatch]) throws -> Int {
        guard !patches.isEmpty else { return 0 }
        var patchByID: [String: DownloadItemStatePatch] = [:]
        patchByID.reserveCapacity(patches.count)
        for patch in patches {
            patchByID[patch.itemID] = patch
        }

        let items = try fetchDownloadItems(byIDs: Array(patchByID.keys))

        var updated = 0
        for item in items {
            guard let patch = patchByID[item.id] else { continue }
            if patch.onlyIfActualBitrateUnset && item.actualBitrateKbps > 0 {
                continue
            }
            if let state = patch.state { item.state = state }
            if let lastErrorMessage = patch.lastErrorMessage { item.lastErrorMessage = lastErrorMessage }
            if let retryCount = patch.retryCount { item.retryCount = retryCount }
            if let localPath = patch.localPath { item.localPath = localPath }
            if let bytes = patch.bytes { item.bytes = bytes }
            if let qualityIsStale = patch.qualityIsStale { item.qualityIsStale = qualityIsStale }
            if let actualDurationSec = patch.actualDurationSec { item.actualDurationSec = actualDurationSec }
            if let actualBitrateKbps = patch.actualBitrateKbps { item.actualBitrateKbps = actualBitrateKbps }
            updated += 1
        }
        if updated > 0 {
            try modelContext.save()
        }
        return updated
    }

    /// 单条更新下载条目状态与精简错误原因
    @discardableResult
    func updateDownloadItemState(
        itemID: String,
        state: String,
        lastErrorMessage: String? = nil,
        retryCount: Int? = nil
    ) throws -> Bool {
        let count = try updateDownloadItems([
            DownloadItemStatePatch(
                itemID: itemID,
                state: state,
                lastErrorMessage: lastErrorMessage,
                retryCount: retryCount
            )
        ])
        return count > 0
    }

    /// 批量删除指定 ID 的下载条目（按 200 条分片查询）
    @discardableResult
    func deleteDownloadItems(ids: [String]) throws -> Int {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return 0 }
        let items = try fetchDownloadItems(byIDs: uniqueIDs)

        var deleted = 0
        for item in items {
            modelContext.delete(item)
            deleted += 1
        }
        if deleted > 0 {
            try modelContext.save()
        }
        return deleted
    }

    /// 按书籍 ID（及可选 kind）批量清理下载条目
    @discardableResult
    func deleteDownloadItems(forBookID bookID: String, kind: String? = nil) throws -> Int {
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.bookID == bookID })
        let items = try modelContext.fetch(desc)
        var deleted = 0
        for item in items {
            if let kind, item.kind != kind { continue }
            modelContext.delete(item)
            deleted += 1
        }
        if deleted > 0 {
            try modelContext.save()
        }
        return deleted
    }

    // MARK: - 章节与书籍播放进度后台持久化

    /// 批量写入或更新章节收听进度（按 200 条分片查询；durationMs == 0 时保留已有有效总时长）
    @discardableResult
    func upsertChapterProgress(_ patches: [ChapterProgressPatch]) throws -> Int {
        guard !patches.isEmpty else { return 0 }
        var patchByID: [String: ChapterProgressPatch] = [:]
        patchByID.reserveCapacity(patches.count)
        for patch in patches {
            patchByID["\(patch.bookID)::\(patch.chapterID)"] = patch
        }

        let existing = try fetchChapterProgress(byIDs: Array(patchByID.keys))

        var existingByID: [String: ChapterProgress] = [:]
        existingByID.reserveCapacity(existing.count)
        for record in existing {
            existingByID[record.id] = record
        }

        var written = 0
        for (recordID, patch) in patchByID {
            if let current = existingByID[recordID] {
                current.positionMs = patch.positionMs
                if patch.durationMs > 0 {
                    current.durationMs = patch.durationMs
                }
                current.isFinished = patch.isFinished
                current.updatedAt = patch.updatedAt
            } else {
                let record = ChapterProgress(
                    id: recordID,
                    bookID: patch.bookID,
                    chapterID: patch.chapterID,
                    positionMs: patch.positionMs,
                    durationMs: patch.durationMs,
                    isFinished: patch.isFinished,
                    updatedAt: patch.updatedAt
                )
                modelContext.insert(record)
            }
            written += 1
        }
        if written > 0 {
            try modelContext.save()
        }
        return written
    }

    /// R3-4：后台单次事务合并写入 `ChapterProgress` 与 `Book` 播放进度
    func persistPlaybackProgress(
        book: BookRef,
        chapter: ChapterDTO,
        chapterIndexOneBased: Int,
        totalChapters: Int,
        positionMs: Int,
        durationMs: Int,
        isFinished: Bool = false,
        volume: Double,
        skip: BookSkipConfig,
        speed: Double,
        updatedAt: Date = .now
    ) throws {
        let bookID = book.id
        let pid = "\(bookID)::\(chapter.id)"
        let resolvedDurationMs = max(0, durationMs)
        let resolvedPositionMs = max(0, positionMs)

        let progressDesc = FetchDescriptor<ChapterProgress>(predicate: #Predicate<ChapterProgress> { $0.id == pid })
        if let existingProgress = try modelContext.fetch(progressDesc).first {
            existingProgress.positionMs = resolvedPositionMs
            if resolvedDurationMs > 0 {
                existingProgress.durationMs = resolvedDurationMs
            }
            existingProgress.isFinished = isFinished || existingProgress.isFinished
            existingProgress.updatedAt = updatedAt
        } else {
            let record = ChapterProgress(
                id: pid,
                bookID: bookID,
                chapterID: chapter.id,
                positionMs: resolvedPositionMs,
                durationMs: resolvedDurationMs,
                isFinished: isFinished,
                updatedAt: updatedAt
            )
            modelContext.insert(record)
        }

        let bookDesc = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try modelContext.fetch(bookDesc).first {
            saved.lastChapterID = chapter.id
            saved.lastChapterTitle = chapter.title
            if chapterIndexOneBased > 0 { saved.lastChapterIndex = chapterIndexOneBased }
            if totalChapters > 0 { saved.totalChapters = totalChapters }
            saved.lastPositionMs = resolvedPositionMs
            saved.lastPlayedAt = updatedAt
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
                addedAt: updatedAt,
                lastChapterID: chapter.id,
                lastChapterTitle: chapter.title,
                lastChapterIndex: chapterIndexOneBased,
                totalChapters: totalChapters,
                lastPositionMs: resolvedPositionMs,
                lastPlayedAt: updatedAt,
                volume: volume,
                skipEnabled: skip.enabled,
                skipIntroSec: skip.introSec,
                skipOutroSec: skip.outroSec,
                speed: speed
            )
            modelContext.insert(historyBook)
        }

        try modelContext.save()
    }

    /// R3-4 / M-P0-5：后台执行章节进度容量边界裁剪（单书上限 + 全局上限，按 `fetchLimit` 分批拉取最旧记录删除，避免整表加载到内存）
    @discardableResult
    func enforceProgressBounds(
        bookID: String,
        maxPerBook: Int = 2000,
        maxGlobal: Int = 20000,
        batchLimit: Int = defaultBoundsBatchLimit
    ) throws -> Int {
        let safeBatchLimit = max(1, batchLimit)
        var deleted = 0

        let bookCountDesc = FetchDescriptor<ChapterProgress>(
            predicate: #Predicate<ChapterProgress> { $0.bookID == bookID }
        )
        var bookExcess = max(0, try modelContext.fetchCount(bookCountDesc) - maxPerBook)
        while bookExcess > 0 {
            var bookDesc = FetchDescriptor<ChapterProgress>(
                predicate: #Predicate<ChapterProgress> { $0.bookID == bookID },
                sortBy: [SortDescriptor(\ChapterProgress.updatedAt, order: .forward)]
            )
            bookDesc.fetchLimit = min(bookExcess, safeBatchLimit)
            let staleBatch = try modelContext.fetch(bookDesc)
            guard !staleBatch.isEmpty else { break }
            for stale in staleBatch {
                modelContext.delete(stale)
                deleted += 1
            }
            try modelContext.save()
            bookExcess -= staleBatch.count
        }

        var globalExcess = max(0, try modelContext.fetchCount(FetchDescriptor<ChapterProgress>()) - maxGlobal)
        while globalExcess > 0 {
            var globalDesc = FetchDescriptor<ChapterProgress>(
                sortBy: [SortDescriptor(\ChapterProgress.updatedAt, order: .forward)]
            )
            globalDesc.fetchLimit = min(globalExcess, safeBatchLimit)
            let staleBatch = try modelContext.fetch(globalDesc)
            guard !staleBatch.isEmpty else { break }
            for stale in staleBatch {
                modelContext.delete(stale)
                deleted += 1
            }
            try modelContext.save()
            globalExcess -= staleBatch.count
        }

        return deleted
    }

    /// 读取指定下载条目的精简状态快照（Sendable，便于后台对账与测试核验）
    func fetchDownloadItemState(itemID: String) throws -> DownloadItemStateSnapshot? {
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try modelContext.fetch(desc).first else { return nil }
        return DownloadItemStateSnapshot(
            itemID: item.id,
            state: item.state,
            lastErrorMessage: item.lastErrorMessage,
            retryCount: item.retryCount,
            localPath: item.localPath,
            bytes: item.bytes
        )
    }
}
