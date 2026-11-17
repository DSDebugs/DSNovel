import Foundation
import Observation
import SwiftData

enum LibraryFilter: Hashable, Equatable, Sendable {
    case all
    case inProgress
    case downloaded
    case updated
    case category(String)

    var title: String {
        switch self {
        case .all: return "全部"
        case .inProgress: return "在追"
        case .downloaded: return "已下载"
        case .updated: return "有更新"
        case .category(let id): return id
        }
    }
}

enum HistoryTimeGroup: String, CaseIterable, Identifiable, Sendable {
    case today = "today"
    case yesterday = "yesterday"
    case thisWeek = "thisWeek"
    case earlier = "earlier"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .earlier: return "更早"
        }
    }

    static func classify(date: Date, now: Date = .now, calendar: Calendar = .current) -> HistoryTimeGroup {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           date >= calendar.startOfDay(for: weekAgo) {
            return .thisWeek
        }
        return .earlier
    }
}

struct BookSnapshot: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var sourceID: String
    var bookURL: String
    var title: String
    var author: String
    var cover: String
    var intro: String
    var inShelf: Bool
    var addedAt: Date
    var categoryID: String?
    var lastChapterID: String?
    var lastChapterTitle: String?
    var lastChapterIndex: Int
    var totalChapters: Int
    var lastPositionMs: Int
    var lastPlayedAt: Date?
    var isPinned: Bool
    var hasUpdate: Bool
    var latestChapterCount: Int
    var updateCheckedAt: Date?

    var bookRef: BookRef {
        BookRef(
            id: id,
            sourceID: sourceID,
            bookURL: bookURL,
            title: title,
            author: author,
            cover: cover,
            intro: intro,
            chapterCount: max(totalChapters, latestChapterCount)
        )
    }

    var progressFraction: Double {
        if totalChapters > 0 && lastChapterIndex > 0 {
            return min(max(Double(lastChapterIndex) / Double(totalChapters), 0.02), 1.0)
        }
        return lastPositionMs > 0 ? 0.1 : 0.0
    }
}

@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    var modelContext: ModelContext? {
        didSet {
            observeContextNotifications()
            refreshNow()
        }
    }

    var selectedFilter: LibraryFilter = .all {
        didSet { recomputeDerived() }
    }
    var sortOrder: ShelfSortOrder = AppSettingsStore.shared.shelfSort {
        didSet {
            AppSettingsStore.shared.shelfSort = sortOrder
            recomputeDerived()
        }
    }

    private(set) var hasLoadedOnce: Bool = false
    private(set) var allShelfBooks: [Book] = []
    private(set) var shelfBookIDs: Set<String> = []
    private(set) var shelfBooks: [Book] = []
    private(set) var recentBooks: [Book] = []
    private(set) var continueBook: Book?
    private(set) var categories: [ShelfCategory] = []
    private(set) var filterCounts: [LibraryFilter: Int] = [:]
    private(set) var updatedCount: Int = 0
    private(set) var hiddenBookIDs: Set<String> = []
    private(set) var isCheckingUpdates: Bool = false

    private var saveObserver: NSObjectProtocol?
    private var throttleTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?

    var customChapterCountFetcher: ((BookRef) async throws -> Int)?

    init() {}

    private func observeContextNotifications() {
        if let token = saveObserver {
            NotificationCenter.default.removeObserver(token)
        }
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    func scheduleRefresh() {
        throttleTask?.cancel()
        throttleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard let ctx = modelContext else { return }
        let shelfDesc = FetchDescriptor<Book>(
            predicate: #Predicate<Book> { $0.inShelf == true }
        )
        let historyDesc = FetchDescriptor<Book>(
            predicate: #Predicate<Book> { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\Book.lastPlayedAt, order: .reverse)]
        )
        let catDesc = FetchDescriptor<ShelfCategory>(
            sortBy: [SortDescriptor(\ShelfCategory.order)]
        )

        let rawShelf = (try? ctx.fetch(shelfDesc)) ?? []
        let rawHistory = (try? ctx.fetch(historyDesc)) ?? []
        categories = (try? ctx.fetch(catDesc)) ?? []

        allShelfBooks = rawShelf.filter { !hiddenBookIDs.contains($0.id) }
        shelfBookIDs = Set(allShelfBooks.map(\.id))
        hasLoadedOnce = true
        let visibleHistory = rawHistory.filter { !hiddenBookIDs.contains($0.id) }

        continueBook = visibleHistory.first(where: { ($0.lastChapterID != nil) || $0.lastPositionMs > 0 }) ?? visibleHistory.first
        let continueID = continueBook?.id
        // 最近在听仅展示未加入书架且非继续收听主卡的历史书籍（E-01）
        recentBooks = Array(visibleHistory.filter { $0.id != continueID && !$0.inShelf }.prefix(8))

        recomputeDerived()
        scheduleBackfillChapterCountsIfNeeded()
    }

    func recomputeDerived(downloadedBookIDs: Set<String>? = nil) {
        let dlIDs = downloadedBookIDs ?? Set(
            DownloadManager.shared.summariesByBookID.values
                .filter { $0.completedCount > 0 }
                .map(\.bookID)
        )

        var counts: [LibraryFilter: Int] = [:]
        counts[.all] = allShelfBooks.count
        counts[.inProgress] = allShelfBooks.filter { Self.matchesFilter($0, filter: .inProgress, downloadedBookIDs: dlIDs) }.count
        counts[.downloaded] = allShelfBooks.filter { Self.matchesFilter($0, filter: .downloaded, downloadedBookIDs: dlIDs) }.count
        let upd = allShelfBooks.filter { Self.matchesFilter($0, filter: .updated, downloadedBookIDs: dlIDs) }.count
        counts[.updated] = upd
        updatedCount = upd
        for cat in categories {
            counts[.category(cat.id)] = allShelfBooks.filter { $0.categoryID == cat.id }.count
        }
        filterCounts = counts

        let filtered = allShelfBooks.filter {
            Self.matchesFilter($0, filter: selectedFilter, downloadedBookIDs: dlIDs)
        }
        shelfBooks = Self.sortBooks(filtered, by: sortOrder)
    }

    nonisolated static func matchesFilter(_ book: Book, filter: LibraryFilter, downloadedBookIDs: Set<String>) -> Bool {
        switch filter {
        case .all:
            return true
        case .inProgress:
            let hasProgress = (book.lastChapterID != nil || book.lastPositionMs > 0 || book.lastChapterIndex > 0)
            let isFinished = (book.totalChapters > 0 && book.lastChapterIndex >= book.totalChapters)
            return hasProgress && !isFinished
        case .downloaded:
            return downloadedBookIDs.contains(book.id)
        case .updated:
            return book.hasUpdate
        case .category(let catID):
            return book.categoryID == catID
        }
    }

    nonisolated static func sortBooks(_ books: [Book], by order: ShelfSortOrder) -> [Book] {
        books.sorted { a, b in
            if a.isPinned != b.isPinned {
                return a.isPinned && !b.isPinned
            }
            switch order {
            case .lastPlayed:
                let da = a.lastPlayedAt ?? a.addedAt
                let db = b.lastPlayedAt ?? b.addedAt
                if da != db { return da > db }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .addedAt:
                if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .title:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .recentlyUpdated:
                if a.hasUpdate != b.hasUpdate { return a.hasUpdate && !b.hasUpdate }
                let ua = a.updateCheckedAt ?? a.addedAt
                let ub = b.updateCheckedAt ?? b.addedAt
                if ua != ub { return ua > ub }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    nonisolated static func sortSnapshots(_ items: [BookSnapshot], by order: ShelfSortOrder) -> [BookSnapshot] {
        items.sorted { a, b in
            if a.isPinned != b.isPinned {
                return a.isPinned && !b.isPinned
            }
            switch order {
            case .lastPlayed:
                let da = a.lastPlayedAt ?? a.addedAt
                let db = b.lastPlayedAt ?? b.addedAt
                if da != db { return da > db }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .addedAt:
                if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .title:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .recentlyUpdated:
                if a.hasUpdate != b.hasUpdate { return a.hasUpdate && !b.hasUpdate }
                let ua = a.updateCheckedAt ?? a.addedAt
                let ub = b.updateCheckedAt ?? b.addedAt
                if ua != ub { return ua > ub }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    /// T3-03 检查更新：并发上限 3，同一本书 5 分钟内不重复请求，章节数增加置 hasUpdate = true
    @discardableResult
    func checkUpdates(now: Date = .now) async -> Int {
        guard !isCheckingUpdates else { return 0 }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        let candidates = allShelfBooks.filter { book in
            guard let checkedAt = book.updateCheckedAt else { return true }
            return now.timeIntervalSince(checkedAt) >= 300.0
        }
        guard !candidates.isEmpty else { return 0 }

        let fetcher = customChapterCountFetcher
        let refsAndBaseCounts: [(id: String, ref: BookRef, oldCount: Int)] = candidates.map {
            ($0.id, $0.bookRef, max($0.totalChapters, $0.latestChapterCount))
        }

        var updatedResults: [(id: String, newCount: Int)] = []
        let chunkSize = 3
        var start = 0
        while start < refsAndBaseCounts.count {
            let end = min(start + chunkSize, refsAndBaseCounts.count)
            let slice = Array(refsAndBaseCounts[start..<end])
            let batchResults = await withTaskGroup(of: (String, Int?).self) { group in
                for item in slice {
                    group.addTask {
                        do {
                            if let custom = fetcher {
                                let count = try await custom(item.ref)
                                return (item.id, count)
                            } else {
                                let detail = try await PluginRuntime.shared.bookDetail(
                                    sourceID: item.ref.sourceID,
                                    bookURL: item.ref.bookURL
                                )
                                return (item.id, detail.chapters.count)
                            }
                        } catch {
                            return (item.id, nil)
                        }
                    }
                }
                var collected: [(String, Int)] = []
                for await (id, count) in group {
                    if let count {
                        collected.append((id, count))
                    }
                }
                return collected
            }
            updatedResults.append(contentsOf: batchResults)
            start = end
        }

        var newlyUpdatedCount = 0
        let map = Dictionary(uniqueKeysWithValues: updatedResults)
        for book in candidates {
            if let latest = map[book.id] {
                let baseline = max(book.totalChapters, book.latestChapterCount)
                book.updateCheckedAt = now
                if latest > baseline && baseline > 0 {
                    book.hasUpdate = true
                    book.latestChapterCount = latest
                    book.totalChapters = latest
                    newlyUpdatedCount += 1
                } else if baseline == 0 && latest > 0 {
                    book.totalChapters = latest
                    book.latestChapterCount = latest
                }
            }
        }
        try? modelContext?.save()
        refreshNow()
        return newlyUpdatedCount
    }

    func markUpdateRead(bookID: String) {
        guard let book = allShelfBooks.first(where: { $0.id == bookID }), book.hasUpdate else { return }
        book.hasUpdate = false
        try? modelContext?.save()
        refreshNow()
    }

    /// T3-03 合并三处 backfillMissingChapterCountsIfNeeded 为 Store 内单点 1 秒节流
    private func scheduleBackfillChapterCountsIfNeeded() {
        backfillTask?.cancel()
        backfillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            var changed = false
            for book in self.allShelfBooks where book.totalChapters <= 0 {
                if let cached = ChapterCacheStore.loadChapters(for: book.id), !cached.isEmpty {
                    book.totalChapters = cached.count
                    changed = true
                }
            }
            if changed {
                try? self.modelContext?.save()
                self.recomputeDerived()
            }
        }
    }

    // MARK: - 书架可逆移除（配合 BannerCenter.showUndo）

    func removeFromShelfDeferred(_ books: [Book]) {
        let ids = Set(books.map(\.id))
        guard !ids.isEmpty else { return }
        hiddenBookIDs.formUnion(ids)
        refreshNow()

        let titleDesc = books.count == 1 ? "已移出《\(books[0].title)》" : "已移出 \(books.count) 本书"
        BannerCenter.shared.showUndo(
            titleDesc,
            onUndo: { [weak self] in
                self?.hiddenBookIDs.subtract(ids)
                self?.refreshNow()
            },
            onCommit: { [weak self] in
                guard let self, let ctx = self.modelContext else { return }
                for b in books {
                    if b.lastPlayedAt != nil {
                        b.inShelf = false
                    } else {
                        ctx.delete(b)
                    }
                }
                self.hiddenBookIDs.subtract(ids)
                try? ctx.save()
                self.refreshNow()
            }
        )
    }

    func deleteHistoryDeferred(_ book: Book) {
        let bid = book.id
        hiddenBookIDs.insert(bid)
        refreshNow()

        BannerCenter.shared.showUndo(
            "已删除《\(book.title)》播放记录",
            onUndo: { [weak self] in
                self?.hiddenBookIDs.remove(bid)
                self?.refreshNow()
            },
            onCommit: { [weak self] in
                guard let self, let ctx = self.modelContext else { return }
                if book.inShelf {
                    book.lastPlayedAt = nil
                    book.lastChapterID = nil
                    book.lastChapterTitle = nil
                    book.lastChapterIndex = 0
                    book.lastPositionMs = 0
                } else {
                    ctx.delete(book)
                }
                self.hiddenBookIDs.remove(bid)
                try? ctx.save()
                self.refreshNow()
            }
        )
    }

    func clearAllHistory() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.lastPlayedAt != nil })
        let items = (try? ctx.fetch(desc)) ?? []
        for b in items {
            if b.inShelf {
                b.lastPlayedAt = nil
                b.lastChapterID = nil
                b.lastChapterTitle = nil
                b.lastChapterIndex = 0
                b.lastPositionMs = 0
            } else {
                ctx.delete(b)
            }
        }
        try? ctx.save()
        refreshNow()
    }

    func allHistoryGrouped(now: Date = .now, calendar: Calendar = .current) -> [(group: HistoryTimeGroup, books: [Book])] {
        guard let ctx = modelContext else { return [] }
        let desc = FetchDescriptor<Book>(
            predicate: #Predicate<Book> { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\Book.lastPlayedAt, order: .reverse)]
        )
        let list = ((try? ctx.fetch(desc)) ?? []).filter { !hiddenBookIDs.contains($0.id) }
        var buckets: [HistoryTimeGroup: [Book]] = [:]
        for b in list {
            let group = HistoryTimeGroup.classify(date: b.lastPlayedAt ?? b.addedAt, now: now, calendar: calendar)
            buckets[group, default: []].append(b)
        }
        return HistoryTimeGroup.allCases.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return (g, items)
        }
    }
}
