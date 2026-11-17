import Foundation
import SwiftData

@MainActor
enum LibraryCardMapper {
    static func makeModel(from book: Book, sourceStore: SourceStore, player: PlayerEngine) -> BookCardModel {
        let dlSummary = DownloadManager.shared.summariesByBookID[book.id]
        let isDownloaded = (dlSummary?.completedCount ?? 0) > 0
        let frac: Double = {
            if book.totalChapters > 0 && book.lastChapterIndex > 0 {
                return min(max(Double(book.lastChapterIndex) / Double(book.totalChapters), 0.02), 1.0)
            }
            return book.lastPositionMs > 0 ? 0.1 : 0.0
        }()
        let isCurrentPlaying = (player.currentBookID == book.id && player.state == .playing)
        return BookCardModel(
            id: book.id,
            title: book.title,
            author: book.author,
            sourceName: sourceStore.sourceName(for: book.sourceID),
            coverURL: book.cover,
            progressFraction: frac,
            lastChapterIndex: book.lastChapterIndex,
            totalChapters: book.totalChapters,
            progressSubtitle: book.episodeAndTimeProgressText,
            isDownloaded: isDownloaded,
            hasUpdate: book.hasUpdate,
            isVIP: false,
            isPinned: book.isPinned,
            inShelf: book.inShelf,
            isPlaying: isCurrentPlaying
        )
    }

    static func makeFilterChips(from store: LibraryStore) -> [DSChipItem<LibraryFilter>] {
        var items: [DSChipItem<LibraryFilter>] = [
            DSChipItem(id: .all, title: "全部", count: store.filterCounts[.all]),
            DSChipItem(id: .inProgress, title: "在追", count: store.filterCounts[.inProgress]),
            DSChipItem(id: .downloaded, title: "已下载", count: store.filterCounts[.downloaded]),
            DSChipItem(id: .updated, title: "有更新", count: store.filterCounts[.updated])
        ]
        for cat in store.categories {
            items.append(
                DSChipItem(
                    id: .category(cat.id),
                    title: cat.name,
                    count: store.filterCounts[.category(cat.id)]
                )
            )
        }
        return items
    }

    static func playBookImmediately(_ book: Book, player: PlayerEngine) {
        if player.currentBookID == book.id {
            player.togglePlayPause()
            return
        }
        if let chapters = ChapterCacheStore.loadChapters(for: book.id), !chapters.isEmpty {
            let target = chapters.first(where: { $0.id == book.lastChapterID }) ?? chapters[0]
            player.startPlayback(
                book: book.bookRef,
                chapters: chapters,
                startChapter: target,
                initialPositionMs: book.lastPositionMs
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
}
