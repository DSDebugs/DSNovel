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
    let durationMs: Int
    let isFinished: Bool
    let isVIP: Bool
    let downloadState: ChapterDownloadState
    let downloadedBytes: Int64
    /// 磁盘是否存在已校验的本地离线文件（含按新音质重下期间保留的旧文件）
    let hasLocalFile: Bool
    let isDeleting: Bool
    let downloadStatusNote: String?
    /// 列表展示用标题（已去掉重复的书名前缀）；默认等于 chapter.title
    let displayTitle: String
    /// P1：在构建章节列表快照时一次性预计算旧音质状态，避免 ChapterRow 渲染期逐行查询
    let isQualityStale: Bool
    /// 下载条目 ID（用于叶子进度环订阅 DownloadProgressStore）
    let downloadItemID: String

    init(
        chapter: ChapterDTO,
        displayIndex: Int,
        isCurrentPlayingChapter: Bool,
        isEnginePlaying: Bool,
        savedPositionMs: Int,
        durationMs: Int = 0,
        isFinished: Bool,
        isVIP: Bool,
        downloadState: ChapterDownloadState,
        downloadedBytes: Int64 = 0,
        hasLocalFile: Bool = false,
        isDeleting: Bool = false,
        downloadStatusNote: String? = nil,
        displayTitle: String? = nil,
        isQualityStale: Bool = false,
        downloadItemID: String = ""
    ) {
        self.chapter = chapter
        self.displayIndex = displayIndex
        self.isCurrentPlayingChapter = isCurrentPlayingChapter
        self.isEnginePlaying = isEnginePlaying
        self.savedPositionMs = savedPositionMs
        self.durationMs = durationMs
        self.isFinished = isFinished
        self.isVIP = isVIP
        self.downloadState = downloadState
        self.downloadedBytes = downloadedBytes
        self.hasLocalFile = hasLocalFile
        self.isDeleting = isDeleting
        self.downloadStatusNote = downloadStatusNote
        self.displayTitle = displayTitle ?? chapter.title
        self.isQualityStale = isQualityStale
        self.downloadItemID = downloadItemID
    }

    var effectiveDurationMs: Int {
        if durationMs > 0 { return durationMs }
        if let durSec = chapter.normalizedDurationSec, durSec > 0 {
            return durSec * 1000
        }
        return 0
    }

    var progressFraction: Double {
        guard savedPositionMs > 0 else { return 0 }
        let durMs = max(effectiveDurationMs, 1)
        guard effectiveDurationMs > 0 else { return 0 }
        return min(max(Double(savedPositionMs) / Double(durMs), 0.01), 1.0)
    }

    var progressPercent: Int? {
        guard !isFinished, savedPositionMs > 0 else { return nil }
        let durMs = effectiveDurationMs
        guard durMs > 0 else { return nil }
        return min(99, max(1, Int((Double(savedPositionMs) / Double(durMs) * 100.0).rounded())))
    }

    func subtitleText(overridePositionMs: Int? = nil, overrideDurationMs: Int? = nil) -> String {
        let posMs = overridePositionMs ?? savedPositionMs
        let durMs = (overrideDurationMs ?? 0) > 0 ? (overrideDurationMs ?? 0) : effectiveDurationMs
        var parts: [String] = []
        if let dur = chapter.normalizedDurationSec {
            parts.append(PlaybackClock.formatSeconds(Double(dur)))
        } else if durMs > 0 {
            parts.append(PlaybackClock.formatSeconds(Double(durMs) / 1000.0))
        }

        if isFinished {
            parts.append("已播完")
        } else if posMs > 0 {
            if durMs > 0 {
                let pct = min(99, max(1, Int((Double(posMs) / Double(durMs) * 100.0).rounded())))
                parts.append("已播 \(pct)%")
            } else {
                parts.append("已播")
            }
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

    var subtitleText: String {
        subtitleText()
    }
}

@MainActor
@Observable
final class BookDetailModel {
    static let emptyIntroPlaceholder = "暂无作品简介"

    var currentBookRef: BookRef {
        didSet {
            if currentBookRef.id != oldValue.id {
                cancelPendingTasks()
            }
        }
    }
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
    private(set) var hasFetchedFullIntro: Bool = false
    private(set) var isLoadingIntro: Bool = false

    @ObservationIgnored
    private var activeLoadTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadGeneration: UInt64 = 0
    @ObservationIgnored
    private var silentRefreshTask: Task<Void, Never>?

    var customDetailLoader: ((BookRef) async throws -> BookDetailDTO)?

    var hasIntroContent: Bool {
        let trimmed = cleanedIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != Self.emptyIntroPlaceholder
    }

    init(book: BookRef, preferDownloaded: Bool = false) {
        self.currentBookRef = book
        self.preferDownloadedOnAppear = preferDownloaded
        self.cleanedIntro = Self.cleanHTML(book.intro)
        if preferDownloaded {
            self.isShowingDownloadedOnly = true
        }
    }

    func cancelPendingTasks() {
        loadGeneration &+= 1
        activeLoadTask?.cancel()
        activeLoadTask = nil
        silentRefreshTask?.cancel()
        silentRefreshTask = nil
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
        guard !raw.isEmpty else { return emptyIntroPlaceholder }
        let stripped = raw
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "([0-9]+)\\s*集", with: "$1 章", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? emptyIntroPlaceholder : stripped
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
        cancelPendingTasks()
        let generation = loadGeneration
        let bookRef = currentBookRef
        let bookID = bookRef.id

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if !forceRefresh,
               let cached = await ChapterCacheStore.loadChaptersAsync(for: bookID),
               !cached.isEmpty {
                guard !Task.isCancelled, generation == self.loadGeneration, self.currentBookRef.id == bookID else { return }
                self.applyChapters(cached)
                let age = ChapterCacheStore.cacheAge(for: bookID) ?? 9999
                if age < 600 {
                    let cachedCount = cached.count
                    self.silentRefreshTask = Task { [weak self] in
                        await self?.refreshChaptersSilently(
                            oldCount: cachedCount,
                            expectedBookID: bookID,
                            generation: generation
                        )
                    }
                    return
                }
            }

            guard !Task.isCancelled, generation == self.loadGeneration, self.currentBookRef.id == bookID else { return }
            self.isLoadingChapters = self.chapters.isEmpty
            self.chapterError = nil
            do {
                let detail = try await self.fetchDetail(for: bookRef)
                guard !Task.isCancelled, generation == self.loadGeneration, self.currentBookRef.id == bookID else { return }
                if !detail.intro.isEmpty {
                    self.cleanedIntro = Self.cleanHTML(detail.intro)
                }
                self.hasFetchedFullIntro = true
                self.statusText = detail.status
                self.applyChapters(detail.chapters)
                ChapterCacheStore.saveChapters(detail.chapters, for: bookID)
                self.isLoadingChapters = false
            } catch {
                guard !Task.isCancelled, generation == self.loadGeneration, self.currentBookRef.id == bookID else { return }
                self.isLoadingChapters = false
                self.chapterError = error
                if let pErr = error as? PluginError {
                    switch pErr {
                    case .needLogin, .needVerify:
                        SourceStore.shared.markAuthExpired(sourceID: bookRef.sourceID)
                    case .vipRequired, .builtinParserMissing, .builtinParserFailed, .timeout, .network, .rateLimited, .parseFailed:
                        break
                    }
                }
            }
        }
        activeLoadTask = task
        await task.value
    }

    private func refreshChaptersSilently(oldCount: Int, expectedBookID: String, generation: UInt64) async {
        guard !Task.isCancelled, generation == loadGeneration, currentBookRef.id == expectedBookID else { return }
        let bookRef = currentBookRef
        do {
            let detail = try await fetchDetail(for: bookRef)
            guard !Task.isCancelled, generation == loadGeneration, currentBookRef.id == expectedBookID else { return }
            if !detail.intro.isEmpty {
                cleanedIntro = Self.cleanHTML(detail.intro)
            }
            if !detail.status.isEmpty {
                statusText = detail.status
            }
            hasFetchedFullIntro = true
            guard !detail.chapters.isEmpty else { return }
            let diff = detail.chapters.count - oldCount
            applyChapters(detail.chapters)
            ChapterCacheStore.saveChapters(detail.chapters, for: expectedBookID)
            if diff > 0 {
                BannerCenter.shared.show("新增 \(diff) 章", kind: .info)
            }
        } catch {
            // 静默刷新失败不打断用户
        }
    }

    func loadFullIntroIfNeeded() async {
        guard !hasFetchedFullIntro, !isLoadingIntro else { return }
        let expectedBookID = currentBookRef.id
        isLoadingIntro = true
        defer { isLoadingIntro = false }
        do {
            let detail: BookDetailDTO
            if let custom = customDetailLoader {
                detail = try await custom(currentBookRef)
            } else {
                detail = try await PluginRuntime.shared.bookDetail(
                    sourceID: currentBookRef.sourceID,
                    bookURL: currentBookRef.bookURL,
                    loadEpisodes: false,
                    loadFullPages: false
                )
            }
            guard !Task.isCancelled, currentBookRef.id == expectedBookID else { return }
            if !detail.intro.isEmpty {
                cleanedIntro = Self.cleanHTML(detail.intro)
            }
            if !detail.status.isEmpty {
                statusText = detail.status
            }
            hasFetchedFullIntro = true
        } catch {
            // 保持已有简介，不打断用户展开浏览
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
        let currentTierRaw = DownloadManager.shared.effectiveQualityTier(forBookID: bookID).rawValue
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
        let progressSnapshots = ChapterProgressCache.shared.allSnapshotsMap(for: bookID)

        var results: [ChapterRowSnapshot] = []
        results.reserveCapacity(ordered.count)

        let bookMainTitle = BookTitleFormatter.split(currentBookRef.title).main

        for ch in ordered {
            let itemID = "\(bookID)::\(ch.id)"
            let isDeleting = deletingIDs.contains(itemID)
            let dlState: ChapterDownloadState
            var dlBytes: Int64 = 0
            var hasLocalFile = false
            var statusNote: String? = nil
            var isQualityStale = false

            if let snap = liveSnapshots[itemID] {
                dlBytes = snap.bytes
                hasLocalFile = !snap.localPath.isEmpty && snap.isFileVerified
                isQualityStale = snap.isFileVerified && snap.isStale(against: currentTierRaw)
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
                hasLocalFile = !dl.localPath.isEmpty && DownloadManager.shared.verifyFileExists(localPath: dl.localPath)
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
            let progSnap = progressSnapshots[ch.id]
            let cachedPos = progSnap?.positionMs ?? 0
            let pos: Int
            if isCurrent, let livePos = currentPlayingPositionMs, livePos > 0 {
                pos = livePos
            } else {
                pos = cachedPos
            }
            let durMs = max(progSnap?.durationMs ?? 0, (ch.normalizedDurationSec ?? 0) * 1000)
            let autoDone = durMs > 0 && pos >= Int(Double(durMs) * 0.98)
            let isDone = finishedChapterIDs.contains(ch.id) || (progSnap?.isFinished == true) || autoDone

            results.append(
                ChapterRowSnapshot(
                    chapter: ch,
                    displayIndex: ch.index + 1,
                    isCurrentPlayingChapter: isCurrent,
                    isEnginePlaying: isCurrent && isEnginePlaying,
                    savedPositionMs: pos,
                    durationMs: durMs,
                    isFinished: isDone,
                    isVIP: ch.title.uppercased().contains("VIP"),
                    downloadState: dlState,
                    downloadedBytes: dlBytes,
                    hasLocalFile: hasLocalFile,
                    isDeleting: isDeleting,
                    downloadStatusNote: statusNote,
                    displayTitle: BookTitleFormatter.stripBookPrefix(from: ch.title, bookMainTitle: bookMainTitle),
                    isQualityStale: isQualityStale,
                    downloadItemID: itemID
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
        let wasFinished = finishedChapterIDs.contains(chapterID)
            || (ChapterProgressCache.shared.progress(bookID: currentBookRef.id, chapterID: chapterID)?.isFinished == true)
        let nextFinished = !wasFinished
        if nextFinished {
            finishedChapterIDs.insert(chapterID)
        } else {
            finishedChapterIDs.remove(chapterID)
        }
        let durMs = (chapters.first(where: { $0.id == chapterID })?.normalizedDurationSec ?? 0) * 1000
        ChapterProgressCache.shared.setFinished(
            bookID: currentBookRef.id,
            chapterID: chapterID,
            isFinished: nextFinished,
            durationMs: durMs
        )
    }

    /// D-7：下载/重下三态文案统一口径（added > 0 / 重下中 / 旧音质离线 / 已在下载队列中）
    static func chapterDownloadBannerCopy(added: Int, isReDownloading: Bool, isStale: Bool) -> String {
        if added > 0 {
            return "已加入下载 \(added) 章"
        }
        if isReDownloading {
            return "该章正在按新音质重下（旧文件可先播放）"
        }
        if isStale {
            return "该章为旧音质离线文件，可在下载页按新音质重下"
        }
        return "该章已在下载队列中"
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
            let chapterID = snap.chapter.id
            let isReDL = DownloadManager.shared.isReDownloading(bookID: bookID, chapterID: chapterID)
            let isStale = DownloadManager.shared.isChapterQualityStale(bookID: bookID, chapterID: chapterID)
            let text = Self.chapterDownloadBannerCopy(added: added, isReDownloading: isReDL, isStale: isStale)
            BannerCenter.shared.show(
                text,
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
