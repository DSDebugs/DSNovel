import DSCore
import DSDesignSystem
import Foundation

/// 书架 4 组筛选（1:1 复刻 v2.8）
enum ShelfFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case listening
    case downloaded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .listening: return "在追"
        case .downloaded: return "已下载"
        }
    }
}

/// 书架排序方式（1:1 复刻 v2.8）
enum ShelfSortOrder: String, CaseIterable, Identifiable, Sendable {
    case recentPlayed
    case recentAdded
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentPlayed: return "最近收听"
        case .recentAdded: return "最近加入"
        case .title: return "按书名"
        }
    }
}

/// 播放历史时间分组（1:1 复刻 v2.8）
enum HistoryTimeGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case today
    case yesterday
    case earlier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .earlier: return "更早"
        }
    }
}

/// 书架/历史单书展示模型（值类型，跨线程安全）
struct LibraryBookItem: Identifiable, Equatable, Sendable {
    var id: String { book.id }
    let book: BookSummaryDTO
    let isPinned: Bool
    let inShelf: Bool
    let addedToShelfAt: Date?
    let lastPlayedAt: Date?
    let lastChapterIndex: Int
    let lastChapterTitle: String
    let lastPositionMs: Int
    let lastDurationMs: Int
    let downloadedCount: Int
    let downloadedBytes: Int64
    let hasUpdate: Bool

    var isDownloaded: Bool { downloadedCount > 0 }
    var isListening: Bool { lastPlayedAt != nil }

    var progressFraction: Double {
        if lastDurationMs > 0, lastPositionMs > 0 {
            return min(1, max(0.02, Double(lastPositionMs) / Double(lastDurationMs)))
        }
        if book.totalChapters > 0, lastChapterIndex >= 0, lastPlayedAt != nil {
            return min(1, max(0.02, Double(lastChapterIndex + 1) / Double(book.totalChapters)))
        }
        return 0
    }

    var progressSubtitle: String {
        if !lastChapterTitle.isEmpty {
            return lastChapterTitle
        }
        if lastPlayedAt != nil {
            return "听到第 \(lastChapterIndex + 1) 章"
        }
        if downloadedCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
            return "已下载 \(downloadedCount) 章 · \(size)"
        }
        return ""
    }
}

/// 播放历史分组区段
struct HistorySectionGroup: Identifiable, Equatable, Sendable {
    var id: HistoryTimeGroup { group }
    let group: HistoryTimeGroup
    let items: [LibraryBookItem]
}

/// 已下载书籍总览
struct DownloadedShelfOverview: Equatable, Sendable {
    let bookCount: Int
    let completedChapters: Int
    let activeChapters: Int
    let failedChapters: Int
    let totalBytes: Int64

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: max(0, totalBytes), countStyle: .file)
    }
}

/// 书架整理与筛选辅助器（保留 v3.0 既有公开静态签名 `filterBooks`，独立于 View 文件以遵守规则 #8）
enum LibraryOrganizerHelper {
    static func filterBooks(_ books: [BookSummaryDTO], keyword: String) -> [BookSummaryDTO] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.author.localizedCaseInsensitiveContains(q)
                || $0.narrator.localizedCaseInsensitiveContains(q)
        }
    }

    static func computeDownloadedOverview(from records: [DownloadRecordSnapshot]) -> DownloadedShelfOverview {
        var bookIDs: Set<String> = []
        var completed = 0
        var active = 0
        var failed = 0
        var bytes: Int64 = 0

        for rec in records where rec.kind == .manual {
            switch rec.state {
            case .completed:
                completed += 1
                bytes += max(0, rec.totalBytes)
                bookIDs.insert(rec.bookID)
            case .queued, .resolving, .downloading, .paused:
                active += 1
            case .failed:
                failed += 1
            case .cancelled:
                break
            }
        }
        return DownloadedShelfOverview(
            bookCount: bookIDs.count,
            completedChapters: completed,
            activeChapters: active,
            failedChapters: failed,
            totalBytes: bytes
        )
    }

    static func downloadStatsByBookID(
        from records: [DownloadRecordSnapshot]
    ) -> [String: (count: Int, bytes: Int64)] {
        var stats: [String: (count: Int, bytes: Int64)] = [:]
        for rec in records where rec.kind == .manual && rec.state == .completed {
            let prev = stats[rec.bookID] ?? (0, 0)
            stats[rec.bookID] = (prev.count + 1, prev.bytes + max(0, rec.totalBytes))
        }
        return stats
    }

    static func makeFilterChips(
        shelfItems: [LibraryBookItem],
        downloadedItems: [LibraryBookItem]
    ) -> [DSChipItem<ShelfFilter>] {
        let listeningCount = shelfItems.filter(\.isListening).count
        return [
            DSChipItem(id: .all, title: ShelfFilter.all.title, count: shelfItems.count),
            DSChipItem(id: .listening, title: ShelfFilter.listening.title, count: listeningCount),
            DSChipItem(id: .downloaded, title: ShelfFilter.downloaded.title, count: downloadedItems.count)
        ]
    }

    static func filteredAndSorted(
        shelfItems: [LibraryBookItem],
        downloadedItems: [LibraryBookItem],
        filter: ShelfFilter,
        sortOrder: ShelfSortOrder
    ) -> [LibraryBookItem] {
        let base: [LibraryBookItem]
        switch filter {
        case .all:
            base = shelfItems
        case .listening:
            base = shelfItems.filter(\.isListening)
        case .downloaded:
            base = downloadedItems
        }

        return base.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            switch sortOrder {
            case .recentPlayed:
                let ld = lhs.lastPlayedAt ?? lhs.addedToShelfAt ?? .distantPast
                let rd = rhs.lastPlayedAt ?? rhs.addedToShelfAt ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.book.title.localizedStandardCompare(rhs.book.title) == .orderedAscending
            case .recentAdded:
                let ld = lhs.addedToShelfAt ?? .distantPast
                let rd = rhs.addedToShelfAt ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.book.title.localizedStandardCompare(rhs.book.title) == .orderedAscending
            case .title:
                return lhs.book.title.localizedStandardCompare(rhs.book.title) == .orderedAscending
            }
        }
    }

    static func groupHistoryByDate(
        _ items: [LibraryBookItem],
        calendar: Calendar = .current
    ) -> [HistorySectionGroup] {
        var today: [LibraryBookItem] = []
        var yesterday: [LibraryBookItem] = []
        var earlier: [LibraryBookItem] = []

        for item in items {
            guard let date = item.lastPlayedAt else {
                earlier.append(item)
                continue
            }
            if calendar.isDateInToday(date) {
                today.append(item)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(item)
            } else {
                earlier.append(item)
            }
        }

        var result: [HistorySectionGroup] = []
        if !today.isEmpty { result.append(HistorySectionGroup(group: .today, items: today)) }
        if !yesterday.isEmpty { result.append(HistorySectionGroup(group: .yesterday, items: yesterday)) }
        if !earlier.isEmpty { result.append(HistorySectionGroup(group: .earlier, items: earlier)) }
        return result
    }

    static func unreadChapters(from chapters: [ChapterDTO], lastChapterIndex: Int) -> [ChapterDTO] {
        guard !chapters.isEmpty else { return [] }
        let start = min(max(0, lastChapterIndex), chapters.count - 1)
        return Array(chapters[start...])
    }

    static func filterSelected(_ items: [LibraryBookItem], selectedIDs: Set<String>) -> [LibraryBookItem] {
        items.filter { selectedIDs.contains($0.id) }
    }
}
