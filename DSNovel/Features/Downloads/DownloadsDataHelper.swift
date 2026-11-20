import Foundation
import SwiftData

@MainActor
enum DownloadsDataHelper {
    static func partitionItems(_ items: [DownloadItem]) -> (active: [DownloadItem], failed: [DownloadItem]) {
        let active = items.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi" || $0.state == "paused"
        }
        let failed = items.filter { $0.state == "failed" }
        return (active, failed)
    }

    static func partitionItemsForBook(_ bookID: String?, from items: [DownloadItem]) -> (active: [DownloadItem], failed: [DownloadItem], completed: [DownloadItem]) {
        guard let bookID, !bookID.isEmpty else { return ([], [], []) }
        let bookItems = items.filter { $0.bookID == bookID && $0.kind == "manual" }
        let active = bookItems.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi" || $0.state == "paused"
        }
        let failed = bookItems.filter { $0.state == "failed" }
        let completed = bookItems.filter { $0.state == "completed" }
        return (active, failed, completed)
    }

    static func qualityTierLabel(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tier = AudioQualityTier(rawValue: trimmed) else {
            return ""
        }
        switch tier.normalizedForSelection {
        case .auto: return "智能"
        case .dataSaver: return "省流"
        case .standard: return "标准"
        case .high, .lossless: return "高清"
        case .losslessHQ: return "无损"
        }
    }

    static func qualityLabel(forChainCode code: String) -> String {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "M4A_24", "SAVER": return "省流"
        case "M4A_64", "STANDARD": return "标准"
        case "M4A_128", "HIGH": return "高清"
        case "LOSSLESS": return "无损"
        default: return ""
        }
    }

    static func qualityLabel(forItem item: DownloadItem) -> String {
        let byCode = qualityLabel(forChainCode: item.qualityCodeSnapshot)
        return byCode.isEmpty ? qualityTierLabel(for: item.qualityTierSnapshot) : byCode
    }

    static func isItemStale(_ item: DownloadItem, currentTierRaw: String) -> Bool {
        guard item.state == "completed" || (!item.localPath.isEmpty && item.state != "failed") else { return false }
        if item.qualityIsStale { return true }
        return !item.qualityTierSnapshot.isEmpty && item.qualityTierSnapshot != currentTierRaw
    }

    static func staleCount(in items: [DownloadItem], currentTierRaw: String) -> Int {
        var count = 0
        for item in items {
            if isItemStale(item, currentTierRaw: currentTierRaw) {
                count += 1
            }
        }
        return count
    }

    /// 统计某本书中所有“磁盘有本地文件且为手动下载”的旧音质章节数（含重下窗口中的旧文件，列表分区语义保持不变）
    static func staleCount(forBookID bookID: String?, in allItems: [DownloadItem], currentTierRaw: String) -> Int {
        guard let bookID, !bookID.isEmpty else { return 0 }
        let candidates = allItems.filter { $0.bookID == bookID && $0.kind == "manual" && !$0.localPath.isEmpty && $0.state != "failed" }
        return staleCount(in: candidates, currentTierRaw: currentTierRaw)
    }

    /// 统计本书磁盘上所有手动离线文件占用字节（含重下窗口内保留的旧文件，与 DownloadSummary.totalBytes 口径一致）
    static func totalLocalBytes(forBookID bookID: String?, in allItems: [DownloadItem]) -> Int64 {
        guard let bookID, !bookID.isEmpty else { return 0 }
        return allItems
            .filter { $0.bookID == bookID && $0.kind == "manual" && !$0.localPath.isEmpty }
            .reduce(Int64(0)) { $0 + $1.bytes }
    }

    static func sortedSummaries(_ map: [String: DownloadSummary]) -> [DownloadSummary] {
        map.values
            .filter { $0.completedCount > 0 || $0.activeCount > 0 || $0.failedCount > 0 }
            .sorted { a, b in
                let aHasOffline = a.completedCount > 0 || a.totalBytes > 0
                let bHasOffline = b.completedCount > 0 || b.totalBytes > 0
                if aHasOffline != bHasOffline {
                    return aHasOffline
                }
                return a.bookTitle.localizedStandardCompare(b.bookTitle) == .orderedAscending
            }
    }

    static func itemsForBook(_ bookID: String, from items: [DownloadItem]) -> [DownloadItem] {
        items.filter { $0.bookID == bookID && $0.state == "completed" && $0.kind == "manual" }
    }

    static func buildBookRef(bookID: String, bookTitle: String, items: [DownloadItem]) -> BookRef {
        if let saved = LibraryStore.shared.book(for: bookID) {
            return saved.bookRef
        }
        let parts = bookID.components(separatedBy: "::")
        let sourceID = parts.first ?? "local"
        let bookURL = parts.count > 1 ? parts.dropFirst().joined(separator: "::") : bookID
        return BookRef(
            id: bookID,
            sourceID: sourceID,
            bookURL: bookURL,
            title: bookTitle,
            chapterCount: max(items.count, ChapterCacheStore.loadChapters(for: bookID)?.count ?? 0)
        )
    }

    static func playDownloadedChapter(_ item: DownloadItem, allBookItems: [DownloadItem]) {
        let ref = buildBookRef(bookID: item.bookID, bookTitle: item.bookTitle, items: allBookItems)
        let cachedChapters = ChapterCacheStore.loadChapters(for: item.bookID) ?? []
        let queue: [ChapterDTO]
        if !cachedChapters.isEmpty {
            queue = cachedChapters
        } else {
            queue = allBookItems.enumerated().map { idx, dl in
                ChapterDTO(index: idx, title: dl.chapterTitle, url: dl.chapterID)
            }
        }
        let target = queue.first(where: { $0.id == item.chapterID })
            ?? ChapterDTO(index: 0, title: item.chapterTitle, url: item.chapterID)
        let savedPos = ChapterProgressCache.shared.progress(bookID: item.bookID, chapterID: item.chapterID)?.positionMs ?? 0
        DSHapticPolicy.fire(.chapterSwitch)
        PlayerEngine.shared.startPlayback(
            book: ref,
            chapters: queue.isEmpty ? [target] : queue,
            startChapter: target,
            initialPositionMs: savedPos
        )
    }
}
