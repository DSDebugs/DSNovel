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

    static func sortedSummaries(_ map: [String: DownloadSummary]) -> [DownloadSummary] {
        map.values
            .filter { $0.completedCount > 0 || $0.activeCount > 0 || $0.failedCount > 0 }
            .sorted { a, b in
                if (a.completedCount > 0) != (b.completedCount > 0) {
                    return a.completedCount > 0
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
