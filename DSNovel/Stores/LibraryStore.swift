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

    private struct BookStructuralKey: Equatable {
        let id: String
        let inShelf: Bool
        let isPinned: Bool
        let hasUpdate: Bool
        let totalChapters: Int
        let latestChapterCount: Int
        let title: String
        let author: String
        let cover: String
        let addedAt: Date
        let updateCheckedAt: Date?
        let lastChapterID: String?
        let lastChapterIndex: Int
        let hasProgress: Bool
    }

    private struct StructuralSignature: Equatable {
        let books: [BookStructuralKey]
        let continueBookID: String?
        let recentBookIDs: [String]
        let sortedShelfIDs: [String]
        let hiddenShelfBookIDs: Set<String>
        let hiddenHistoryBookIDs: Set<String>
    }

    var modelContext: ModelContext? {
        didSet {
            guard oldValue !== modelContext else { return }
            lastStructuralSignature = nil
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
            lastStructuralSignature = nil
            recomputeDerived()
        }
    }

    private(set) var hasLoadedOnce: Bool = false
    private(set) var allKnownBooksByID: [String: Book] = [:]
    private(set) var allShelfBooks: [Book] = []
    private(set) var shelfBookIDs: Set<String> = []
    private(set) var shelfBooks: [Book] = []
    private(set) var recentBooks: [Book] = []
    private(set) var historyBooks: [Book] = []
    private(set) var cachedHistorySections: [(group: HistoryTimeGroup, books: [Book])] = []
    private(set) var continueBook: Book?
    private(set) var filterCounts: [LibraryFilter: Int] = [:]
    private(set) var updatedCount: Int = 0
    private(set) var hiddenShelfBookIDs: Set<String> = []
    private(set) var hiddenHistoryBookIDs: Set<String> = []
    var hiddenBookIDs: Set<String> {
        hiddenShelfBookIDs.union(hiddenHistoryBookIDs)
    }
    private(set) var isCheckingUpdates: Bool = false

    @ObservationIgnored nonisolated(unsafe) private var saveObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var throttleTask: Task<Void, Never>?
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var backfillAttemptedBookIDs: Set<String> = []
    @ObservationIgnored private var lastStructuralSignature: StructuralSignature?
    @ObservationIgnored private var cachedChapterCountsByBookID: [String: Int] = [:]
    @ObservationIgnored private var pendingChapterCountBookIDs: Set<String> = []

    var customChapterCountFetcher: ((BookRef) async throws -> Int)?

    init() {}

    deinit {
        if let token = saveObserver {
            NotificationCenter.default.removeObserver(token)
        }
        throttleTask?.cancel()
    }

    private static func didSaveAffectBooks(_ notification: Notification) -> Bool {
        guard let userInfo = notification.userInfo else { return true }
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers
        ]
        var hasIdentifierCollection = false
        for key in keys {
            let rawValue = userInfo[key] ?? userInfo[key.rawValue]
            if let ids = rawValue as? [PersistentIdentifier] {
                hasIdentifierCollection = true
                if ids.contains(where: { $0.entityName == "Book" }) {
                    return true
                }
            } else if let ids = rawValue as? Set<PersistentIdentifier> {
                hasIdentifierCollection = true
                if ids.contains(where: { $0.entityName == "Book" }) {
                    return true
                }
            }
        }
        return !hasIdentifierCollection
    }

    private func observeContextNotifications() {
        if let token = saveObserver {
            NotificationCenter.default.removeObserver(token)
            saveObserver = nil
        }
        guard let ctx = modelContext else { return }
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: ctx,
            queue: .main
        ) { [weak self] notification in
            guard Self.didSaveAffectBooks(notification) else { return }
            Task { @MainActor [weak self] in
                self?.scheduleRefresh(fromContextSave: true)
            }
        }
    }

    func scheduleRefresh(fromContextSave: Bool = false) {
        throttleTask?.cancel()
        throttleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshNow(fromContextSave: fromContextSave)
        }
    }

    func refreshNow(fromContextSave: Bool = false) {
        guard let ctx = modelContext else { return }
        let allBooksDesc = FetchDescriptor<Book>()
        let rawAllBooks = (try? ctx.fetch(allBooksDesc)) ?? []
        // 从全量内存列表直接派生历史排序，避免第二次 Book 全表 SQLite 查询
        let rawHistory = rawAllBooks
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }

        let rawShelf = rawAllBooks.filter { $0.inShelf }
        let nextAllShelfBooks = rawShelf.filter { !hiddenShelfBookIDs.contains($0.id) }
        let visibleHistory = rawHistory.filter { !hiddenHistoryBookIDs.contains($0.id) }
        let nextContinueBook = visibleHistory.first(where: { ($0.lastChapterID != nil) || $0.lastPositionMs > 0 }) ?? visibleHistory.first
        let continueID = nextContinueBook?.id
        let nextRecentBooks = Array(visibleHistory.filter { $0.id != continueID && !$0.inShelf }.prefix(8))
        let nextSortedShelfIDs = Self.sortBooks(nextAllShelfBooks, by: sortOrder).map(\.id)

        let signature = StructuralSignature(
            books: rawAllBooks
                .sorted { $0.id < $1.id }
                .map { b in
                    BookStructuralKey(
                        id: b.id,
                        inShelf: b.inShelf,
                        isPinned: b.isPinned,
                        hasUpdate: b.hasUpdate,
                        totalChapters: b.totalChapters,
                        latestChapterCount: b.latestChapterCount,
                        title: b.title,
                        author: b.author,
                        cover: b.cover,
                        addedAt: b.addedAt,
                        updateCheckedAt: b.updateCheckedAt,
                        lastChapterID: b.lastChapterID,
                        lastChapterIndex: b.lastChapterIndex,
                        hasProgress: (b.lastChapterID != nil || b.lastPositionMs > 0 || b.lastChapterIndex > 0)
                    )
                },
            continueBookID: continueID,
            recentBookIDs: nextRecentBooks.map(\.id),
            sortedShelfIDs: nextSortedShelfIDs,
            hiddenShelfBookIDs: hiddenShelfBookIDs,
            hiddenHistoryBookIDs: hiddenHistoryBookIDs
        )

        // P4：若本次保存仅微调播放位置/lastPlayedAt，且未改变书架成员、筛选归属或排序结果，跳过整表重建与视图刷新风暴
        if fromContextSave, hasLoadedOnce, lastStructuralSignature == signature {
            return
        }
        lastStructuralSignature = signature

        var byID: [String: Book] = [:]
        byID.reserveCapacity(rawAllBooks.count)
        for b in rawAllBooks {
            byID[b.id] = b
        }
        allKnownBooksByID = byID
        allShelfBooks = nextAllShelfBooks
        shelfBookIDs = Set(nextAllShelfBooks.map(\.id))
        hasLoadedOnce = true
        continueBook = nextContinueBook
        recentBooks = nextRecentBooks
        historyBooks = visibleHistory
        cachedHistorySections = Self.groupHistoryBooks(visibleHistory)

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

    /// 确保指定书籍已受 SwiftData 托管（用于 .downloaded 分栏中未入书架的脱管临时 Book 执行置顶/更新）
    func ensurePersistedBook(for bookID: String, fallbackContext: ModelContext? = nil) -> Book? {
        if let existing = book(for: bookID, fallbackContext: fallbackContext) {
            return existing
        }
        guard let ctx = fallbackContext ?? modelContext,
              let transient = shelfBooks.first(where: { $0.id == bookID }) else {
            return nil
        }
        let persisted = Book(
            id: transient.id,
            sourceID: transient.sourceID,
            bookURL: transient.bookURL,
            title: transient.title,
            author: transient.author,
            cover: transient.cover,
            intro: transient.intro,
            inShelf: false,
            addedAt: transient.addedAt,
            totalChapters: transient.totalChapters,
            speed: AppSettingsStore.shared.defaultSpeed
        )
        ctx.insert(persisted)
        try? ctx.save()
        allKnownBooksByID[bookID] = persisted
        return persisted
    }

    func isBookInShelf(_ bookID: String?, fallbackContext: ModelContext? = nil) -> Bool {
        guard let bookID, !bookID.isEmpty else { return false }
        if hiddenShelfBookIDs.contains(bookID) {
            return false
        }
        if hasLoadedOnce {
            return shelfBookIDs.contains(bookID)
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
        let wasHidden = hiddenShelfBookIDs.contains(targetID)
        if wasHidden {
            hiddenShelfBookIDs.remove(targetID)
            if hiddenShelfBookIDs.isEmpty {
                BannerCenter.shared.cancelPendingUndoWithoutCommit()
            }
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

    private func loadTransientChapterCountAsyncIfNeeded(for bookID: String, baselineCount: Int) {
        guard cachedChapterCountsByBookID[bookID] == nil,
              !pendingChapterCountBookIDs.contains(bookID) else {
            return
        }
        pendingChapterCountBookIDs.insert(bookID)
        Task { [weak self] in
            let count = await ChapterCacheStore.loadChaptersAsync(for: bookID)?.count ?? 0
            guard let self else { return }
            self.pendingChapterCountBookIDs.remove(bookID)
            self.cachedChapterCountsByBookID[bookID] = count
            if count > baselineCount {
                self.recomputeDerived()
            }
        }
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
        for bid in dlIDs where !shelfIDSet.contains(bid) && !hiddenShelfBookIDs.contains(bid) {
            if let known = allKnownBooksByID[bid] {
                downloadedCandidates.append(known)
            } else if let sum = dlSummaries[bid] {
                let parts = bid.components(separatedBy: "::")
                let bURL = parts.count > 1 ? parts.dropFirst().joined(separator: "::") : bid
                let cachedCount = cachedChapterCountsByBookID[bid] ?? 0
                if cachedChapterCountsByBookID[bid] == nil {
                    loadTransientChapterCountAsyncIfNeeded(for: bid, baselineCount: sum.totalCount)
                }
                let transient = Book(
                    id: bid,
                    sourceID: sum.sourceID,
                    bookURL: bURL,
                    title: sum.bookTitle,
                    inShelf: false,
                    totalChapters: max(sum.totalCount, cachedCount)
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
        let pendingIDs = allShelfBooks
            .filter { $0.totalChapters <= 0 && !backfillAttemptedBookIDs.contains($0.id) }
            .map(\.id)
        guard !pendingIDs.isEmpty else { return }

        backfillTask?.cancel()
        backfillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let targetIDs = self.allShelfBooks
                .filter { $0.totalChapters <= 0 && !self.backfillAttemptedBookIDs.contains($0.id) }
                .map(\.id)
            guard !targetIDs.isEmpty else { return }
            self.backfillAttemptedBookIDs.formUnion(targetIDs)

            // 磁盘章节缓存读取使用异步接口，避免主线程 IO 卡顿
            var counts: [String: Int] = [:]
            for bookID in targetIDs {
                if Task.isCancelled { break }
                if let cached = await ChapterCacheStore.loadChaptersAsync(for: bookID), !cached.isEmpty {
                    counts[bookID] = cached.count
                }
            }

            guard !Task.isCancelled, !counts.isEmpty else { return }
            var changed = false
            for book in self.allShelfBooks where book.totalChapters <= 0 {
                if let count = counts[book.id], count > 0 {
                    book.totalChapters = count
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
        hiddenShelfBookIDs.formUnion(ids)
        refreshNow()

        let titleDesc = books.count == 1 ? "已移出《\(books[0].title)》" : "已移出 \(books.count) 本书"
        BannerCenter.shared.showUndo(
            titleDesc,
            onUndo: { [weak self] in
                self?.hiddenShelfBookIDs.subtract(ids)
                self?.refreshNow()
            },
            onCommit: { [weak self] in
                guard let self, let ctx = self.modelContext else { return }
                for b in books where self.hiddenShelfBookIDs.contains(b.id) {
                    if b.lastPlayedAt != nil {
                        b.inShelf = false
                    } else {
                        ctx.delete(b)
                    }
                }
                self.hiddenShelfBookIDs.subtract(ids)
                try? ctx.save()
                self.refreshNow()
            }
        )
    }

    func deleteHistoryDeferred(_ book: Book) {
        let bid = book.id
        hiddenHistoryBookIDs.insert(bid)
        refreshNow()

        BannerCenter.shared.showUndo(
            "已删除《\(book.title)》播放记录",
            onUndo: { [weak self] in
                self?.hiddenHistoryBookIDs.remove(bid)
                self?.refreshNow()
            },
            onCommit: { [weak self] in
                guard let self, let ctx = self.modelContext else { return }
                guard self.hiddenHistoryBookIDs.contains(bid) else { return }
                if book.inShelf {
                    book.lastPlayedAt = nil
                    book.lastChapterID = nil
                    book.lastChapterTitle = nil
                    book.lastChapterIndex = 0
                    book.lastPositionMs = 0
                } else {
                    ctx.delete(book)
                }
                self.hiddenHistoryBookIDs.remove(bid)
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

    private static func groupHistoryBooks(
        _ list: [Book],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [(group: HistoryTimeGroup, books: [Book])] {
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

    func refreshHistoryCache(now: Date = .now, calendar: Calendar = .current) {
        if !hasLoadedOnce {
            refreshNow()
        } else {
            cachedHistorySections = Self.groupHistoryBooks(historyBooks, now: now, calendar: calendar)
        }
    }

    func allHistoryGrouped(now: Date = .now, calendar: Calendar = .current) -> [(group: HistoryTimeGroup, books: [Book])] {
        if hasLoadedOnce {
            return Self.groupHistoryBooks(historyBooks, now: now, calendar: calendar)
        }
        guard let ctx = modelContext else { return [] }
        let desc = FetchDescriptor<Book>(
            predicate: #Predicate<Book> { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\Book.lastPlayedAt, order: .reverse)]
        )
        let list = ((try? ctx.fetch(desc)) ?? []).filter { !hiddenHistoryBookIDs.contains($0.id) }
        return Self.groupHistoryBooks(list, now: now, calendar: calendar)
    }
}
