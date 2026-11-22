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

/// 搜索状态控制器（并发聚合多源、耗时统计、代际防乱序、缓存派生筛选、热门书籍与单条历史删除，完整保留 v3.0 全部对外接口）
@Observable
@MainActor
final class SearchViewModel {
    static let allSourcesChipID = "__all_sources__"
    static let currentDiscoverChipID = "__current_discover__"

    var query: String = ""
    var history: [String] = []
    var results: [BookSummaryDTO] = [] {
        didSet { rebuildDerivedCaches() }
    }
    var selectedSourceFilterID: String? {
        didSet {
            if oldValue != selectedSourceFilterID {
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
    var completedSources = 0
    var totalSources = 0
    var elapsedSeconds: Double = 0
    var lastSearchedTerm: String?

    var searchableSources: [SourceMetaDTO] = [] {
        didSet { rebuildScopeChips() }
    }
    var selectedScopeID: String = SearchViewModel.allSourcesChipID
    var hotBooks: [BookSummaryDTO] = []
    var hotBooksSourceName: String = ""
    var isLoadingHotBooks = false
    var shelfBookIDs: Set<String> = []

    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var seenBookIDs: Set<String> = []
    private var searchStartedAt: Date?

    var activeScopeSourceCount: Int {
        resolveTargetSources(from: searchableSources, activeDiscoverSourceID: "").count
    }

    func loadHistory(container: AppContainer) async {
        history = (try? await container.persistence.fetchSearchHistory(limit: 16)) ?? []
    }

    func loadSearchableSources(container: AppContainer) async {
        let all = (try? await container.persistence.fetchAllSources()) ?? []
        searchableSources = all.map(\.meta).filter { $0.isEnabled && $0.methods.contains("search") }
    }

    func loadShelfBookIDs(container: AppContainer) async {
        let shelf = (try? await container.persistence.fetchShelfBooks()) ?? []
        shelfBookIDs = Set(shelf.map(\.id))
    }

    func loadHotBooksIfNeeded(container: AppContainer, forceReload: Bool = false) async {
        if !forceReload && !hotBooks.isEmpty { return }
        guard !isLoadingHotBooks else { return }
        isLoadingHotBooks = true
        defer { isLoadingHotBooks = false }

        let all = (try? await container.persistence.fetchAllSources()) ?? []
        let discoverable = all.map(\.meta).filter {
            $0.isEnabled && ($0.methods.contains("discover") || $0.methods.contains("categoryPage") || $0.methods.contains("categoryMenus"))
        }
        let target = discoverable.first(where: { $0.id == container.activeDiscoverSourceID }) ?? discoverable.first
        guard let source = target else { return }

        do {
            let categories = try await container.pluginRuntime.discoverCategories(sourceID: source.id)
            let page = try await container.pluginRuntime.discoverPage(
                sourceID: source.id,
                categoryURL: categories.first?.url ?? "",
                page: 1
            )
            var seen: Set<String> = []
            let deduped = page.books.filter { seen.insert($0.id).inserted }
            if !deduped.isEmpty {
                hotBooks = Array(deduped.prefix(10))
                hotBooksSourceName = source.name
            }
        } catch {
            // 热门书籍为辅助推荐区，静默回退至默认热门词
        }
    }

    func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        results = []
        seenBookIDs.removeAll()
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

    func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        if let start = searchStartedAt {
            elapsedSeconds = max(0.1, Date().timeIntervalSince(start))
        }
        isSearching = false
    }

    func executeSearch(keyword: String? = nil, container: AppContainer) {
        let term = (keyword ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        query = term
        searchTask?.cancel()
        searchGeneration &+= 1
        let gen = searchGeneration
        let startTime = Date()
        searchStartedAt = startTime

        searchTask = Task { [weak self] in
            guard let self else { return }
            self.isSearching = true
            self.lastSearchedTerm = term
            self.results = []
            self.seenBookIDs.removeAll()
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

            let allSources = (try? await container.persistence.fetchAllSources()) ?? []
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            let searchable = allSources.map(\.meta).filter { $0.isEnabled && $0.methods.contains("search") }
            self.searchableSources = searchable
            let active = self.resolveTargetSources(
                from: searchable,
                activeDiscoverSourceID: container.activeDiscoverSourceID
            )
            self.totalSources = active.count

            await withTaskGroup(of: (sourceID: String, sourceName: String, books: [BookSummaryDTO]?, errorReason: String?).self) { group in
                for src in active {
                    group.addTask {
                        guard !Task.isCancelled else { return (src.id, src.name, nil, "已取消") }
                        do {
                            let fetched = try await container.pluginRuntime.search(sourceID: src.id, keyword: term, page: 1)
                            return (src.id, src.name, fetched, nil)
                        } catch {
                            return (src.id, src.name, nil, error.localizedDescription)
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
            } else {
                shelfBookIDs.remove(book.id)
            }
            container.libraryRevision &+= 1
            return nextState
        } catch {
            return currentlyInShelf
        }
    }

    private func resolveTargetSources(from sources: [SourceMetaDTO], activeDiscoverSourceID: String) -> [SourceMetaDTO] {
        let unskipped = sources.filter { !skippedSourceIDs.contains($0.id) }
        if selectedScopeID == Self.allSourcesChipID {
            return unskipped
        }
        if selectedScopeID == Self.currentDiscoverChipID {
            if !activeDiscoverSourceID.isEmpty,
               let match = unskipped.first(where: { $0.id == activeDiscoverSourceID }) {
                return [match]
            }
            return unskipped
        }
        let matched = unskipped.filter { $0.id == selectedScopeID || $0.groupName == selectedScopeID }
        return matched.isEmpty ? unskipped : matched
    }

    private func rebuildScopeChips() {
        var chips: [DSChipItem<String>] = [
            DSChipItem(id: Self.allSourcesChipID, title: "全部书源"),
            DSChipItem(id: Self.currentDiscoverChipID, title: "当前发现源")
        ]
        var seenGroups: Set<String> = []
        for src in searchableSources {
            let group = src.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !group.isEmpty && seenGroups.insert(group).inserted {
                chips.append(DSChipItem(id: group, title: group))
            }
        }
        scopeChips = chips
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
