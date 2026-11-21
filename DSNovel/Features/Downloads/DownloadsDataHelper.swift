import Foundation
import SwiftData

@MainActor
enum DownloadsDataHelper {
    /// 7-2：下载管理 UI 严格过滤 `kind == "manual"`，避免暴露 `precache` 预缓存条目
    static func partitionItems(_ items: [DownloadItem]) -> (active: [DownloadItem], failed: [DownloadItem]) {
        let manualItems = items.filter { $0.kind == "manual" }
        let active = manualItems.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi" || $0.state == "paused"
        }
        let failed = manualItems.filter { $0.state == "failed" }
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

    static func chapterIndexMap(from chapters: [ChapterDTO]) -> [String: Int] {
        guard !chapters.isEmpty else { return [:] }
        var indexByChapterID: [String: Int] = [:]
        indexByChapterID.reserveCapacity(chapters.count)
        for (offset, chapter) in chapters.enumerated() {
            if indexByChapterID[chapter.id] == nil {
                indexByChapterID[chapter.id] = chapter.index >= 0 ? chapter.index : offset
            }
        }
        return indexByChapterID
    }

    static func sortedCompletedItems(_ items: [DownloadItem], indexByChapterID: [String: Int]) -> [DownloadItem] {
        items.sorted { lhs, rhs in
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

    static func sortedCompletedItems(_ items: [DownloadItem], forBookID bookID: String) -> [DownloadItem] {
        let indexByChapterID = chapterIndexMap(from: ChapterCacheStore.loadChapters(for: bookID) ?? [])
        return sortedCompletedItems(items, indexByChapterID: indexByChapterID)
    }

    /// 用于驱动 BookDownloadDetailView `.task(id:)` 的签名，避免在 `body` 中反复排序
    static func completedSignature(for items: [DownloadItem], bookID: String) -> String {
        var parts: [String] = []
        parts.reserveCapacity(items.count + 2)
        parts.append(bookID)
        parts.append(String(items.count))
        for item in items {
            parts.append(item.chapterID)
        }
        return parts.joined(separator: "|")
    }

    /// 当已缓存的排序结果与当前 live 集合一致时直接复用，否则回退 live 列表避免渲染已删除对象
    static func displayCompletedItems(cached: [DownloadItem], live: [DownloadItem]) -> [DownloadItem] {
        guard !live.isEmpty else { return [] }
        guard cached.count == live.count else { return live }
        let liveIDs = Set(live.map(\.id))
        for item in cached {
            if item.isDeleted || !liveIDs.contains(item.id) {
                return live
            }
        }
        return cached
    }

    /// 自定义区间数字输入校验与同步纠偏
    static func clampedRange(
        startText: String,
        endText: String,
        fallbackStart: Int,
        fallbackEnd: Int,
        totalCount: Int
    ) -> (start: Int, end: Int) {
        let upper = max(1, totalCount)
        let parsedStart = Int(startText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallbackStart
        let parsedEnd = Int(endText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallbackEnd
        let clampedStart = min(max(1, parsedStart), upper)
        let clampedEnd = min(max(clampedStart, parsedEnd), upper)
        return (clampedStart, clampedEnd)
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

    static func buildBookRef(
        bookID: String,
        bookTitle: String,
        items: [DownloadItem],
        cachedChapterCount: Int? = nil
    ) -> BookRef {
        if let saved = LibraryStore.shared.book(for: bookID) {
            return saved.bookRef
        }
        let parts = bookID.components(separatedBy: "::")
        let sourceID = parts.first ?? "local"
        let bookURL = parts.count > 1 ? parts.dropFirst().joined(separator: "::") : bookID
        let knownCount = cachedChapterCount ?? (ChapterCacheStore.loadChapters(for: bookID)?.count ?? 0)
        return BookRef(
            id: bookID,
            sourceID: sourceID,
            bookURL: bookURL,
            title: bookTitle,
            chapterCount: max(items.count, knownCount)
        )
    }

    /// 7-4：异步读取 `ChapterCacheStore.loadChaptersAsync`，消除点击离线章节时的主线程磁盘 I/O 卡顿
    static func playDownloadedChapterAsync(_ item: DownloadItem, allBookItems: [DownloadItem]) async {
        let bookID = item.bookID
        let bookTitle = item.bookTitle
        let chapterID = item.chapterID
        let chapterTitle = item.chapterTitle
        let fallbackQueue: [ChapterDTO] = allBookItems.enumerated().map { idx, dl in
            ChapterDTO(index: idx, title: dl.chapterTitle, url: dl.chapterID)
        }
        let savedPos = ChapterProgressCache.shared.progress(bookID: bookID, chapterID: chapterID)?.positionMs ?? 0
        DSHapticPolicy.fire(.chapterSwitch)

        let cachedChapters = await ChapterCacheStore.loadChaptersAsync(for: bookID) ?? []
        let ref = buildBookRef(
            bookID: bookID,
            bookTitle: bookTitle,
            items: allBookItems,
            cachedChapterCount: cachedChapters.count
        )
        let queue = cachedChapters.isEmpty ? fallbackQueue : cachedChapters
        let target = queue.first(where: { $0.id == chapterID })
            ?? ChapterDTO(index: 0, title: chapterTitle, url: chapterID)
        PlayerEngine.shared.startPlayback(
            book: ref,
            chapters: queue.isEmpty ? [target] : queue,
            startChapter: target,
            initialPositionMs: savedPos
        )
    }

    static func playDownloadedChapter(_ item: DownloadItem, allBookItems: [DownloadItem]) {
        Task { @MainActor in
            await playDownloadedChapterAsync(item, allBookItems: allBookItems)
        }
    }
}
