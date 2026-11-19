import Foundation
import Observation
import SwiftData

/// 播放器目录下载与分段模型：
/// 统一复用 DownloadManager.shared 的响应式状态快照与 ChapterProgressCache 实时进度，确保播放器目录与书籍详情页 100% 状态同步。
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

    private func resolveDownloadState(for chapter: ChapterDTO, liveSnapshots: [String: DownloadItemSnapshot]) -> (state: ChapterDownloadState, bytes: Int64) {
        let itemID = "\(book.id)::\(chapter.id)"
        if let snap = liveSnapshots[itemID] {
            switch snap.state {
            case "completed":
                return (snap.isFileVerified ? .completed : .notDownloaded, snap.bytes)
            case "downloading", "queued", "waitingWiFi", "paused":
                let p = DownloadManager.shared.itemProgress[itemID] ?? (snap.state == "downloading" ? 0.2 : 0.08)
                return (.downloading(p), snap.bytes)
            case "failed":
                return (.failed, 0)
            default:
                return (.notDownloaded, 0)
            }
        }
        if let legacy = downloadItems[itemID] {
            switch legacy.state {
            case "completed":
                return (.completed, legacy.bytes)
            case "downloading", "queued", "waitingWiFi", "paused":
                return (.downloading(DownloadManager.shared.itemProgress[itemID] ?? 0.2), legacy.bytes)
            case "failed":
                return (.failed, 0)
            default:
                return (.notDownloaded, 0)
            }
        }
        return (.notDownloaded, 0)
    }

    var snapshots: [ChapterRowSnapshot] {
        let liveMap = DownloadManager.shared.bookSnapshots(for: book.id)
        let progressMap = ChapterProgressCache.shared.allSnapshotsMap(for: book.id)
        return chapters.map { ch in
            let resolved = resolveDownloadState(for: ch, liveSnapshots: liveMap)
            let snap = progressMap[ch.id]
            let pos = snap?.positionMs ?? 0
            let dur = max(snap?.durationMs ?? 0, (ch.normalizedDurationSec ?? 0) * 1000)
            let isDone = (snap?.isFinished == true) || (dur > 0 && pos >= Int(Double(dur) * 0.98))
            return ChapterRowSnapshot(
                chapter: ch,
                displayIndex: ch.index + 1,
                isCurrentPlayingChapter: ch.id == currentChapterID,
                isEnginePlaying: false,
                savedPositionMs: pos,
                durationMs: dur,
                isFinished: isDone,
                isVIP: ch.title.uppercased().contains("VIP"),
                downloadState: resolved.state,
                downloadedBytes: resolved.bytes
            )
        }
    }

    func reloadDownloadMap() {
        guard let ctx = DownloadManager.shared.modelContext else { return }
        let bid = book.id
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.bookID == bid && $0.kind == "manual" })
        let items = (try? ctx.fetch(desc)) ?? []
        var map: [String: DownloadItem] = [:]
        for item in items {
            map[item.id] = item
        }
        downloadItems = map
    }

    func visibleSnapshots(
        from browserModel: BookDetailModel,
        currentChapterIDOverride: String? = nil,
        isPlaying: Bool,
        currentPlayingPositionMs: Int? = nil
    ) -> [ChapterRowSnapshot] {
        _ = DownloadManager.shared.stateVersion
        let resolvedChapterID = currentChapterIDOverride ?? currentChapterID
        let base = browserModel.visibleChapterSnapshots(
            currentPlayingChapterID: resolvedChapterID,
            isEnginePlaying: isPlaying,
            currentPlayingPositionMs: currentPlayingPositionMs,
            forceAllSegmentsWhenFiltered: onlyDownloadedFilter
        )
        guard onlyDownloadedFilter else { return base }
        return base.filter { $0.downloadState == .completed }
    }

    func confirmDeleteDownload(_ snap: ChapterRowSnapshot) {
        let removed = DownloadManager.shared.invalidateLocalFile(bookID: book.id, chapterID: snap.chapter.id)
        DSHapticPolicy.fire(.warning)
        BannerCenter.shared.show(
            removed ? "已删除第 \(snap.displayIndex) 章离线文件" : "离线文件不存在，已同步状态",
            kind: .info,
            bypassDeduplication: true
        )
    }

    func startOrRetryDownload(_ snap: ChapterRowSnapshot) {
        if snap.downloadState == .failed {
            if DownloadManager.shared.retryFailedChapter(bookID: book.id, chapterID: snap.chapter.id) {
                DSHapticPolicy.fire(.selection)
                BannerCenter.shared.show("已重新加入下载队列", kind: .info, bypassDeduplication: true)
                return
            }
        }
        do {
            let added = try DownloadManager.shared.enqueueChaptersWithCheck([snap.chapter], for: book, kind: "manual")
            DSHapticPolicy.fire(.success)
            BannerCenter.shared.show(
                added > 0 ? "已加入下载 1 章" : "该章已在下载队列中",
                kind: added > 0 ? .success : .info,
                bypassDeduplication: true
            )
        } catch {
            DSHapticPolicy.fire(.error)
            BannerCenter.shared.show(error.localizedDescription, kind: .error)
        }
    }

    func downloadRemaining() {
        let liveMap = DownloadManager.shared.bookSnapshots(for: book.id)
        let remaining = chapters.filter { ch in
            let itemID = "\(book.id)::\(ch.id)"
            return liveMap[itemID]?.state != "completed"
        }
        guard !remaining.isEmpty else {
            BannerCenter.shared.show("全部章节均已离线下载", kind: .info)
            return
        }
        DownloadManager.shared.enqueueChapters(remaining, for: book, kind: "manual")
        DSHapticPolicy.fire(.success)
        BannerCenter.shared.show("已加入下载 \(remaining.count) 章", kind: .success)
    }

    static func segmentIndex(for chapterID: String?, in chapters: [ChapterDTO], pageSize: Int = 100) -> Int? {
        guard let chapterID, pageSize > 0 else { return nil }
        for (idx, item) in chapters.enumerated() where item.id == chapterID {
            return idx / pageSize
        }
        return nil
    }
}
