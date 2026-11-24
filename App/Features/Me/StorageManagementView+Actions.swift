import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import Foundation
import SwiftUI

extension StoragePrefsView {
    struct BreakdownSegment: Identifiable {
        let id: Int
        let color: Color
        let width: CGFloat
    }

    func computeBreakdownSegments(totalWidth: CGFloat, spacing: CGFloat) -> [BreakdownSegment] {
        var raw: [(Int, Int64, Color)] = []
        if offlineTotalBytes > 0 { raw.append((0, offlineTotalBytes, DSColors.accent)) }
        if coverCacheBytes > 0 { raw.append((1, coverCacheBytes, Color.blue)) }
        if chapterCacheBytes > 0 { raw.append((2, chapterCacheBytes, DSColors.inkSecondary.opacity(0.65))) }
        guard !raw.isEmpty else { return [] }
        let totalGap = CGFloat(max(0, raw.count - 1)) * spacing
        let usable = max(0, totalWidth - totalGap)
        let denom = max(1, appTotalBytes)
        let minSegW: CGFloat = raw.count > 1 ? 3 : 0
        var widths: [CGFloat] = []
        var sumW: CGFloat = 0
        for item in raw {
            let w = max(minSegW, usable * CGFloat(item.1) / CGFloat(denom))
            widths.append(w)
            sumW += w
        }
        let scale = sumW > usable && sumW > 0 ? (usable / sumW) : 1
        var result: [BreakdownSegment] = []
        for idx in raw.indices {
            result.append(BreakdownSegment(id: raw[idx].0, color: raw[idx].2, width: max(0, widths[idx] * scale)))
        }
        return result
    }

    var downloadsSubtitle: String {
        var parts: [String] = []
        if downloadedBooksCount > 0 {
            parts.append("已下载 \(downloadedBooksCount) 本")
        }
        if activeDownloadsCount > 0 {
            parts.append("进行中 \(activeDownloadsCount) 项")
        }
        if failedDownloadsCount > 0 {
            parts.append("失败 \(failedDownloadsCount) 项")
        }
        return parts.isEmpty ? "管理离线章节与下载队列" : parts.joined(separator: " · ")
    }

    func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    func refreshStorageStats() async {
        let records = downloads.manualRecords
        let partitioned = DownloadsDataHelper.partitionRecords(records)
        activeDownloadsCount = partitioned.active.count
        failedDownloadsCount = partitioned.failed.count
        downloadedBooksCount = DownloadsDataHelper.bookSummaries(from: records).count
        manualAudioBytes = DownloadsDataHelper.manualCompletedBytes(from: records)
        freeDiskBytes = DownloadsDataHelper.freeDiskBytes()

        if let precacheRecords = try? await container.persistence.fetchDownloads(kind: .precache, limit: 500) {
            precacheBytes = precacheRecords.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        } else {
            precacheBytes = 0
        }

        async let cover = container.coverPipeline.diskUsageBytes()
        async let chapter = container.chapterCache.diskUsageBytes()
        coverCacheBytes = await cover
        chapterCacheBytes = await chapter
    }

    private func protectedChapterCacheBookIDs() -> Set<String> {
        var ids = Set(downloads.manualRecords.filter { $0.state == .completed }.map(\.bookID))
        if let activeID = container.playback.currentBook?.id {
            ids.insert(activeID)
        }
        return ids
    }

    func clearPrecacheOnly() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        await downloads.clearAllPrecache()
        await refreshStorageStats()
        DSHaptics.selection()
        banner.show("已清理自动预缓存", tone: .success)
    }

    func clearCoverCache() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        await container.coverPipeline.clearAll()
        CoverAmbientColor.clearCache()
        await refreshStorageStats()
        DSHaptics.selection()
        banner.show("已清理封面图片缓存", tone: .success)
    }

    func clearChapterCache() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        await container.chapterCache.clearAll(preservingBookIDs: protectedChapterCacheBookIDs())
        await refreshStorageStats()
        DSHaptics.selection()
        banner.show("已清理章节目录缓存", tone: .success)
    }

    func clearAllCaches() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        await downloads.clearAllPrecache()
        await container.coverPipeline.clearAll()
        CoverAmbientColor.clearCache()
        await container.chapterCache.clearAll(preservingBookIDs: protectedChapterCacheBookIDs())
        await refreshStorageStats()
        DSHaptics.selection()
        banner.show("已清理全部缓存", tone: .success)
    }
}
