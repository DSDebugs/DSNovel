import DSCore
import DSDesignSystem
import DSStorage
import SwiftData
import SwiftUI

/// 书架数据加载与批量操作扩展（拆分自 LibraryRootView.swift 以保持单文件 ≤ 385 行）
extension LibraryRootView {
    func handleCardTap(_ item: LibraryBookItem) {
        if isEditing {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        } else {
            router.push(.bookDetail(item.book))
        }
    }

    func recomputeDisplayed() {
        filterChips = LibraryOrganizerHelper.makeFilterChips(
            shelfItems: shelfItems,
            downloadedItems: downloadedItems
        )
        displayedItems = LibraryOrganizerHelper.filteredAndSorted(
            shelfItems: shelfItems,
            downloadedItems: downloadedItems,
            filter: selectedFilter,
            sortOrder: sortOrder
        )
        if isEditing {
            let visibleIDs = Set(displayedItems.map(\.id))
            selectedIDs = selectedIDs.intersection(visibleIDs)
        }
    }

    func reloadShelf() async {
        isLoading = true
        defer { isLoading = false }
        let dlStats = LibraryOrganizerHelper.downloadStatsByBookID(from: downloads.manualRecords)
        let context = ModelContext(container.modelContainer)
        let allEntities = (try? context.fetch(FetchDescriptor<BookEntity>())) ?? []

        var shelf: [LibraryBookItem] = []
        var downloaded: [LibraryBookItem] = []
        var recents: [LibraryBookItem] = []
        var itemByID: [String: LibraryBookItem] = [:]

        for entity in allEntities {
            let stat = dlStats[entity.id] ?? (0, 0)
            let item = LibraryBookItem(
                book: entity.toSummaryDTO(),
                isPinned: entity.isPinned,
                inShelf: entity.inShelf,
                addedToShelfAt: entity.addedToShelfAt,
                lastPlayedAt: entity.lastPlayedAt,
                lastChapterIndex: entity.lastChapterIndex,
                lastChapterTitle: entity.lastChapterTitle,
                lastPositionMs: entity.lastPositionMs,
                lastDurationMs: entity.lastDurationMs,
                downloadedCount: stat.count,
                downloadedBytes: stat.bytes,
                hasUpdate: false
            )
            itemByID[item.id] = item
            if item.inShelf { shelf.append(item) }
            if item.isDownloaded { downloaded.append(item) }
            if item.lastPlayedAt != nil { recents.append(item) }
        }

        recents.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }

        if let playingBook = playback.currentBook {
            let existing = itemByID[playingBook.id]
            let stat = dlStats[playingBook.id] ?? (0, 0)
            let activeTitle = playback.currentChapter?.title ?? existing?.lastChapterTitle ?? ""
            let promoted = LibraryBookItem(
                book: existing?.book ?? playingBook,
                isPinned: existing?.isPinned ?? false,
                inShelf: existing?.inShelf ?? false,
                addedToShelfAt: existing?.addedToShelfAt,
                lastPlayedAt: Date(),
                lastChapterIndex: playback.currentChapterIndex,
                lastChapterTitle: activeTitle,
                lastPositionMs: existing?.lastPositionMs ?? 0,
                lastDurationMs: existing?.lastDurationMs ?? 0,
                downloadedCount: stat.count,
                downloadedBytes: stat.bytes,
                hasUpdate: existing?.hasUpdate ?? false
            )
            recents.removeAll { $0.id == playingBook.id }
            recents.insert(promoted, at: 0)
        }

        if recents.count > 20 {
            recents = Array(recents.prefix(20))
        }

        shelfItems = shelf
        downloadedItems = downloaded
        recentItems = recents
        continueItem = recents.first
        recomputeDisplayed()
    }

    func playBookImmediately(_ item: LibraryBookItem) async {
        DSHaptics.lightImpact()
        if playback.currentBook?.id == item.id && playback.currentChapter != nil {
            playback.togglePlayPause()
            return
        }
        if let cached = await container.chapterCache.loadChapters(bookID: item.id), !cached.isEmpty {
            let startIdx = min(max(0, item.lastChapterIndex), cached.count - 1)
            playback.play(book: item.book, chapters: cached, startIndex: startIdx, autoPlay: true)
            return
        }
        router.push(.bookDetail(item.book))
    }

    func togglePin(_ item: LibraryBookItem) async {
        do {
            try await container.persistence.togglePin(bookID: item.id)
            container.notifyLibraryChanged()
            banner.show(item.isPinned ? "已取消置顶" : "已置顶", tone: .success)
        } catch {
            banner.show("更新置顶状态失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func downloadUnread(_ item: LibraryBookItem) async {
        guard let chapters = await container.chapterCache.loadChapters(bookID: item.id), !chapters.isEmpty else {
            banner.show("请先进入书籍详情加载章节目录", tone: .info)
            return
        }
        let unread = LibraryOrganizerHelper.unreadChapters(from: chapters, lastChapterIndex: item.lastChapterIndex)
        guard !unread.isEmpty else {
            banner.show("《\(item.book.title)》暂无未听章节", tone: .info)
            return
        }
        await downloads.enqueueManual(book: item.book, chapters: unread, quality: container.resolvedQuality(for: item.book))
        banner.show("已加入下载 \(unread.count) 章未听章节", tone: .success)
    }

    func removeFromShelf(_ item: LibraryBookItem) async {
        do {
            try await container.persistence.setInShelf(bookID: item.id, inShelf: false)
            container.notifyLibraryChanged()
            banner.show("已将《\(item.book.title)》移出书架", tone: .info)
        } catch {
            banner.show("移出书架失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func batchDownloadSelected() async {
        let targets = LibraryOrganizerHelper.filterSelected(displayedItems, selectedIDs: selectedIDs)
        isEditing = false
        selectedIDs.removeAll()
        var bookCount = 0
        var chapterCount = 0
        for target in targets {
            if let chapters = await container.chapterCache.loadChapters(bookID: target.id), !chapters.isEmpty {
                let unread = LibraryOrganizerHelper.unreadChapters(from: chapters, lastChapterIndex: target.lastChapterIndex)
                let slice = unread.isEmpty ? chapters : unread
                await downloads.enqueueManual(book: target.book, chapters: slice, quality: container.resolvedQuality(for: target.book))
                bookCount += 1
                chapterCount += slice.count
            }
        }
        if chapterCount > 0 {
            banner.show("已将 \(bookCount) 本书共 \(chapterCount) 章加入下载队列", tone: .success)
        } else {
            banner.show("所选书籍暂无目录缓存，请先打开书籍详情", tone: .info)
        }
    }

    func batchTogglePinSelected() async {
        let targets = LibraryOrganizerHelper.filterSelected(displayedItems, selectedIDs: selectedIDs)
        for target in targets {
            try? await container.persistence.togglePin(bookID: target.id)
        }
        isEditing = false
        selectedIDs.removeAll()
        container.notifyLibraryChanged()
    }

    func handleBatchRemoveTap() {
        let targets = LibraryOrganizerHelper.filterSelected(displayedItems, selectedIDs: selectedIDs)
        guard !targets.isEmpty else {
            isEditing = false
            selectedIDs.removeAll()
            return
        }
        pendingBatchDeleteItems = targets
    }

    func executeBatchRemove(_ targets: [LibraryBookItem]) async {
        isEditing = false
        selectedIDs.removeAll()
        if selectedFilter == .downloaded {
            for target in targets {
                await downloads.deleteBookDownloads(bookID: target.id)
            }
            banner.show("已删除 \(targets.count) 本书的离线音频", tone: .info)
            await reloadShelf()
        } else {
            do {
                try await container.persistence.setInShelfBatch(bookIDs: targets.map(\.id), inShelf: false)
                container.notifyLibraryChanged()
                banner.show("已移出 \(targets.count) 本书", tone: .info)
            } catch {
                banner.show("批量移出书架失败：\(error.localizedDescription)", tone: .error)
            }
        }
    }
}
