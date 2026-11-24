import DSCore
import Foundation

/// 下载列表分组、分区与过滤助手（保留 v3.0 既有公开静态签名并补全 v2.8 多分区与单书离线辅助）
enum DownloadsDataHelper {
    struct BookGroup: Identifiable, Sendable {
        let id: String
        let bookTitle: String
        let completedCount: Int
        let totalBytes: Int64
    }

    struct BookDownloadSummary: Identifiable, Equatable, Sendable {
        let id: String
        let bookTitle: String
        let completedCount: Int
        let activeCount: Int
        let failedCount: Int
        let totalBytes: Int64
    }

    static func activeTaskCount(from records: [DownloadRecordSnapshot]) -> Int {
        var count = 0
        for rec in records where rec.state != .completed && rec.state != .cancelled {
            count += 1
        }
        return count
    }

    static func completedBookCount(from records: [DownloadRecordSnapshot]) -> Int {
        var seen: Set<String> = []
        for rec in records where rec.state == .completed {
            seen.insert(rec.bookID)
        }
        return seen.count
    }

    static func activeTasks(from records: [DownloadRecordSnapshot]) -> [DownloadRecordSnapshot] {
        records.filter { $0.state != .completed && $0.state != .cancelled }
    }

    static func completedBookGroups(from records: [DownloadRecordSnapshot]) -> [BookGroup] {
        let completed = records.filter { $0.state == .completed }
        let grouped = Dictionary(grouping: completed, by: \.bookID)
        return grouped.map { bookID, items in
            let title = items.first?.bookTitle ?? bookID
            let bytes = items.reduce(Int64(0)) { $0 + $1.totalBytes }
            return BookGroup(id: bookID, bookTitle: title, completedCount: items.count, totalBytes: bytes)
        }
        .sorted { $0.bookTitle < $1.bookTitle }
    }

    static func completedChapters(for bookID: String, from records: [DownloadRecordSnapshot]) -> [DownloadRecordSnapshot] {
        records
            .filter { $0.bookID == bookID && $0.state == .completed }
            .sorted { $0.chapterIndex < $1.chapterIndex }
    }

    // MARK: - v2.8 多分区与存储统计辅助

    static func partitionRecords(
        _ records: [DownloadRecordSnapshot]
    ) -> (active: [DownloadRecordSnapshot], failed: [DownloadRecordSnapshot]) {
        var active: [DownloadRecordSnapshot] = []
        var failed: [DownloadRecordSnapshot] = []
        for rec in records where rec.kind == .manual {
            switch rec.state {
            case .queued, .resolving, .downloading, .paused:
                active.append(rec)
            case .failed:
                failed.append(rec)
            case .completed, .cancelled:
                break
            }
        }
        return (active, failed)
    }

    static func partitionRecordsForBook(
        _ bookID: String,
        from records: [DownloadRecordSnapshot]
    ) -> (active: [DownloadRecordSnapshot], failed: [DownloadRecordSnapshot], completed: [DownloadRecordSnapshot]) {
        var active: [DownloadRecordSnapshot] = []
        var failed: [DownloadRecordSnapshot] = []
        var completed: [DownloadRecordSnapshot] = []
        for rec in records where rec.bookID == bookID && rec.kind == .manual {
            switch rec.state {
            case .queued, .resolving, .downloading, .paused:
                active.append(rec)
            case .failed:
                failed.append(rec)
            case .completed:
                completed.append(rec)
            case .cancelled:
                break
            }
        }
        completed.sort { $0.chapterIndex < $1.chapterIndex }
        return (active, failed, completed)
    }

    static func bookSummaries(from records: [DownloadRecordSnapshot]) -> [BookDownloadSummary] {
        let manual = records.filter { $0.kind == .manual && $0.state != .cancelled }
        let grouped = Dictionary(grouping: manual, by: \.bookID)
        var list: [BookDownloadSummary] = []
        list.reserveCapacity(grouped.count)

        for (bookID, items) in grouped {
            var completed = 0
            var active = 0
            var failed = 0
            var totalBytes: Int64 = 0
            for item in items {
                switch item.state {
                case .completed:
                    completed += 1
                    totalBytes += max(0, item.totalBytes)
                case .queued, .resolving, .downloading, .paused:
                    active += 1
                case .failed:
                    failed += 1
                case .cancelled:
                    break
                }
            }
            guard completed > 0 || active > 0 || failed > 0 else { continue }
            let title = items.first?.bookTitle ?? bookID
            list.append(
                BookDownloadSummary(
                    id: bookID,
                    bookTitle: title,
                    completedCount: completed,
                    activeCount: active,
                    failedCount: failed,
                    totalBytes: totalBytes
                )
            )
        }
        return list.sorted { lhs, rhs in
            let lHas = lhs.completedCount > 0 || lhs.totalBytes > 0
            let rHas = rhs.completedCount > 0 || rhs.totalBytes > 0
            if lHas != rHas { return lHas }
            return lhs.bookTitle.localizedStandardCompare(rhs.bookTitle) == .orderedAscending
        }
    }

    static func manualCompletedBytes(from records: [DownloadRecordSnapshot]) -> Int64 {
        records
            .filter { $0.kind == .manual && $0.state == .completed }
            .reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
    }

    static func activeStateLabel(for state: DownloadState, isWaitingForWiFi: Bool) -> String {
        switch state {
        case .paused:
            return isWaitingForWiFi ? "等待 Wi-Fi" : "已暂停"
        case .queued:
            return isWaitingForWiFi ? "等待 Wi-Fi" : "排队中"
        case .resolving:
            return "解析地址中"
        case .downloading:
            return "下载中"
        case .completed:
            return "已完成"
        case .failed:
            return "下载失败"
        case .cancelled:
            return "已取消"
        }
    }

    static func qualityBadgeText(for record: DownloadRecordSnapshot) -> String {
        record.qualityTier.displayName
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
            segments.append("已下载 \(completedCount) 章 · \(formattedBytes)")
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

    static func freeDiskBytes() -> Int64 {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return max(0, capacity)
        }
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity {
            return max(0, Int64(capacity))
        }
        return 0
    }
}
