import Foundation
import Observation
import SwiftData

struct ChapterSegmentItem: Identifiable, Equatable, Hashable, Sendable {
    var id: Int { startIndex }
    let startIndex: Int
    let endIndex: Int
    var label: String { "\(startIndex + 1)–\(endIndex)" }
}

enum ChapterDownloadState: Equatable, Hashable, Sendable {
    case notDownloaded
    case downloading(Double)
    case completed
    case failed
}

struct ChapterRowSnapshot: Identifiable, Equatable, Hashable, Sendable {
    var id: String { chapter.id }
    let chapter: ChapterDTO
    let displayIndex: Int
    let isCurrentPlayingChapter: Bool
    let isEnginePlaying: Bool
    let savedPositionMs: Int
    let isFinished: Bool
    let isVIP: Bool
    let downloadState: ChapterDownloadState
    let downloadedBytes: Int64
    let isDeleting: Bool
    let downloadStatusNote: String?

    init(
        chapter: ChapterDTO,
        displayIndex: Int,
        isCurrentPlayingChapter: Bool,
        isEnginePlaying: Bool,
        savedPositionMs: Int,
        isFinished: Bool,
        isVIP: Bool,
        downloadState: ChapterDownloadState,
        downloadedBytes: Int64 = 0,
        isDeleting: Bool = false,
        downloadStatusNote: String? = nil
    ) {
        self.chapter = chapter
        self.displayIndex = displayIndex
        self.isCurrentPlayingChapter = isCurrentPlayingChapter
        self.isEnginePlaying = isEnginePlaying
        self.savedPositionMs = savedPositionMs
        self.isFinished = isFinished
        self.isVIP = isVIP
        self.downloadState = downloadState
        self.downloadedBytes = downloadedBytes
        self.isDeleting = isDeleting
        self.downloadStatusNote = downloadStatusNote
    }

    var progressFraction: Double {
        guard savedPositionMs > 0 else { return 0 }
        let durMs = max((chapter.normalizedDurationSec ?? 600) * 1000, 1)
        return min(max(Double(savedPositionMs) / Double(durMs), 0.02), 1.0)
    }

    var subtitleText: String {
        var parts: [String] = []
        if let dur = chapter.normalizedDurationSec {
            parts.append(PlaybackClock.formatSeconds(Double(dur)))
        }
        if savedPositionMs > 0 {
            parts.append("听至 \(ChapterProgressStore.formattedPosition(ms: savedPositionMs))")
        }
        if isDeleting {
            parts.append("删除中…")
        } else {
            switch downloadState {
            case .completed:
                if downloadedBytes > 0 {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
                    parts.append("已下载 · \(sizeStr)")
                } else {
                    parts.append("已下载")
                }
            case .downloading(let p):
                if let note = downloadStatusNote, !note.isEmpty {
                    parts.append(note)
                } else {
                    parts.append("下载中 \(Int((p * 100).rounded()))%")
                }
            case .failed:
                parts.append("下载失败 · 点击重试")
            case .notDownloaded:
                break
            }
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class BookDetailModel {
    var currentBookRef: BookRef
    let preferDownloadedOnAppear: Bool
    private(set) var cleanedIntro: String = ""
    private(set) var statusText: String = ""
    private(set) var chapters: [ChapterDTO] = []
    private(set) var segments: [ChapterSegmentItem] = []
    var selectedSegmentIndex: Int = 0
    /// 是否处于「已下载章节」展示模式（书籍有已下载章节时默认开启以优先展示已下载章节）
    var isShowingDownloadedOnly: Bool = false
    var isAscending: Bool = true
    var chapterSearchKeyword: String = ""
    private(set) var isLoadingChapters: Bool = false
    private(set) var chapterError: Error?
    private(set) var finishedChapterIDs: Set<String> = []
    private(set) var didApplyInitialPresentation: Bool = false

    var customDetailLoader: ((BookRef) async throws -> BookDetailDTO)?

    init(book: BookRef, preferDownloaded: Bool = false) {
        self.currentBookRef = book
        self.preferDownloadedOnAppear = preferDownloaded
        self.cleanedIntro = Self.cleanHTML(book.intro)
        if preferDownloaded {
            self.isShowingDownloadedOnly = true
        }
    }

    nonisolated static func buildSegments(totalCount: Int, pageSize: Int = 50) -> [ChapterSegmentItem] {
        guard totalCount > 0, pageSize > 0 else { return [] }
        var list: [ChapterSegmentItem] = []
        var start = 0
        while start < totalCount {
            let end = min(start + pageSize, totalCount)
            list.append(ChapterSegmentItem(startIndex: start, endIndex: end))
            start = end
        }
        return list
    }

    nonisolated static func cleanHTML(_ raw: String) -> String {
        guard !raw.isEmpty else { return "暂无作品简介" }
        let stripped = raw
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "([0-9]+)\\s*集", with: "$1 章", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "暂无作品简介" : stripped
    }

    func applyChapters(_ list: [ChapterDTO]) {
        self.chapters = list
        self.segments = Self.buildSegments(totalCount: list.count, pageSize: 100)
        if !segments.indices.contains(selectedSegmentIndex) {
            selectedSegmentIndex = 0
        }
    }

    /// 初始展示优先级决策：有已下载章节（或由已下载书籍页进入）时优先展示「已下载章节」，同时将百章分段自动对齐至当前收听进度所在区间
    func applyInitialPresentationIfNeeded(
        downloadedCount: Int,
        activeDownloadCount: Int,
        activeChapterID: String?,
        savedChapterID: String?,
        savedChapterIndex: Int?
    ) {
        guard !chapters.isEmpty else { return }
        if let targetID = activeChapterID ?? savedChapterID,
           let idx = chapters.firstIndex(where: { $0.id == targetID }) {
            let segIdx = idx / 100
            if segments.indices.contains(segIdx) {
                selectedSegmentIndex = segIdx
            }
        } else if let savedIdx = savedChapterIndex, savedIdx > 0 {
            let segIdx = min(max(0, savedIdx - 1), max(0, chapters.count - 1)) / 100
            if segments.indices.contains(segIdx) {
                selectedSegmentIndex = segIdx
            }
        }
        guard !didApplyInitialPresentation else { return }
        didApplyInitialPresentation = true
        if preferDownloadedOnAppear || downloadedCount > 0 || activeDownloadCount > 0 {
            isShowingDownloadedOnly = true
        }
    }

    func loadChaptersIfNeeded(forceRefresh: Bool = false) async {
        let bookID = currentBookRef.id
        if !forceRefresh,
           let cached = ChapterCacheStore.loadChapters(for: bookID),
           !cached.isEmpty {
            applyChapters(cached)
            let age = ChapterCacheStore.cacheAge(for: bookID) ?? 9999
            if age < 600 {
                Task { await refreshChaptersSilently(oldCount: cached.count) }
                return
            }
        }

        isLoadingChapters = chapters.isEmpty
        chapterError = nil
        do {
            let detail = try await fetchDetail(for: currentBookRef)
            if !detail.intro.isEmpty {
                cleanedIntro = Self.cleanHTML(detail.intro)
            }
            statusText = detail.status
            applyChapters(detail.chapters)
            ChapterCacheStore.saveChapters(detail.chapters, for: bookID)
            isLoadingChapters = false
        } catch {
            isLoadingChapters = false
            chapterError = error
            if let pErr = error as? PluginError {
                switch pErr {
                case .needLogin, .needVerify:
                    SourceStore.shared.markAuthExpired(sourceID: currentBookRef.sourceID)
                case .vipRequired, .builtinParserMissing, .builtinParserFailed, .timeout, .network, .rateLimited, .parseFailed:
                    break
                }
            }
        }
    }

    private func refreshChaptersSilently(oldCount: Int) async {
        do {
            let detail = try await fetchDetail(for: currentBookRef)
            guard !detail.chapters.isEmpty else { return }
            let diff = detail.chapters.count - oldCount
            applyChapters(detail.chapters)
            ChapterCacheStore.saveChapters(detail.chapters, for: currentBookRef.id)
            if diff > 0 {
                BannerCenter.shared.show("新增 \(diff) 章", kind: .info)
            }
        } catch {
            // 静默刷新失败不打断用户
        }
    }

    private func fetchDetail(for ref: BookRef) async throws -> BookDetailDTO {
        if let custom = customDetailLoader {
            return try await custom(ref)
        }
        return try await PluginRuntime.shared.bookDetail(sourceID: ref.sourceID, bookURL: ref.bookURL)
    }

    func visibleChapterSnapshots(
        currentPlayingChapterID: String?,
        isEnginePlaying: Bool,
        currentPlayingPositionMs: Int? = nil,
        downloadItems: [String: DownloadItem]? = nil,
        forceAllSegmentsWhenFiltered: Bool = false
    ) -> [ChapterRowSnapshot] {
        guard !chapters.isEmpty else { return [] }
        let bookID = currentBookRef.id
        let liveSnapshots = DownloadManager.shared.bookSnapshots(for: bookID)
        let deletingIDs = DownloadManager.shared.deletingItemIDs
        let kw = chapterSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let baseSlice: [ChapterDTO]
        if !kw.isEmpty {
            baseSlice = chapters.filter {
                $0.title.lowercased().contains(kw) || "\($0.index + 1)".contains(kw)
            }
        } else if isShowingDownloadedOnly || forceAllSegmentsWhenFiltered {
            baseSlice = chapters
        } else if segments.indices.contains(selectedSegmentIndex) {
            let seg = segments[selectedSegmentIndex]
            let end = min(seg.endIndex, chapters.count)
            baseSlice = Array(chapters[seg.startIndex..<end])
        } else {
            baseSlice = chapters
        }

        let ordered = isAscending ? baseSlice : Array(baseSlice.reversed())
        let progressMap = ChapterProgressCache.shared.allProgressMap(for: bookID)

        var results: [ChapterRowSnapshot] = []
        results.reserveCapacity(ordered.count)

        for ch in ordered {
            let itemID = "\(bookID)::\(ch.id)"
            let isDeleting = deletingIDs.contains(itemID)
            let dlState: ChapterDownloadState
            var dlBytes: Int64 = 0
            var statusNote: String? = nil

            if let snap = liveSnapshots[itemID] {
                dlBytes = snap.bytes
                switch snap.state {
                case "completed":
                    dlState = snap.isFileVerified ? .completed : .notDownloaded
                case "downloading", "queued", "waitingWiFi", "paused":
                    let p = DownloadManager.shared.itemProgress[itemID] ?? (snap.state == "downloading" ? 0.2 : 0.08)
                    dlState = .downloading(p)
                    if snap.state == "waitingWiFi" {
                        statusNote = "等待 Wi-Fi"
                    } else if snap.state == "paused" {
                        statusNote = "已暂停"
                    } else if snap.state == "queued" {
                        statusNote = "排队下载中"
                    }
                case "failed":
                    dlState = .failed
                default:
                    dlState = .notDownloaded
                }
            } else if let legacyMap = downloadItems, let dl = legacyMap[itemID] {
                dlBytes = dl.bytes
                switch dl.state {
                case "completed":
                    dlState = .completed
                case "downloading", "queued", "waitingWiFi", "paused":
                    let p = DownloadManager.shared.itemProgress[itemID] ?? 0.2
                    dlState = .downloading(p)
                case "failed":
                    dlState = .failed
                default:
                    dlState = .notDownloaded
                }
            } else {
                dlState = .notDownloaded
            }

            if isShowingDownloadedOnly && dlState == .notDownloaded && !isDeleting {
                continue
            }

            let isCurrent = (ch.id == currentPlayingChapterID)
            let cachedPos = progressMap[ch.id] ?? 0
            let pos: Int
            if isCurrent, let livePos = currentPlayingPositionMs, livePos > 0 {
                pos = livePos
            } else {
                pos = cachedPos
            }

            results.append(
                ChapterRowSnapshot(
                    chapter: ch,
                    displayIndex: ch.index + 1,
                    isCurrentPlayingChapter: isCurrent,
                    isEnginePlaying: isCurrent && isEnginePlaying,
                    savedPositionMs: pos,
                    isFinished: finishedChapterIDs.contains(ch.id),
                    isVIP: ch.title.uppercased().contains("VIP"),
                    downloadState: dlState,
                    downloadedBytes: dlBytes,
                    isDeleting: isDeleting,
                    downloadStatusNote: statusNote
                )
            )
        }
        return results
    }

    /// 修复 Bug 2：定位当前播放或上次收听章节（自动退出已下载过滤/搜索词并切换到目标章节所在的百章分段）
    func prepareToLocateChapter(
        currentPlayingChapterID: String?,
        savedChapterID: String?,
        savedChapterIndex: Int?
    ) -> (targetID: String, didSwitchContext: Bool)? {
        guard !chapters.isEmpty else { return nil }
        let targetIndex: Int
        if let playingID = currentPlayingChapterID,
           let idx = chapters.firstIndex(where: { $0.id == playingID }) {
            targetIndex = idx
        } else if let savedID = savedChapterID,
                  let idx = chapters.firstIndex(where: { $0.id == savedID }) {
            targetIndex = idx
        } else if let savedOneBased = savedChapterIndex,
                  savedOneBased > 0,
                  chapters.indices.contains(savedOneBased - 1) {
            targetIndex = savedOneBased - 1
        } else {
            return nil
        }

        let targetChapter = chapters[targetIndex]
        let targetSegIdx = targetIndex / 100
        var didSwitch = false

        if !chapterSearchKeyword.isEmpty {
            chapterSearchKeyword = ""
            didSwitch = true
        }
        if isShowingDownloadedOnly {
            isShowingDownloadedOnly = false
            didSwitch = true
        }
        if segments.indices.contains(targetSegIdx) && selectedSegmentIndex != targetSegIdx {
            selectedSegmentIndex = targetSegIdx
            didSwitch = true
        }
        return (targetChapter.id, didSwitch)
    }

    func toggleFinished(chapterID: String) {
        if finishedChapterIDs.contains(chapterID) {
            finishedChapterIDs.remove(chapterID)
        } else {
            finishedChapterIDs.insert(chapterID)
        }
    }

    func startOrRetryChapterDownload(_ snap: ChapterRowSnapshot) {
        let bookID = currentBookRef.id
        let realState = DownloadManager.shared.downloadState(bookID: bookID, chapterID: snap.chapter.id)
        if realState == .failed {
            if DownloadManager.shared.retryFailedChapter(bookID: bookID, chapterID: snap.chapter.id) {
                DSHapticPolicy.fire(.selection)
                BannerCenter.shared.show("已重新加入下载队列", kind: .info, bypassDeduplication: true)
                return
            }
        }
        do {
            let added = try DownloadManager.shared.enqueueChaptersWithCheck([snap.chapter], for: currentBookRef, kind: "manual")
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

    func confirmDeleteChapterDownload(_ snap: ChapterRowSnapshot) {
        let removed = DownloadManager.shared.invalidateLocalFile(
            bookID: currentBookRef.id,
            chapterID: snap.chapter.id
        )
        DSHapticPolicy.fire(.warning)
        BannerCenter.shared.show(
            removed ? "已删除第 \(snap.displayIndex) 章离线文件" : "离线文件不存在，已同步状态",
            kind: .info,
            bypassDeduplication: true
        )
    }

    func confirmClearAllBookDownloads() {
        DownloadManager.shared.removeDownloads(forBookID: currentBookRef.id)
        DSHapticPolicy.fire(.warning)
        BannerCenter.shared.show("已清空《\(currentBookRef.title)》全部离线章节", kind: .info, bypassDeduplication: true)
    }

    func enqueueRange(_ startOneBased: Int, _ endOneBased: Int) {
        guard !chapters.isEmpty else { return }
        let s = max(0, startOneBased - 1)
        let e = min(chapters.count, endOneBased)
        guard s < e else { return }
        let slice = Array(chapters[s..<e])
        do {
            let added = try DownloadManager.shared.enqueueChaptersWithCheck(slice, for: currentBookRef, kind: "manual")
            DSHapticPolicy.fire(.success)
            BannerCenter.shared.show(
                added > 0 ? "已加入下载 \(added) 章" : "所选区间章节均已下载或在队列中",
                kind: added > 0 ? .success : .info,
                bypassDeduplication: true
            )
        } catch {
            DSHapticPolicy.fire(.error)
            BannerCenter.shared.show(error.localizedDescription, kind: .error)
        }
    }

    func toggleShelfMembership(libraryStore: LibraryStore, context: ModelContext) {
        let nowInShelf = libraryStore.toggleShelfImmediate(
            for: currentBookRef,
            totalChapters: chapters.count,
            context: context
        )
        DSHapticPolicy.fire(nowInShelf ? .success : .selection)
        BannerCenter.shared.show(
            nowInShelf ? "已加入书架" : "已从书架移除",
            kind: nowInShelf ? .success : .info,
            bypassDeduplication: true
        )
    }
}

typealias BookDetailViewModel = BookDetailModel
