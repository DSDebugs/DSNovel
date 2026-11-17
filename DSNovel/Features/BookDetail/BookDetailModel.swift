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
        if downloadState == .completed {
            parts.append("已下载")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class BookDetailModel {
    var currentBookRef: BookRef
    var alternatives: [BookRef]
    private(set) var cleanedIntro: String = ""
    private(set) var statusText: String = ""
    private(set) var chapters: [ChapterDTO] = []
    private(set) var segments: [ChapterSegmentItem] = []
    var selectedSegmentIndex: Int = 0
    var isAscending: Bool = true
    var chapterSearchKeyword: String = ""
    private(set) var isLoadingChapters: Bool = false
    private(set) var chapterError: Error?
    private(set) var finishedChapterIDs: Set<String> = []

    var customDetailLoader: ((BookRef) async throws -> BookDetailDTO)?

    init(book: BookRef, alternatives: [BookRef] = []) {
        self.currentBookRef = book
        self.alternatives = alternatives
        self.cleanedIntro = Self.cleanHTML(book.intro)
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

    /// T4-3 换源进度匹配算法：标题相同 → 序号相同 → 都不匹配则保持当前有效序号（钳制在合法范围）
    nonisolated static func matchChapterIndexForSourceSwitch(
        currentIndex: Int,
        currentTitle: String,
        targetChapters: [ChapterDTO]
    ) -> Int {
        guard !targetChapters.isEmpty else { return 0 }
        let normalizedCurrent = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedCurrent.isEmpty,
           let matchedByTitle = targetChapters.firstIndex(where: {
               $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedCurrent
           }) {
            return matchedByTitle
        }
        if targetChapters.indices.contains(currentIndex) {
            return currentIndex
        }
        return min(max(0, currentIndex), targetChapters.count - 1)
    }

    nonisolated static func cleanHTML(_ raw: String) -> String {
        guard !raw.isEmpty else { return "暂无作品简介" }
        let stripped = raw
            .replacingOccurrences(of: "<br\s*/?>", with: "
", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "
", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: """)
            .replacingOccurrences(of: "&amp;", with: "&")
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

    func loadChaptersIfNeeded(forceRefresh: Bool = false) async {
        let bookID = currentBookRef.id
        if !forceRefresh,
           let cached = ChapterCacheStore.loadChapters(for: bookID),
           !cached.isEmpty {
            applyChapters(cached)
            let age = ChapterCacheStore.cacheAge(for: bookID) ?? 9999
            if age < 600 {
                // 10 分钟内直接使用缓存并后台静默刷新
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
        downloadItems: [String: DownloadItem]
    ) -> [ChapterRowSnapshot] {
        guard !chapters.isEmpty else { return [] }
        let kw = chapterSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseSlice: [ChapterDTO]
        if !kw.isEmpty {
            baseSlice = chapters.filter { $0.title.lowercased().contains(kw) }
        } else if segments.indices.contains(selectedSegmentIndex) {
            let seg = segments[selectedSegmentIndex]
            let end = min(seg.endIndex, chapters.count)
            baseSlice = Array(chapters[seg.startIndex..<end])
        } else {
            baseSlice = chapters
        }

        let ordered = isAscending ? baseSlice : Array(baseSlice.reversed())
        let progressMap = ChapterProgressCache.shared.allProgressMap(for: currentBookRef.id)

        return ordered.map { ch in
            let itemID = "\(currentBookRef.id)::\(ch.id)"
            let dl = downloadItems[itemID]
            let dlState: ChapterDownloadState
            if let dl {
                switch dl.state {
                case "completed":
                    dlState = .completed
                case "downloading", "queued", "waitingWiFi":
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
            let pos = progressMap[ch.id] ?? 0
            return ChapterRowSnapshot(
                chapter: ch,
                displayIndex: ch.index + 1,
                isCurrentPlayingChapter: ch.id == currentPlayingChapterID,
                isEnginePlaying: ch.id == currentPlayingChapterID && isEnginePlaying,
                savedPositionMs: pos,
                isFinished: finishedChapterIDs.contains(ch.id),
                isVIP: ch.title.uppercased().contains("VIP"),
                downloadState: dlState
            )
        }
    }

    func toggleFinished(chapterID: String) {
        if finishedChapterIDs.contains(chapterID) {
            finishedChapterIDs.remove(chapterID)
        } else {
            finishedChapterIDs.insert(chapterID)
        }
    }

    func switchSource(
        to target: BookRef,
        currentChapterIndex: Int,
        currentChapterTitle: String,
        in context: ModelContext?
    ) async -> Int {
        currentBookRef = target
        await loadChaptersIfNeeded(forceRefresh: true)
        let matchedIndex = Self.matchChapterIndexForSourceSwitch(
            currentIndex: currentChapterIndex,
            currentTitle: currentChapterTitle,
            targetChapters: chapters
        )
        let sourceName = SourceStore.shared.sourceName(for: target.sourceID)
        BannerCenter.shared.show("已切换到 \(sourceName)，进度保持在第 \(matchedIndex + 1) 章", kind: .success)
        return matchedIndex
    }

    func currentBookDownloadMap() -> [String: DownloadItem] {
        guard let ctx = DownloadManager.shared.modelContext else { return [:] }
        let bid = currentBookRef.id
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.bookID == bid })
        let items = (try? ctx.fetch(desc)) ?? []
        var map: [String: DownloadItem] = [:]
        for item in items {
            map[item.id] = item
        }
        return map
    }

    func handleChapterDownloadTap(_ snap: ChapterRowSnapshot) {
        if snap.downloadState == .completed {
            DownloadManager.shared.invalidateLocalFile(bookID: currentBookRef.id, chapterID: snap.chapter.id)
            BannerCenter.shared.show("已删除该章离线文件", kind: .info)
        } else {
            DownloadManager.shared.enqueueChapters([snap.chapter], for: currentBookRef, kind: "manual")
            BannerCenter.shared.show("已加入下载 1 章", kind: .success)
        }
    }

    func enqueueRange(_ startOneBased: Int, _ endOneBased: Int) {
        guard !chapters.isEmpty else { return }
        let s = max(0, startOneBased - 1)
        let e = min(chapters.count, endOneBased)
        guard s < e else { return }
        let slice = Array(chapters[s..<e])
        DownloadManager.shared.enqueueChapters(slice, for: currentBookRef, kind: "manual")
        DSHapticPolicy.fire(.success)
        BannerCenter.shared.show("已加入下载 \(slice.count) 章", kind: .success)
    }

    func toggleShelfMembership(savedBook: Book?, libraryStore: LibraryStore, context: ModelContext) {
        if let existing = savedBook {
            if existing.inShelf {
                libraryStore.removeFromShelfDeferred([existing])
            } else {
                existing.inShelf = true
                try? context.save()
                DSHapticPolicy.fire(.success)
                BannerCenter.shared.show("已加入书架", kind: .success)
                libraryStore.refreshNow()
            }
        } else {
            let ref = currentBookRef
            let b = Book(
                id: ref.id,
                sourceID: ref.sourceID,
                bookURL: ref.bookURL,
                title: ref.title,
                author: ref.author,
                cover: ref.cover,
                intro: ref.intro,
                inShelf: true,
                totalChapters: chapters.count
            )
            context.insert(b)
            try? context.save()
            DSHapticPolicy.fire(.success)
            BannerCenter.shared.show("已加入书架", kind: .success)
            libraryStore.refreshNow()
        }
    }
}

typealias BookDetailViewModel = BookDetailModel
