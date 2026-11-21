import DSCore
import Foundation

/// 下载列表分组与过滤助手（独立于 View 文件以严格遵守规则 #8）
enum DownloadsDataHelper {
    struct BookGroup: Identifiable, Sendable {
        let id: String
        let bookTitle: String
        let completedCount: Int
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
}
