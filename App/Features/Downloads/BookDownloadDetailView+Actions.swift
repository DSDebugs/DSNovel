import DSCore
import DSDesignSystem
import SwiftUI

/// 单书离线下载详情页动作逻辑（拆分保持单文件 ≤ 385 行）
extension BookDownloadDetailView {
    func refreshPartitionedItems() {
        let p = DownloadsDataHelper.partitionRecordsForBook(bookID, from: downloads.manualRecords)
        activeItems = p.active
        failedItems = p.failed
        completedItems = p.completed
        totalBytes = p.completed.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        if completedItems.isEmpty {
            isBatchManaging = false
            selectedRecordIDs.removeAll()
        } else {
            let validIDs = Set(completedItems.map(\.id))
            selectedRecordIDs = selectedRecordIDs.intersection(validIDs)
        }
    }

    func openBookDetailPage() async {
        let book = await resolveBookSummary()
        router.push(.bookDetail(book))
    }

    private func resolveBookSummary() async -> BookSummaryDTO {
        if let exact = try? await container.persistence.fetchBook(id: bookID) {
            return exact
        }
        let sample = completedItems.first ?? activeItems.first ?? failedItems.first
        return BookSummaryDTO(
            id: bookID,
            sourceID: sample?.sourceID ?? "",
            bookURL: "",
            title: bookTitle,
            coverURL: sample?.coverURL ?? "",
            totalChapters: completedItems.count
        )
    }

    func continueOfflinePlayback() async {
        if playback.currentBook?.id == bookID, let currentChap = playback.currentChapter,
           let playingRec = completedItems.first(where: { $0.chapterID == currentChap.id }),
           let idx = completedItems.firstIndex(where: { $0.id == playingRec.id }) {
            await playOffline(record: playingRec, fallbackIndex: idx)
            return
        }
        if let first = completedItems.first {
            await playOffline(record: first, fallbackIndex: 0)
        }
    }

    /// 优先从 ChapterCacheStore 还原完整目录队列再定位对应章起播，无缓存时按正序 completedItems 精确匹配索引
    func playOffline(record: DownloadRecordSnapshot, fallbackIndex: Int? = nil) async {
        DSHaptics.selection()
        let book = await resolveBookSummary()
        if let cached = await container.chapterCache.loadChapters(bookID: bookID), !cached.isEmpty {
            let matchIdx = cached.firstIndex(where: { $0.id == record.chapterID })
                ?? (cached.indices.contains(record.chapterIndex) ? record.chapterIndex : nil)
            if let startIdx = matchIdx {
                playback.play(book: book, chapters: cached, startIndex: startIdx, autoPlay: true)
                return
            }
        }
        let fallbackQueue = completedItems.map { rec in
            ChapterDTO(id: rec.chapterID, index: rec.chapterIndex, title: rec.chapterTitle, url: rec.chapterURL)
        }
        let resolvedFallback = completedItems.firstIndex(where: { $0.id == record.id }) ?? fallbackIndex ?? 0
        let safeIdx = min(max(0, resolvedFallback), max(0, fallbackQueue.count - 1))
        guard fallbackQueue.indices.contains(safeIdx) else { return }
        playback.play(book: book, chapters: fallbackQueue, startIndex: safeIdx, autoPlay: true)
    }

    func deleteSelectedChapters() async {
        let targets = completedItems.filter { selectedRecordIDs.contains($0.id) }
        for item in targets {
            await downloads.cancelAndDelete(id: item.id)
        }
        selectedRecordIDs.removeAll()
        isBatchManaging = false
        if !targets.isEmpty {
            DSHaptics.lightImpact()
            banner.show("已删除 \(targets.count) 章离线文件", tone: .info)
        }
    }

    func pauseBookActive() async {
        for item in activeItems where item.state != .paused {
            await downloads.pause(id: item.id)
        }
    }

    func resumeBookActive() async {
        for item in activeItems where item.state == .paused {
            await downloads.resume(id: item.id)
        }
    }

    func retryBookFailed() async {
        for item in failedItems {
            await downloads.resume(id: item.id)
        }
        banner.show("已重新加入下载队列", tone: .info)
    }

    func clearBookFailed() async {
        let targets = failedItems
        for item in targets {
            await downloads.cancelAndDelete(id: item.id)
        }
        if !targets.isEmpty {
            banner.show("已清空 \(targets.count) 章失败记录", tone: .info)
        }
    }
}
