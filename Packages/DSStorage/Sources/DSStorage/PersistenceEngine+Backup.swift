import DSCore
import Foundation
import SwiftData

/// 书架与进度版本化 JSON 导出/导入扩展（拆分自 PersistenceEngine 以确保单文件 ≤ 385 行）
extension PersistenceEngine {
    private static let batchPrefetchChunkSize = 200

    private func prefetchMap<T: PersistentModel>(
        ids: [String],
        fetchChunk: ([String]) throws -> [T],
        key: (T) -> String
    ) throws -> [String: T] {
        let uniqueIDs = Array(Set(ids))
        var result: [String: T] = [:]
        result.reserveCapacity(uniqueIDs.count)
        var start = 0
        while start < uniqueIDs.count {
            let end = min(start + Self.batchPrefetchChunkSize, uniqueIDs.count)
            let chunk = Array(uniqueIDs[start..<end])
            for row in try fetchChunk(chunk) {
                result[key(row)] = row
            }
            start = end
        }
        return result
    }

    public func exportLibraryBackup(appVersion: String) throws -> LibraryBackupPayload {
        let books = try modelContext.fetch(FetchDescriptor<BookEntity>())
        let mapped = books.map { b in
            LibraryBackupPayload.BackupBook(
                id: b.id,
                sourceID: b.sourceID,
                sourceName: b.sourceName,
                bookURL: b.bookURL,
                title: b.title,
                author: b.author,
                narrator: b.narrator,
                coverURL: b.coverURL,
                inShelf: b.inShelf,
                isPinned: b.isPinned,
                shelfGroupName: b.shelfGroupID,
                lastPlayedAt: b.lastPlayedAt,
                lastChapterID: b.lastChapterID.isEmpty ? nil : b.lastChapterID,
                lastChapterIndex: b.lastChapterIndex,
                lastChapterTitle: b.lastChapterTitle,
                lastPositionMs: b.lastPositionMs,
                lastDurationMs: b.lastDurationMs > 0 ? b.lastDurationMs : nil,
                skipConfig: SkipConfigDTO(introSeconds: b.skipIntroSeconds, outroSeconds: b.skipOutroSeconds)
            )
        }
        let groupDesc = FetchDescriptor<ShelfGroupEntity>(
            sortBy: [SortDescriptor<ShelfGroupEntity>(\.sortOrder, order: .forward)]
        )
        let groups = try modelContext.fetch(groupDesc).map {
            LibraryBackupPayload.BackupShelfGroup(id: $0.id, name: $0.name, sortOrder: $0.sortOrder)
        }
        return LibraryBackupPayload(
            appVersion: appVersion,
            books: mapped,
            shelfGroups: groups.isEmpty ? nil : groups
        )
    }

    public func importLibraryBackup(_ payload: LibraryBackupPayload) throws -> Int {
        let hasGroups = !(payload.shelfGroups?.isEmpty ?? true)
        guard !payload.books.isEmpty || hasGroups else { return 0 }

        if let groups = payload.shelfGroups, !groups.isEmpty {
            var existingGroups = try prefetchMap(
                ids: groups.map(\.id),
                fetchChunk: { chunk in
                    try modelContext.fetch(FetchDescriptor<ShelfGroupEntity>(predicate: #Predicate { chunk.contains($0.id) }))
                },
                key: \.id
            )
            for grp in groups {
                if let existing = existingGroups[grp.id] {
                    existing.name = grp.name
                    existing.sortOrder = grp.sortOrder
                } else {
                    let created = ShelfGroupEntity(id: grp.id, name: grp.name, sortOrder: grp.sortOrder)
                    modelContext.insert(created)
                    existingGroups[grp.id] = created
                }
            }
        }

        let cappedBooks = Array(payload.books.prefix(5000))
        var existingBooks = try prefetchMap(
            ids: cappedBooks.map(\.id),
            fetchChunk: { chunk in
                try modelContext.fetch(FetchDescriptor<BookEntity>(predicate: #Predicate { chunk.contains($0.id) }))
            },
            key: \.id
        )

        var importedCount = 0
        let now = Date()
        for item in cappedBooks {
            let entity: BookEntity
            if let existing = existingBooks[item.id] {
                if !item.sourceID.isEmpty { existing.sourceID = item.sourceID }
                if !item.sourceName.isEmpty { existing.sourceName = item.sourceName }
                if !item.bookURL.isEmpty { existing.bookURL = item.bookURL }
                if !item.title.isEmpty { existing.title = item.title }
                if !item.author.isEmpty { existing.author = item.author }
                if !item.narrator.isEmpty { existing.narrator = item.narrator }
                if !item.coverURL.isEmpty { existing.coverURL = item.coverURL }
                existing.inShelf = existing.inShelf || item.inShelf
                if existing.inShelf && existing.addedToShelfAt == nil {
                    existing.addedToShelfAt = now
                }
                entity = existing
            } else {
                let created = BookEntity(
                    id: item.id,
                    sourceID: item.sourceID,
                    sourceName: item.sourceName,
                    bookURL: item.bookURL,
                    title: item.title,
                    author: item.author,
                    narrator: item.narrator,
                    coverURL: item.coverURL,
                    inShelf: item.inShelf,
                    addedToShelfAt: item.inShelf ? now : nil
                )
                modelContext.insert(created)
                existingBooks[item.id] = created
                entity = created
            }
            // P1-9 / P1-06 / AUD-39：按 lastPlayedAt 合并取较新进度，保护书架状态、置顶一致性与本地跳过配置
            let incomingNewer: Bool = {
                guard let incDate = item.lastPlayedAt else { return false }
                guard let curDate = entity.lastPlayedAt else { return true }
                return incDate >= curDate
            }()
            entity.isPinned = entity.inShelf ? (entity.isPinned || item.isPinned) : false
            if (incomingNewer || entity.shelfGroupID.isEmpty || entity.shelfGroupID == "default") && !item.shelfGroupName.isEmpty {
                entity.shelfGroupID = item.shelfGroupName
            }
            if incomingNewer {
                let safeChapterIndex = max(0, item.lastChapterIndex)
                let chapterChanged = safeChapterIndex != entity.lastChapterIndex
                entity.lastPlayedAt = item.lastPlayedAt
                if let cid = item.lastChapterID, !cid.isEmpty {
                    entity.lastChapterID = cid
                } else if chapterChanged {
                    entity.lastChapterID = ""
                    entity.lastDurationMs = max(0, item.lastDurationMs ?? 0)
                }
                entity.lastChapterIndex = safeChapterIndex
                entity.lastChapterTitle = item.lastChapterTitle
                entity.lastPositionMs = max(0, item.lastPositionMs)
                if let dur = item.lastDurationMs, dur > 0 {
                    entity.lastDurationMs = dur
                }
            }
            let localSkipConfigured = (entity.skipIntroSeconds > 0 || entity.skipOutroSeconds > 0)
            if incomingNewer || !localSkipConfigured {
                entity.skipIntroSeconds = max(0, min(600, item.skipConfig.introSeconds))
                entity.skipOutroSeconds = max(0, min(600, item.skipConfig.outroSeconds))
            }
            importedCount += 1
        }
        try saveOrRollback()
        return importedCount
    }

    /// 专用书源整理持久化接口（ARC-01：与脚本覆盖升级 upsertSource 彻底解耦，确保拖拽排序/移组/启停 100% 落盘）
    public func updateSourceOrganization(
        id: String,
        isEnabled: Bool? = nil,
        isPinned: Bool? = nil,
        groupName: String? = nil,
        sortOrder: Int? = nil
    ) throws {
        let targetID = id
        var desc = FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == targetID })
        desc.fetchLimit = 1
        guard let existing = try modelContext.fetch(desc).first else { return }
        if let en = isEnabled { existing.isEnabled = en }
        if let pin = isPinned { existing.isPinned = pin }
        if let grp = groupName { existing.groupName = grp }
        if let ord = sortOrder { existing.sortOrder = ord }
        existing.updatedAt = Date()
        try saveOrRollback()
    }

    /// 最近一次播放会话快照（供冷启动恢复播放器书籍、章节与进度）
    public struct LastPlaybackSessionSnapshot: Sendable, Equatable {
        public let book: BookSummaryDTO
        public let chapterID: String
        public let chapterIndex: Int
        public let chapterTitle: String
        public let positionMs: Int
        public let durationMs: Int
    }

    /// 读取最近一次播放的书籍与章节进度（索引排序 fetchLimit=1）
    public func fetchLatestPlaybackSession() -> LastPlaybackSessionSnapshot? {
        var desc = FetchDescriptor<BookEntity>(
            predicate: #Predicate { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor<BookEntity>(\.lastPlayedAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        let fetchedBook: BookEntity?
        do {
            fetchedBook = try modelContext.fetch(desc).first
        } catch {
            Self.logger.error("fetchLatestPlaybackSession failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let book = fetchedBook else { return nil }
        return LastPlaybackSessionSnapshot(
            book: book.toSummaryDTO(),
            chapterID: book.lastChapterID,
            chapterIndex: book.lastChapterIndex,
            chapterTitle: book.lastChapterTitle,
            positionMs: book.lastPositionMs,
            durationMs: book.lastDurationMs
        )
    }

    /// 读取单本书最近收听章节位置（UI-03：供书籍详情页显示「继续收听 · 第 N 章」）
    public func fetchBookLastPlayback(bookID: String) -> (chapterIndex: Int, chapterTitle: String, positionMs: Int)? {
        let targetID = bookID
        var desc = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == targetID })
        desc.fetchLimit = 1
        let fetchedBook: BookEntity?
        do {
            fetchedBook = try modelContext.fetch(desc).first
        } catch {
            Self.logger.error("fetchBookLastPlayback failed for book=\(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let book = fetchedBook, book.lastPlayedAt != nil else { return nil }
        return (book.lastChapterIndex, book.lastChapterTitle, book.lastPositionMs)
    }

    /// 分页拉取全部下载记录（ARC-06 / P0-07：统一 effectivePageSize 并以 id 稳定排序）
    public func fetchAllDownloadsPaginated(pageSize: Int = 400) throws -> [DownloadRecordSnapshot] {
        let effectivePageSize = max(50, pageSize)
        var offset = 0
        var all: [DownloadRecordSnapshot] = []
        while true {
            var desc = FetchDescriptor<DownloadRecord>(
                sortBy: [
                    SortDescriptor<DownloadRecord>(\.createdAt, order: .forward),
                    SortDescriptor<DownloadRecord>(\.id, order: .forward)
                ]
            )
            desc.fetchLimit = effectivePageSize
            desc.fetchOffset = offset
            let batch = try modelContext.fetch(desc)
            if batch.isEmpty { break }
            all.append(contentsOf: batch.map { $0.toSnapshot() })
            if batch.count < effectivePageSize { break }
            offset += effectivePageSize
        }
        return all
    }

    /// 单事务批量写入下载记录（SYS5-02 / AUD-39：200 条分块预取消除 N+1，合并为 1 次原子提交）
    public func upsertDownloadsBatch(_ snapshots: [DownloadRecordSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        var existingMap = try prefetchMap(
            ids: snapshots.map(\.id),
            fetchChunk: { chunk in
                try modelContext.fetch(FetchDescriptor<DownloadRecord>(predicate: #Predicate { chunk.contains($0.id) }))
            },
            key: \.id
        )
        let now = Date()
        for snapshot in snapshots {
            if let existing = existingMap[snapshot.id] {
                existing.kindRaw = snapshot.kind.rawValue
                existing.stateRaw = snapshot.state.rawValue
                existing.qualityTierRaw = snapshot.qualityTier.rawValue
                existing.retryCount = snapshot.retryCount
                existing.retryNotBefore = snapshot.retryNotBefore
                existing.localRelPath = snapshot.localRelPath
                existing.totalBytes = snapshot.totalBytes
                existing.downloadedBytes = snapshot.downloadedBytes
                existing.errorMessage = snapshot.errorMessage
                existing.updatedAt = now
            } else {
                let created = DownloadRecord(snapshot: snapshot)
                modelContext.insert(created)
                existingMap[snapshot.id] = created
            }
        }
        try saveOrRollback()
    }

    /// 单事务批量修改书架归属（SYS5-02 / AUD-39：200 条分块预取消除 N+1）
    public func setInShelfBatch(bookIDs: [String], inShelf: Bool) throws {
        guard !bookIDs.isEmpty else { return }
        let existingMap = try prefetchMap(
            ids: bookIDs,
            fetchChunk: { chunk in
                try modelContext.fetch(FetchDescriptor<BookEntity>(predicate: #Predicate { chunk.contains($0.id) }))
            },
            key: \.id
        )
        let now = Date()
        for bookID in bookIDs {
            if let book = existingMap[bookID] {
                book.inShelf = inShelf
                if inShelf {
                    book.addedToShelfAt = book.addedToShelfAt ?? now
                } else {
                    book.isPinned = false
                }
            }
        }
        try saveOrRollback()
    }

    /// 单事务批量删除下载记录（B8-02 / AUD-39：200 条分块预取消除 N+1）
    public func deleteDownloadsBatch(ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var existingMap = try prefetchMap(
            ids: ids,
            fetchChunk: { chunk in
                try modelContext.fetch(FetchDescriptor<DownloadRecord>(predicate: #Predicate { chunk.contains($0.id) }))
            },
            key: \.id
        )
        var deleted = 0
        for targetID in ids {
            if let existing = existingMap.removeValue(forKey: targetID) {
                modelContext.delete(existing)
                deleted += 1
            }
        }
        if deleted > 0 {
            try saveOrRollback()
        }
        return deleted
    }

    /// 单事务批量更新书源整理结果（B9-04 / AUD-39：200 条分块预取消除 N+1）
    public func updateSourcesOrganizationBatch(_ updates: [SourceMetaDTO]) throws {
        guard !updates.isEmpty else { return }
        let existingMap = try prefetchMap(
            ids: updates.map(\.id),
            fetchChunk: { chunk in
                try modelContext.fetch(FetchDescriptor<SourceRecord>(predicate: #Predicate { chunk.contains($0.id) }))
            },
            key: \.id
        )
        let now = Date()
        for item in updates {
            if let existing = existingMap[item.id] {
                existing.isEnabled = item.isEnabled
                existing.isPinned = item.isPinned
                existing.groupName = item.groupName
                existing.sortOrder = item.sortOrder
                existing.updatedAt = now
            }
        }
        try saveOrRollback()
    }

    /// P1-15：内置书源升级对账，自动移除已从新内置包中剔除的旧内置源
    public func pruneRemovedBundledSources(keepingIDs: Set<String>) throws -> Int {
        let pred = #Predicate<SourceRecord> { $0.isBundled == true }
        let allBundled = try modelContext.fetch(FetchDescriptor<SourceRecord>(predicate: pred))
        var removed = 0
        for rec in allBundled where !keepingIDs.contains(rec.id) {
            modelContext.delete(rec)
            removed += 1
        }
        if removed > 0 { try saveOrRollback() }
        return removed
    }
}
