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

    /// 独立核算的下载条目音质/码率角标（对所有书源生效，绝不直接显示用户所选档位）
    static func bitrateBadgeText(forItem item: DownloadItem, inProgressBitrateKbps: Int? = nil) -> String {
        if item.actualBitrateKbps > 0 {
            return AudioQualityTier.badgeText(forDetectedBitrateKbps: item.actualBitrateKbps)
        }
        let dur = item.actualDurationSec > 1 ? item.actualDurationSec : item.expectedDurationSec
        if item.bytes > 0, dur > 1,
           let computed = AudioQualityTier.computedBitrateKbps(bytes: item.bytes, durationSec: dur),
           computed > 0 {
            return AudioQualityTier.badgeText(forDetectedBitrateKbps: computed)
        }
        if let live = inProgressBitrateKbps, live > 0 {
            return AudioQualityTier.badgeText(forDetectedBitrateKbps: live)
        }
        if item.bytes > 0 {
            return AudioQualityTier.formattedSizeFallback(bytes: item.bytes)
        }
        return ""
    }

    static func qualityTierLabel(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tier = AudioQualityTier(rawValue: trimmed) else {
            return ""
        }
        switch tier {
        case .auto: return "智能"
        case .std: return "标准"
        case .hd: return "高清"
        case .uhd: return "超清"
        }
    }

    static func qualityLabel(forChainCode code: String) -> String {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "M4A_24", "SAVER", "STD": return "标准"
        case "M4A_64", "STANDARD", "HD": return "高清"
        case "M4A_128", "HIGH", "LOSSLESS", "UHD": return "超清"
        default: return ""
        }
    }

    static func qualityLabel(forItem item: DownloadItem) -> String {
        let byCode = qualityLabel(forChainCode: item.qualityCodeSnapshot)
        return byCode.isEmpty ? qualityTierLabel(for: item.qualityTierSnapshot) : byCode
    }

    static func isItemStale(_ item: DownloadItem, currentTierRaw: String) -> Bool {
        guard QualityPolicy.sourceHasMultipleBitrates(sourceID: item.sourceID) else { return false }
        guard item.state == "completed" || (!item.localPath.isEmpty && item.state != "failed") else { return false }
        if item.qualityIsStale { return true }
        guard !item.qualityTierSnapshot.isEmpty else { return false }
        return item.qualityTierSnapshot != currentTierRaw
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

    static func activeStateLabel(for state: String) -> String {
        switch state {
        case "waitingWiFi":
            return "等待 Wi-Fi"
        case "paused":
            return "已暂停"
        case "queued":
            return "排队中"
        default:
            return "下载中"
        }
    }

    static func sortedCompletedItems(_ items: [DownloadItem], forBookID bookID: String) -> [DownloadItem] {
        var indexByChapterID: [String: Int] = [:]
        if let cached = ChapterCacheStore.loadChapters(for: bookID), !cached.isEmpty {
            indexByChapterID.reserveCapacity(cached.count)
            for (offset, chapter) in cached.enumerated() {
                if indexByChapterID[chapter.id] == nil {
                    indexByChapterID[chapter.id] = chapter.index >= 0 ? chapter.index : offset
                }
            }
        }
        return items.sorted { lhs, rhs in
            let lIdx = indexByChapterID[lhs.chapterID]
            let rIdx = indexByChapterID[rhs.chapterID]
            switch (lIdx, rIdx) {
            case let (li?, ri?):
                if li != ri {
                    return li < ri
                }
                return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                let cmp = lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.chapterID < rhs.chapterID
            }
        }
    }

    static func clearAllAlertTitle(
        bookTitle: String,
        completedCount: Int,
        activeCount: Int,
        failedCount: Int,
        formattedBytes: String
    ) -> String {
        var segments: [String] = []
        if completedCount > 0 {
            let trimmedBytes = formattedBytes.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBytes.isEmpty {
                segments.append("已下载 \(completedCount) 章")
            } else {
                segments.append("已下载 \(completedCount) 章 · \(trimmedBytes)")
            }
        }
        if activeCount > 0 {
            segments.append("进行中 \(activeCount) 章")
        }
        if failedCount > 0 {
            segments.append("失败 \(failedCount) 章")
        }
        if segments.isEmpty {
            return "确认清空《\(bookTitle)》全部下载记录？"
        }
        return "确认清空《\(bookTitle)》全部下载记录（\(segments.joined(separator: "、"))）？"
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
