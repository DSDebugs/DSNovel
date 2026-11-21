import DSCore
import Foundation
import Observation

/// 搜索状态控制器（并发聚合多源、代际防乱序、缓存派生筛选、失败源独立记录与一键恢复重试，独立于 View 文件以遵守规则 #8）
@Observable
@MainActor
final class SearchViewModel {
    var query: String = ""
    var history: [String] = []
    var results: [BookSummaryDTO] = []
    var selectedSourceFilterID: String? = nil {
        didSet {
            if oldValue != selectedSourceFilterID {
                rebuildFilteredResults()
            }
        }
    }

    private(set) var availableResultSources: [(id: String, name: String)] = []
    private(set) var filteredResults: [BookSummaryDTO] = []

    var failedSourceNames: [String] = []
    var isSearching = false
    var completedSources = 0
    var totalSources = 0
    var lastSearchedTerm: String? = nil

    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var seenBookIDs: Set<String> = []

    func loadHistory(container: AppContainer) async {
        history = (try? await container.persistence.fetchSearchHistory(limit: 16)) ?? []
    }

    func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        results = []
        seenBookIDs.removeAll()
        failedSourceNames = []
        lastSearchedTerm = nil
        selectedSourceFilterID = nil
        rebuildDerivedCaches()
        isSearching = false
        completedSources = 0
        totalSources = 0
    }

    func executeSearch(keyword: String? = nil, container: AppContainer) {
        let term = (keyword ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        query = term
        searchTask?.cancel()
        searchGeneration &+= 1
        let gen = searchGeneration

        searchTask = Task { [weak self] in
            guard let self else { return }
            self.isSearching = true
            self.lastSearchedTerm = term
            self.results = []
            self.seenBookIDs.removeAll()
            self.selectedSourceFilterID = nil
            self.rebuildDerivedCaches()
            self.failedSourceNames = []
            self.completedSources = 0

            try? await container.persistence.recordSearchKeyword(term)
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            await self.loadHistory(container: container)
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            let allSources = (try? await container.persistence.fetchAllSources()) ?? []
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            let active = allSources.map(\.meta).filter { $0.isEnabled && $0.methods.contains("search") }
            self.totalSources = active.count

            await withTaskGroup(of: (sourceName: String, books: [BookSummaryDTO]?).self) { group in
                for src in active {
                    group.addTask {
                        guard !Task.isCancelled else { return (src.name, nil) }
                        let fetched = try? await container.pluginRuntime.search(sourceID: src.id, keyword: term, page: 1)
                        return (src.name, fetched)
                    }
                }
                for await item in group {
                    if Task.isCancelled || gen != self.searchGeneration {
                        group.cancelAll()
                        break
                    }
                    self.completedSources += 1
                    if let list = item.books {
                        let unique = list.filter { self.seenBookIDs.insert($0.id).inserted }
                        if !unique.isEmpty {
                            self.results.append(contentsOf: unique)
                            self.rebuildDerivedCaches()
                        }
                    } else {
                        self.failedSourceNames.append(item.sourceName)
                    }
                }
                group.cancelAll()
            }
            guard !Task.isCancelled, gen == self.searchGeneration else { return }
            self.isSearching = false
        }
    }

    func clearHistory(container: AppContainer) async {
        try? await container.persistence.clearSearchHistory()
        history = []
    }

    private func rebuildDerivedCaches() {
        var seen: Set<String> = []
        var sources: [(id: String, name: String)] = []
        for book in results where seen.insert(book.sourceID).inserted {
            sources.append((book.sourceID, book.sourceName.isEmpty ? book.sourceID : book.sourceName))
        }
        availableResultSources = sources
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
