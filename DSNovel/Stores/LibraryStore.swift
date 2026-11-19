import Foundation
import Observation
import SwiftData

enum LibraryFilter: Hashable, Equatable, Sendable {
    case all
    case inProgress
    case downloaded
    case updated

    var title: String {
        switch self {
        case .all: return "全部"
        case .inProgress: return "在追"
        case .downloaded: return "已下载"
        case .updated: return "有更新"
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
    private(set) var allKnownBooksByID: [String: Book] = [:]
    private(set) var allShelfBooks: [Book] = []
    private(set) var shelfBookIDs: Set<String> = []
    private(set) var shelfBooks: [Book] = []
    private(set) var recentBooks: [Book] = []
    private(set) var continueBook: Book?
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
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard let ctx = modelContext else { return }
        let allBooksDesc = FetchDescriptor<Book>()
        let historyDesc = FetchDescriptor<Book>(
            predicate: #Predicate<Book> { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\Book.lastPlayedAt, order: .reverse)]
        )

        let rawAllBooks = (try? ctx.fetch(allBooksDesc)) ?? []
        let rawHistory = (try? ctx.fetch(historyDesc)) ?? []

        var byID: [String: Book] = [:]
        for b in rawAllBooks {
            byID[b.id] = b
        }
        allKnownBooksByID = byID

        let rawShelf = rawAllBooks.filter { $0.inShelf }
        allShelfBooks = rawShelf.filter { !hiddenBookIDs.contains($0.id) }
        shelfBookIDs = Set(allShelfBooks.map(\.id))
        hasLoadedOnce = true
        let visibleHistory = rawHistory.filter { !hiddenBookIDs.contains($0.id) }

        continueBook = visibleHistory.first(where: { ($0.lastChapterID != nil) || $0.lastPositionMs > 0 }) ?? visibleHistory.first
        let continueID = continueBook?.id
        recentBooks = Array(visibleHistory.filter { $0.id != continueID && !$0.inShelf }.prefix(8))

        recomputeDerived()
        scheduleBackfillChapterCountsIfNeeded()
    }

    /// 查找任意书籍的持久化记录（即使该书已被移出书架或处于延迟撤销状态，仍保留其播放进度供书籍详情页使用）
    func book(for bookID: String?, fallbackContext: ModelContext? = nil) -> Book? {
        guard let bookID, !bookID.isEmpty else { return nil }
        if let cached = allKnownBooksByID[bookID] {
            return cached
        }
        if let ctx = fallbackContext ?? modelContext {
            let desc = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
            return try? ctx.fetch(desc).first
        }
        return nil
    }

    func isBookInShelf(_ bookID: String?, fallbackContext: ModelContext? = nil) -> Bool {
        guard let bookID, !bookID.isEmpty else { return false }
        if hiddenBookIDs.contains(bookID) {
            return false
        }
        if shelfBookIDs.contains(bookID) {
            return true
        }
        if let ctx = fallbackContext ?? modelContext {
            let desc = FetchDescriptor<Book>(
                predicate: #Predicate<Book> { $0.id == bookID && $0.inShelf == true }
            )
            if let existing = try? ctx.fetch(desc).first {
                return existing.inShelf
            }
        }
        return false
    }

    @discardableResult
    func toggleShelfImmediate(
        for bookRef: BookRef,
        totalChapters: Int = 0,
        context: ModelContext? = nil
    ) -> Bool {
        let resolvedContext = context ?? modelContext
        if modelContext == nil, let resolvedContext {
            modelContext = resolvedContext
        }
        guard let ctx = resolvedContext else { return false }

        let targetID = bookRef.id
        let wasHidden = hiddenBookIDs.contains(targetID)
        if wasHidden {
            hiddenBookIDs.remove(targetID)
            BannerCenter.shared.cancelPendingUndoWithoutCommit()
        }

        let desc = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == targetID })
        let existing = (try? ctx.fetch(desc))?.first

        let currentlyInShelf: Bool
        if let existing {
            currentlyInShelf = existing.inShelf && !wasHidden
        } else {
            currentlyInShelf = false
        }

        let nextInShelf = !currentlyInShelf
        if let existing {
            existing.inShelf = nextInShelf
            if nextInShelf {
                existing.addedAt = .now
                if existing.cover.isEmpty && !bookRef.cover.isEmpty {
                    existing.cover = bookRef.cover
                }
                if existing.author.isEmpty && !bookRef.author.isEmpty {
                    existing.author = bookRef.author
                }
                if totalChapters > 0 && existing.totalChapters == 0 {
                    existing.totalChapters = totalChapters
                }
            }
        } else if nextInShelf {
            let newBook = Book(
                id: bookRef.id,
                sourceID: bookRef.sourceID,
                bookURL: bookRef.bookURL,
                title: bookRef.title,
                author: bookRef.author,
                cover: bookRef.cover,
                intro: bookRef.intro,
                inShelf: true,
                addedAt: .now,
                totalChapters: max(totalChapters, bookRef.chapterCount),
                speed: AppSettingsStore.shared.defaultSpeed
            )
            ctx.insert(newBook)
        }

        try? ctx.save()
        refreshNow()
        return nextInShelf
    }

    func recomputeDerived(downloadedBookIDs: Set<String>? = nil) {
        let dlSummaries = DownloadManager.shared.summariesByBookID
        let dlIDs = downloadedBookIDs ?? Set(
            dlSummaries.values
                .filter { $0.completedCount > 0 || $0.activeCount > 0 }
                .map(\.bookID)
        )

        // 构建完整的已下载书籍候选集（含已加书架及未加书架但已下载章节的书籍）
        var downloadedCandidates: [Book] = allShelfBooks.filter { dlIDs.contains($0.id) }
        let shelfIDSet = Set(downloadedCandidates.map(\.id))
        for bid in dlIDs where !shelfIDSet.contains(bid) && !hiddenBookIDs.contains(bid) {
            if let known = allKnownBooksByID[bid] {
                downloadedCandidates.append(known)
            } else if let sum = dlSummaries[bid] {
                let parts = bid.components(separatedBy: "::")
                let bURL = parts.count > 1 ? parts.dropFirst().joined(separator: "::") : bid
                let transient = Book(
                    id: bid,
                    sourceID: sum.sourceID,
                    bookURL: bURL,
                    title: sum.bookTitle,
                    inShelf: false,
                    totalChapters: max(sum.totalCount, ChapterCacheStore.loadChapters(for: bid)?.count ?? 0)
                )
                downloadedCandidates.append(transient)
            }
        }

        var counts: [LibraryFilter: Int] = [:]
        counts[.all] = allShelfBooks.count
        counts[.inProgress] = allShelfBooks.filter { Self.matchesFilter($0, filter: .inProgress, downloadedBookIDs: dlIDs) }.count
        counts[.downloaded] = downloadedCandidates.count
        let upd = allShelfBooks.filter { Self.matchesFilter($0, filter: .updated, downloadedBookIDs: dlIDs) }.count
        counts[.updated] = upd
        updatedCount = upd
        filterCounts = counts

        let filtered: [Book]
        if selectedFilter == .downloaded {
            filtered = downloadedCandidates
        } else {
            filtered = allShelfBooks.filter {
                Self.matchesFilter($0, filter: selectedFilter, downloadedBookIDs: dlIDs)
            }
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
                for b in books where self.hiddenBookIDs.contains(b.id) {
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
