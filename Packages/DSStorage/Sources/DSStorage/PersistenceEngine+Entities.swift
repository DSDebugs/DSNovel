import DSCore
import Foundation
import SwiftData

/// 下载、书源、分组与搜索历史持久化扩展（拆分自 PersistenceEngine.swift 以确保单文件 ≤ 385 行）
extension PersistenceEngine {
    private static let maxSearchHistoryCount = 100

    // MARK: - Downloads（双池分查）

    public func upsertDownload(_ snapshot: DownloadRecordSnapshot) throws {
        let targetID = snapshot.id
        var desc = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == targetID })
        desc.fetchLimit = 1
        if let existing = try modelContext.fetch(desc).first {
            existing.kindRaw = snapshot.kind.rawValue
            existing.stateRaw = snapshot.state.rawValue
            existing.qualityTierRaw = snapshot.qualityTier.rawValue
            existing.retryCount = snapshot.retryCount
            existing.retryNotBefore = snapshot.retryNotBefore
            existing.localRelPath = snapshot.localRelPath
            existing.totalBytes = snapshot.totalBytes
            existing.downloadedBytes = snapshot.downloadedBytes
            existing.errorMessage = snapshot.errorMessage
            existing.updatedAt = Date()
        } else {
            modelContext.insert(DownloadRecord(snapshot: snapshot))
        }
        try saveOrRollback()
    }

    public func fetchDownloads(kind: DownloadKind?, state: DownloadState? = nil, limit: Int = 200) throws -> [DownloadRecordSnapshot] {
        var desc: FetchDescriptor<DownloadRecord>
        if let k = kind?.rawValue, let s = state?.rawValue {
            desc = FetchDescriptor<DownloadRecord>(
                predicate: #Predicate { $0.kindRaw == k && $0.stateRaw == s },
                sortBy: [SortDescriptor<DownloadRecord>(\.createdAt, order: .forward)]
            )
        } else if let k = kind?.rawValue {
            desc = FetchDescriptor<DownloadRecord>(
                predicate: #Predicate { $0.kindRaw == k },
                sortBy: [SortDescriptor<DownloadRecord>(\.createdAt, order: .forward)]
            )
        } else if let s = state?.rawValue {
            desc = FetchDescriptor<DownloadRecord>(
                predicate: #Predicate { $0.stateRaw == s },
                sortBy: [SortDescriptor<DownloadRecord>(\.createdAt, order: .forward)]
            )
        } else {
            desc = FetchDescriptor<DownloadRecord>(
                sortBy: [SortDescriptor<DownloadRecord>(\.createdAt, order: .forward)]
            )
        }
        desc.fetchLimit = max(1, limit)
        return try modelContext.fetch(desc).map { $0.toSnapshot() }
    }

    public func deleteDownload(id: String) throws {
        var desc = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        if let item = try modelContext.fetch(desc).first {
            modelContext.delete(item)
            try saveOrRollback()
        }
    }

    // MARK: - Sources（覆盖升级原地 upsert，保留用户分组/置顶/开关）

    public func upsertSource(
        meta: SourceMetaDTO,
        scriptBody: String,
        isBundled: Bool
    ) throws {
        let targetID = meta.id
        var desc = FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == targetID })
        desc.fetchLimit = 1
        let hostsJSON = String(data: (try? JSONEncoder().encode(meta.declaredHosts)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let methodsJSON = String(data: (try? JSONEncoder().encode(meta.methods)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"

        if let existing = try modelContext.fetch(desc).first {
            if existing.isBundled && !isBundled {
                throw NSError(
                    domain: "DSStorage.SourceConflict",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "书源 ID 与内置书源冲突（\(meta.id)），禁止覆盖内置源"]
                )
            }
            existing.name = meta.name
            existing.version = meta.version
            existing.author = meta.author
            existing.summary = meta.summary
            existing.scriptBody = scriptBody
            existing.declaredHostsJSON = hostsJSON
            existing.permissionModeRaw = meta.permissionMode.rawValue
            existing.methodsJSON = methodsJSON
            existing.loginURL = meta.loginURL
            existing.updatedAt = Date()
            // 原地保留 existing.isEnabled / isPinned / groupName / sortOrder
        } else {
            let record = SourceRecord(
                id: meta.id,
                name: meta.name,
                version: meta.version,
                author: meta.author,
                summary: meta.summary,
                scriptBody: scriptBody,
                declaredHostsJSON: hostsJSON,
                permissionModeRaw: meta.permissionMode.rawValue,
                methodsJSON: methodsJSON,
                isEnabled: meta.isEnabled,
                isPinned: meta.isPinned,
                groupName: meta.groupName,
                sortOrder: meta.sortOrder,
                loginURL: meta.loginURL,
                isBundled: isBundled
            )
            modelContext.insert(record)
        }
        try saveOrRollback()
    }

    public func fetchAllSources() throws -> [(meta: SourceMetaDTO, scriptBody: String)] {
        let desc = FetchDescriptor<SourceRecord>(
            sortBy: [
                SortDescriptor<SourceRecord>(\.sortOrder, order: .forward),
                SortDescriptor<SourceRecord>(\.name, order: .forward)
            ]
        )
        let rows = try modelContext.fetch(desc)
        let pinned = rows.filter(\.isPinned)
        let unpinned = rows.filter { !$0.isPinned }
        return (pinned + unpinned).map { ($0.toMetaDTO(), $0.scriptBody) }
    }

    public func deleteSource(id: String) throws {
        var desc = FetchDescriptor<SourceRecord>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        if let row = try modelContext.fetch(desc).first {
            modelContext.delete(row)
            try saveOrRollback()
        }
    }

    // MARK: - Shelf Groups（AUD-41：删除分组时同步重置关联书籍 shelfGroupID）

    public func deleteShelfGroup(id: String) throws {
        let targetID = id
        var grpDesc = FetchDescriptor<ShelfGroupEntity>(predicate: #Predicate { $0.id == targetID })
        grpDesc.fetchLimit = 1
        if let group = try modelContext.fetch(grpDesc).first {
            modelContext.delete(group)
        }
        let bookDesc = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.shelfGroupID == targetID })
        let affectedBooks = try modelContext.fetch(bookDesc)
        for book in affectedBooks {
            book.shelfGroupID = "default"
        }
        try saveOrRollback()
    }

    // MARK: - Search History

    public func recordSearchKeyword(_ keyword: String) throws {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var desc = FetchDescriptor<SearchHistoryEntity>(predicate: #Predicate { $0.keyword == trimmed })
        desc.fetchLimit = 1
        if let existing = try modelContext.fetch(desc).first {
            existing.searchedAt = Date()
        } else {
            modelContext.insert(SearchHistoryEntity(keyword: trimmed))
        }
        // AUD-85：保留最近 100 条搜索记录，自动裁剪超限旧记录
        let allDesc = FetchDescriptor<SearchHistoryEntity>(
            sortBy: [SortDescriptor<SearchHistoryEntity>(\.searchedAt, order: .reverse)]
        )
        let allItems = try modelContext.fetch(allDesc)
        if allItems.count > Self.maxSearchHistoryCount {
            for stale in allItems.dropFirst(Self.maxSearchHistoryCount) {
                modelContext.delete(stale)
            }
        }
        try saveOrRollback()
    }

    public func fetchSearchHistory(limit: Int = 20) throws -> [String] {
        var desc = FetchDescriptor<SearchHistoryEntity>(
            sortBy: [SortDescriptor<SearchHistoryEntity>(\.searchedAt, order: .reverse)]
        )
        desc.fetchLimit = max(1, limit)
        return try modelContext.fetch(desc).map(\.keyword)
    }

    public func clearSearchHistory() throws {
        let all = try modelContext.fetch(FetchDescriptor<SearchHistoryEntity>())
        for item in all { modelContext.delete(item) }
        try saveOrRollback()
    }
}
