import Foundation
import Observation
import SwiftData

/// 播放器目录下载与分段模型（§4.2 & §6.2.7）：
/// 封装章节目录下载状态映射、单章即点即下、剩余章节批量下载与离线过滤，确保 ChapterListView 零集合运算。
@MainActor
@Observable
final class PlayerChapterListModel {
    let book: BookRef
    var chapters: [ChapterDTO]
    var currentChapterID: String?
    var downloadItems: [String: DownloadItem] = [:]
    var onlyDownloadedFilter: Bool = AppSettingsStore.shared.onlyPlayDownloadedInOffline {
        didSet {
            AppSettingsStore.shared.onlyPlayDownloadedInOffline = onlyDownloadedFilter
        }
    }

    init(book: BookRef, chapters: [ChapterDTO], currentChapterID: String?) {
        self.book = book
        self.chapters = chapters
        self.currentChapterID = currentChapterID
    }

    var snapshots: [ChapterRowSnapshot] {
        chapters.map { ch in
            let itemID = "\(book.id)::\(ch.id)"
            let dl = downloadItems[itemID]
            let dlState: ChapterDownloadState
            if let dl {
                switch dl.state {
                case "completed":
                    dlState = .completed
                case "downloading", "queued", "waitingWiFi":
                    dlState = .downloading(DownloadManager.shared.itemProgress[itemID] ?? 0.2)
                case "failed":
                    dlState = .failed
                default:
                    dlState = .notDownloaded
                }
            } else {
                dlState = .notDownloaded
            }
            return ChapterRowSnapshot(
                chapter: ch,
                displayIndex: ch.index + 1,
                isCurrentPlayingChapter: ch.id == currentChapterID,
                isEnginePlaying: false,
                savedPositionMs: 0,
                isFinished: false,
                isVIP: ch.title.uppercased().contains("VIP"),
                downloadState: dlState
            )
        }
    }

    func reloadDownloadMap() {
        guard let ctx = DownloadManager.shared.modelContext else { return }
        let bid = book.id
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.bookID == bid })
        let items = (try? ctx.fetch(desc)) ?? []
        var map: [String: DownloadItem] = [:]
        for item in items {
            map[item.id] = item
        }
        downloadItems = map
    }

    func visibleSnapshots(from browserModel: BookDetailModel, isPlaying: Bool) -> [ChapterRowSnapshot] {
        let base = browserModel.visibleChapterSnapshots(
            currentPlayingChapterID: currentChapterID,
            isEnginePlaying: isPlaying,
            downloadItems: downloadItems
        )
        guard onlyDownloadedFilter else { return base }
        return base.filter { $0.downloadState == .completed }
    }

    func toggleDownload(_ snap: ChapterRowSnapshot) {
        let itemID = "\(book.id)::\(snap.chapter.id)"
        if snap.downloadState == .completed {
            DownloadManager.shared.invalidateLocalFile(bookID: book.id, chapterID: snap.chapter.id)
            BannerCenter.shared.show("已删除该章离线文件", kind: .info)
        } else if snap.downloadState == .failed, let failedItem = downloadItems[itemID] {
            DownloadManager.shared.retryFailedItem(failedItem)
            BannerCenter.shared.show("已重新加入下载队列", kind: .info)
        } else {
            do {
                _ = try DownloadManager.shared.enqueueChaptersWithCheck([snap.chapter], for: book, kind: "manual")
                DSHapticPolicy.fire(.success)
                BannerCenter.shared.show("已加入下载 1 章", kind: .success)
            } catch {
                DSHapticPolicy.fire(.error)
                BannerCenter.shared.show(error.localizedDescription, kind: .error)
            }
        }
        reloadDownloadMap()
    }

    func downloadRemaining() {
        let remaining = chapters.filter { ch in
            let itemID = "\(book.id)::\(ch.id)"
            return downloadItems[itemID]?.state != "completed"
        }
        guard !remaining.isEmpty else {
            BannerCenter.shared.show("全部章节均已离线下载", kind: .info)
            return
        }
        DownloadManager.shared.enqueueChapters(remaining, for: book, kind: "manual")
        DSHapticPolicy.fire(.success)
        BannerCenter.shared.show("已加入下载 \(remaining.count) 章", kind: .success)
        reloadDownloadMap()
    }

    static func segmentIndex(for chapterID: String?, in chapters: [ChapterDTO], pageSize: Int = 100) -> Int? {
        guard let chapterID, pageSize > 0 else { return nil }
        for (idx, item) in chapters.enumerated() where item.id == chapterID {
            return idx / pageSize
        }
        return nil
    }
}
