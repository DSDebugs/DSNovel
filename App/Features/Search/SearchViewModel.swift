import DSCore
import DSDesignSystem
import Foundation
import Observation

/// 失败书源条目（供 FailedSourcesSheet 展示详细原因与跳过操作）
struct SearchFailedSourceItem: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let sourceName: String
    let reason: String
}

/// 实时联想关键词条目
struct SearchSuggestionItem: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let isFromHistory: Bool
}

/// 联想结果 5 分钟前缀缓存条目
struct SearchSuggestCacheEntry {
    let books: [BookSummaryDTO]
    let keywords: [SearchSuggestionItem]
    let timestamp: Date
}

/// 搜索状态控制器（并发聚合多源、按当前源与书源管理排序的热榜、双层实时联想与多源游标翻页）
@Observable
@MainActor
final class SearchViewModel {
    static let allSourcesChipID = "__all_sources__"
    static let currentDiscoverChipID = "__current_discover__"
    static let hotBooksCacheTTL: TimeInterval = 30 * 60
    static let suggestCacheTTL: TimeInterval = 5 * 60
    static let defaultHotBooksLimit: Int = 30

    var query: String = ""
    var history: [String] = []
    var results: [BookSummaryDTO] = [] {
        didSet { rebuildDerivedCaches() }
    }
    var selectedSourceFilterID: String? {
        didSet {
            if oldValue != selectedSourceFilterID {
                loadMoreError = nil
                rebuildFilteredResults()
            }
        }
    }

    private(set) var availableResultSources: [(id: String, name: String)] = []
    private(set) var filteredResults: [BookSummaryDTO] = []
    private(set) var resultFilterChips: [DSChipItem<String>] = []
    private(set) var scopeChips: [DSChipItem<String>] = []

    var failedSourceNames: [String] = []
    var failedSourceItems: [SearchFailedSourceItem] = []
    var skippedSourceIDs: Set<String> = []
    var isSearching = false
    var isLoadingMore = false
    var loadMoreError: String?
    var completedSources = 0
    var totalSources = 0
    var elapsedSeconds: Double = 0
    var lastSearchedTerm: String?

    var searchableSources: [SourceMetaDTO] = [] {
        didSet { rebuildScopeChips() }
    }
    var customSourceGroups: [String] = [] {
        didSet {
            if oldValue != customSourceGroups {
                rebuildScopeChips()
            }
        }
    }
    var activeDiscoverSourceID: String = "" {
        didSet {
            if oldValue != activeDiscoverSourceID {
                recomputeHotBooksFromCache()
            }
        }
    }
    var activeDiscoverSourceName: String = "" {
        didSet {
            if oldValue != activeDiscoverSourceName {
                rebuildScopeChips()
            }
        }
    }
    var selectedScopeID: String = SearchViewModel.allSourcesChipID
    var hotBooks: [BookSummaryDTO] = []
    var perSourceHotBooksCache: [String: [BookSummaryDTO]] = [:]
    var discoverableSourcesCache: [SourceMetaDTO] = []
    var isLoadingHotBooks = false
    var hotBooksLoadedAt: Date?
    var hotBooksGeneration: UInt64 = 0

    var suggestedBooks: [BookSummaryDTO] = []
    var suggestedKeywords: [SearchSuggestionItem] = []
    var isLoadingSuggestions = false
    var isShowingSuggestions = false
    var suggestTask: Task<Void, Never>?
    var suggestGeneration: UInt64 = 0
    var suggestCache: [String: SearchSuggestCacheEntry] = [:]

    var shelfBookIDs: Set<String> = []
    var shelfBooksCache: [BookSummaryDTO] = []

    private var searchTask: Task<Void, Never>?
    var loadMoreTask: Task<Void, Never>?
    var searchGeneration: UInt64 = 0
    var seenBookIDs: Set<String> = []
    var sourcePageCursors: [String: SearchSourcePageCursor] = [:]
    private var searchStartedAt: Date?

    func loadHistory(container: AppContainer) async {
        history = (try? await container.persistence.fetchSearchHistory(limit: 16)) ?? []
    }

    func loadSearchableSources(container: AppContainer) async {
        await container.ensureSourcesRegistered()
        let all = (try? await container.persistence.fetchAllSources()) ?? []
        customSourceGroups = container.settings.customSourceGroups
        let enabledSearchable = all.map(\.meta).filter { $0.isEnabled && $0.methods.contains("search") }
        searchableSources = Self.sortedBySourceManagementOrder(enabledSearchable)
    }

    func loadShelfBookIDs(container: AppContainer) async {
        let shelf = (try? await container.persistence.fetchShelfBooks()) ?? []
        shelfBooksCache = shelf
        shelfBookIDs = Set(shelf.map(\.id))
    }

    func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        cancelLoadMoreTask()
        clearSuggestions()
        searchGeneration &+= 1
        results = []
        seenBookIDs.removeAll()
        sourcePageCursors.removeAll()
        loadMoreError = nil
        failedSourceNames = []
        failedSourceItems = []
        lastSearchedTerm = nil
        selectedSourceFilterID = nil
        rebuildDerivedCaches()
        isSearching = false
        completedSources = 0
        totalSources = 0
        elapsedSeconds = 0
        searchStartedAt = nil
    }

    func clearToPrepareState() {
        query = ""
        resetSearch()
    }

    func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        cancelLoadMoreTask()
        searchGeneration &+= 1
        if let start = searchStartedAt {
            elapsedSeconds = max(0.1, Date().timeIntervalSince(start))
        }
        isSearching = false
    }

    func executeSearch(keyword: String? = nil, container: AppContainer) {
        let term = (keyword ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        clearSuggestions()
        searchTask?.cancel()
        cancelLoadMoreTask()
        searchGeneration &+= 1
        let gen = searchGeneration
        let startTime = Date()
        searchStartedAt = startTime
        isSearching = true
        lastSearchedTerm = term
        loadMoreError = nil
        query = term

        searchTask = Task { [weak self] in
            guard let self else { return }
            self.results = []
            self.seenBookIDs.removeAll()
            self.sourcePageCursors.removeAll()
            self.selectedSourceFilterID = nil
            self.rebuildDerivedCaches()
            self.failedSourceNames = []
            self.failedSourceItems = []
            self.completedSources = 0
            self.elapsedSeconds = 0

            try? await container.persistence.recordSearchKeyword(term)
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            await self.loadHistory(container: container)
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            await container.ensureSourcesRegistered()
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            let allSources = (try? await container.persistence.fetchAllSources()) ?? []
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            self.customSourceGroups = container.settings.customSourceGroups
            let searchable = Self.sortedBySourceManagementOrder(
                allSources.map(\.meta).filter { $0.isEnabled && $0.methods.contains("search") }
            )
            self.searchableSources = searchable
            let active = self.resolveTargetSources(
                from: searchable,
                activeDiscoverSourceID: container.activeDiscoverSourceID
            )
            self.totalSources = active.count

            await withTaskGroup(of: (sourceID: String, sourceName: String, books: [BookSummaryDTO]?, hasMore: Bool, errorReason: String?).self) { group in
                for src in active {
                    group.addTask {
                        guard !Task.isCancelled else { return (src.id, src.name, nil, false, "已取消") }
                        do {
                            let pageResult = try await container.pluginRuntime.searchPage(sourceID: src.id, keyword: term, page: 1)
                            return (src.id, src.name, pageResult.books, pageResult.hasMore, nil)
                        } catch {
                            return (src.id, src.name, nil, false, error.localizedDescription)
                        }
                    }
                }
                for await item in group {
                    if Task.isCancelled || gen != self.searchGeneration {
                        group.cancelAll()
                        break
                    }
                    self.completedSources += 1
                    self.elapsedSeconds = max(0.1, Date().timeIntervalSince(startTime))
                    if let list = item.books {
                        let unique = list.filter { self.seenBookIDs.insert($0.id).inserted }
                        self.sourcePageCursors[item.sourceID] = SearchSourcePageCursor(
                            sourceID: item.sourceID,
                            sourceName: item.sourceName,
                            nextPage: 2,
                            hasMore: item.hasMore && !unique.isEmpty
                        )
                        if !unique.isEmpty {
                            self.results.append(contentsOf: unique)
                            self.rebuildDerivedCaches()
                        }
                    } else {
                        self.failedSourceNames.append(item.sourceName)
                        let reason = (item.errorReason?.isEmpty == false) ? (item.errorReason ?? "请求超时或解析异常") : "请求超时或解析异常"
                        self.failedSourceItems.append(
                            SearchFailedSourceItem(
                                id: item.sourceID,
                                sourceID: item.sourceID,
                                sourceName: item.sourceName,
                                reason: reason
                            )
                        )
                    }
                }
                group.cancelAll()
            }
            guard !Task.isCancelled, gen == self.searchGeneration else { return }
            self.elapsedSeconds = max(0.1, Date().timeIntervalSince(startTime))
            self.isSearching = false
        }
    }

    func deleteHistoryKeyword(_ keyword: String, container: AppContainer) async {
        let remaining = history.filter { $0 != keyword }
        history = remaining
        try? await container.persistence.clearSearchHistory()
        for item in remaining.reversed() {
            try? await container.persistence.recordSearchKeyword(item)
        }
    }

    func clearHistory(container: AppContainer) async {
        try? await container.persistence.clearSearchHistory()
        history = []
    }

    func skipFailedSource(_ sourceID: String) {
        skippedSourceIDs.insert(sourceID)
        failedSourceItems.removeAll { $0.sourceID == sourceID }
        failedSourceNames = failedSourceItems.map(\.sourceName)
    }

    func restoreSkippedSources() {
        skippedSourceIDs.removeAll()
    }

    func toggleShelf(for book: BookSummaryDTO, container: AppContainer) async -> Bool {
        let currentlyInShelf = shelfBookIDs.contains(book.id)
        let nextState = !currentlyInShelf
        do {
            try await container.persistence.upsertBook(book, addToShelf: nextState)
            if nextState {
                shelfBookIDs.insert(book.id)
                if !shelfBooksCache.contains(where: { $0.id == book.id }) {
                    shelfBooksCache.insert(book, at: 0)
                }
            } else {
                shelfBookIDs.remove(book.id)
                shelfBooksCache.removeAll { $0.id == book.id }
            }
            container.libraryRevision &+= 1
            return nextState
        } catch {
            return currentlyInShelf
        }
    }

    private func rebuildScopeChips() {
        var chips: [DSChipItem<String>] = [
            DSChipItem(id: Self.allSourcesChipID, title: "全部书源"),
            DSChipItem(
                id: Self.currentDiscoverChipID,
                title: activeDiscoverSourceName.isEmpty ? "当前书源" : "当前书源：\(activeDiscoverSourceName)"
            )
        ]
        let activeSourceGroups = Set(
            searchableSources
                .map { $0.groupName.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "默认分组" }
        )
        var seenGroups: Set<String> = []
        for rawGroup in customSourceGroups {
            let group = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            if !group.isEmpty, group != "默认分组", activeSourceGroups.contains(group), seenGroups.insert(group).inserted {
                chips.append(DSChipItem(id: group, title: group))
            }
        }
        scopeChips = chips
        if !chips.contains(where: { $0.id == selectedScopeID }) {
            selectedScopeID = Self.allSourcesChipID
        }
    }

    private func rebuildDerivedCaches() {
        var seen: Set<String> = []
        var sources: [(id: String, name: String)] = []
        var counts: [String: Int] = [:]
        for book in results {
            counts[book.sourceID, default: 0] += 1
            if seen.insert(book.sourceID).inserted {
                sources.append((book.sourceID, book.sourceName.isEmpty ? book.sourceID : book.sourceName))
            }
        }
        availableResultSources = sources
        var chips: [DSChipItem<String>] = [
            DSChipItem(id: Self.allSourcesChipID, title: "全部", count: results.count)
        ]
        for item in sources {
            chips.append(DSChipItem(id: item.id, title: item.name, count: counts[item.id]))
        }
        resultFilterChips = chips
        rebuildFilteredResults()
    }

    private func rebuildFilteredResults() {
        guard let filterID = selectedSourceFilterID else {
            filteredResults = results
            return
        }
        filteredResults = results.filter { $0.sourceID == filterID }
    }
}
