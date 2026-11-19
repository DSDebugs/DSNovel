import Foundation
import SwiftData

struct DownloadedBooksOverview: Equatable, Sendable {
    let bookCount: Int
    let completedChapters: Int
    let activeChapters: Int
    let failedChapters: Int
    let totalBytes: Int64

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: max(0, totalBytes), countStyle: .file)
    }
}

@MainActor
enum LibraryCardMapper {
    static func makeModel(from book: Book, sourceStore: SourceStore, player: PlayerEngine) -> BookCardModel {
        _ = DownloadManager.shared.stateVersion
        let dlSummary = DownloadManager.shared.summariesByBookID[book.id]
        let dlCount = dlSummary?.completedCount ?? 0
        let isDownloaded = dlCount > 0

        let isThisBookActive = (player.currentBookID == book.id && player.currentChapter != nil)
        let isCurrentPlaying = (isThisBookActive && player.state == .playing)

        let effectiveChapterIndex: Int = {
            if isThisBookActive && player.currentChapterOneBasedIndex > 0 {
                return player.currentChapterOneBasedIndex
            }
            return book.lastChapterIndex
        }()

        let effectiveTotalChapters = max(book.totalChapters, isThisBookActive ? player.chapterQueue.count : 0)

        let frac: Double = {
            if effectiveTotalChapters > 0 && effectiveChapterIndex > 0 {
                return min(max(Double(effectiveChapterIndex) / Double(effectiveTotalChapters), 0.02), 1.0)
            }
            if isThisBookActive && player.clock.currentTimeSec > 0 {
                return 0.1
            }
            return book.lastPositionMs > 0 ? 0.1 : 0.0
        }()

        let baseProgressText: String = {
            if isThisBookActive, let curChap = player.currentChapter {
                let timeStr = player.clock.formattedCurrent
                return "\(curChap.title) · \(timeStr)"
            }
            return book.episodeAndTimeProgressText
        }()

        let finalSubtitle: String = {
            if dlCount > 0 {
                let bytesStr = ByteCountFormatter.string(fromByteCount: max(0, dlSummary?.totalBytes ?? 0), countStyle: .file)
                if baseProgressText == "尚未收听" || baseProgressText.hasSuffix("尚未收听") {
                    return "已下载 \(dlCount) 章 (\(bytesStr))"
                }
                return "已下 \(dlCount) 章 · \(baseProgressText)"
            }
            if let active = dlSummary?.activeCount, active > 0 {
                return "下载中 \(active) 章 · \(baseProgressText)"
            }
            return baseProgressText
        }()

        return BookCardModel(
            id: book.id,
            title: book.title,
            author: book.author,
            sourceName: sourceStore.sourceName(for: book.sourceID),
            coverURL: book.cover,
            progressFraction: frac,
            lastChapterIndex: effectiveChapterIndex,
            totalChapters: effectiveTotalChapters,
            progressSubtitle: finalSubtitle,
            isDownloaded: isDownloaded,
            hasUpdate: book.hasUpdate,
            isVIP: false,
            isPinned: book.isPinned,
            inShelf: book.inShelf,
            isPlaying: isCurrentPlaying
        )
    }

    static func computeDownloadedOverview(from manager: DownloadManager) -> DownloadedBooksOverview {
        _ = manager.stateVersion
        let summaries = manager.summariesByBookID.values
        var bookCount = 0
        var completed = 0
        var active = 0
        var failed = 0
        var bytes: Int64 = 0
        for s in summaries where s.completedCount > 0 || s.activeCount > 0 || s.failedCount > 0 {
            bookCount += 1
            completed += s.completedCount
            active += s.activeCount
            failed += s.failedCount
            bytes += s.totalBytes
        }
        return DownloadedBooksOverview(
            bookCount: bookCount,
            completedChapters: completed,
            activeChapters: active,
            failedChapters: failed,
            totalBytes: bytes
        )
    }

    static func makeFilterChips(from store: LibraryStore) -> [DSChipItem<LibraryFilter>] {
        return [
            DSChipItem(id: .all, title: "全部", count: store.filterCounts[.all]),
            DSChipItem(id: .inProgress, title: "在追", count: store.filterCounts[.inProgress]),
            DSChipItem(id: .downloaded, title: "已下载", count: store.filterCounts[.downloaded]),
            DSChipItem(id: .updated, title: "有更新", count: store.filterCounts[.updated])
        ]
    }

    static func playBookImmediately(_ book: Book, player: PlayerEngine) {
        if player.currentBookID == book.id {
            player.togglePlayPause()
            return
        }
        let downloadedSnaps = DownloadManager.shared.bookSnapshots(for: book.id)
        if let chapters = ChapterCacheStore.loadChapters(for: book.id), !chapters.isEmpty {
            let target: ChapterDTO
            if let lastID = book.lastChapterID,
               let matched = chapters.first(where: { $0.id == lastID }) {
                target = matched
            } else if let firstDownloaded = chapters.first(where: {
                downloadedSnaps["\(book.id)::\($0.id)"]?.state == "completed"
            }) {
                target = firstDownloaded
            } else {
                target = chapters[0]
            }
            let posMs = (target.id == book.lastChapterID)
                ? book.lastPositionMs
                : (ChapterProgressCache.shared.progress(bookID: book.id, chapterID: target.id)?.positionMs ?? 0)
            player.startPlayback(
                book: book.bookRef,
                chapters: chapters,
                startChapter: target,
                initialPositionMs: posMs
            )
        } else if let firstCompleted = downloadedSnaps.values.first(where: { $0.state == "completed" }) {
            let ch = ChapterDTO(index: 0, title: firstCompleted.chapterTitle, url: firstCompleted.chapterID)
            player.startPlayback(
                book: book.bookRef,
                chapters: [ch],
                startChapter: ch,
                initialPositionMs: 0
            )
        } else {
            AppRouter.shared.open(.book(book.bookRef))
        }
    }

    static func addAllRecentToShelf(store: LibraryStore, context: ModelContext) {
        if let cont = store.continueBook, !cont.inShelf {
            cont.inShelf = true
        }
        for b in store.recentBooks where !b.inShelf {
            b.inShelf = true
        }
        try? context.save()
        store.refreshNow()
        BannerCenter.shared.show("已全部加入书架", kind: .success)
    }

    static func filterShelfBooks(_ books: [Book], selectedIDs: Set<String>) -> [Book] {
        books.filter { selectedIDs.contains($0.id) }
    }
}
