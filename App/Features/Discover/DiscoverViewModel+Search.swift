import DSCore
import Foundation

/// 发现页源内搜索扩展（支持真分页续拉、去重与尾部重试，拆分自 DiscoverViewModel 保持单文件 ≤ 385 行）
extension DiscoverViewModel {
    func submitSourceSearch(container: AppContainer) {
        let term = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !selectedSourceID.isEmpty else {
            clearSourceSearch()
            return
        }
        searchKeyword = term
        isSearchActive = true
        sourceSearchTask?.cancel()
        sourceSearchLoadMoreTask?.cancel()
        sourceSearchLoadMoreTask = nil
        sourceSearchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSourceSearch(term: term, container: container)
        }
    }

    func refreshSourceSearch(container: AppContainer) async {
        let term = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !selectedSourceID.isEmpty else { return }
        sourceSearchTask?.cancel()
        sourceSearchLoadMoreTask?.cancel()
        sourceSearchLoadMoreTask = nil
        await performSourceSearch(term: term, container: container)
    }

    func clearSourceSearch() {
        sourceSearchTask?.cancel()
        sourceSearchTask = nil
        sourceSearchLoadMoreTask?.cancel()
        sourceSearchLoadMoreTask = nil
        sourceSearchGeneration &+= 1
        searchKeyword = ""
        isSearchActive = false
        isSearchingInSource = false
        isLoadingMoreSearch = false
        searchResults = []
        seenSearchBookIDs.removeAll()
        sourceSearchPage = 1
        searchHasMore = false
        searchError = nil
        searchLoadMoreError = nil
    }

    func loadNextSourceSearchPageIfNeeded(currentItemID: String, container: AppContainer) {
        guard isSearchActive,
              !isSearchingInSource,
              !isLoadingMoreSearch,
              sourceSearchLoadMoreTask == nil,
              searchHasMore,
              searchLoadMoreError == nil,
              !searchResults.isEmpty else { return }
        let tailIndex = max(0, searchResults.count - 6)
        if let idx = searchResults.firstIndex(where: { $0.id == currentItemID }), idx >= tailIndex {
            startLoadMoreSourceSearch(container: container)
        }
    }

    func retryLoadMoreSourceSearch(container: AppContainer) {
        guard isSearchActive, !isSearchingInSource, !isLoadingMoreSearch, sourceSearchLoadMoreTask == nil, searchHasMore else { return }
        startLoadMoreSourceSearch(container: container)
    }

    private func startLoadMoreSourceSearch(container: AppContainer) {
        sourceSearchLoadMoreTask?.cancel()
        sourceSearchLoadMoreTask = Task { [weak self] in
            guard let self else { return }
            await self.loadMoreSourceSearch(container: container)
            self.sourceSearchLoadMoreTask = nil
        }
    }

    private func performSourceSearch(term: String, container: AppContainer) async {
        await container.ensureSourcesRegistered()
        sourceSearchGeneration &+= 1
        let gen = sourceSearchGeneration
        isSearchingInSource = true
        isLoadingMoreSearch = false
        searchError = nil
        searchLoadMoreError = nil
        sourceSearchPage = 1
        seenSearchBookIDs.removeAll()
        searchResults = []
        searchHasMore = false
        do {
            let pageResult = try await container.pluginRuntime.searchPage(
                sourceID: selectedSourceID,
                keyword: term,
                page: 1
            )
            guard !Task.isCancelled, gen == sourceSearchGeneration else { return }
            var unique: [BookSummaryDTO] = []
            for item in pageResult.books where seenSearchBookIDs.insert(item.id).inserted {
                unique.append(item)
            }
            searchResults = unique
            sourceSearchPage = 1
            searchHasMore = pageResult.hasMore && !unique.isEmpty
            isSearchingInSource = false
        } catch {
            if Self.isCancellationError(error) {
                if gen == sourceSearchGeneration { isSearchingInSource = false }
                return
            }
            guard gen == sourceSearchGeneration else { return }
            isSearchingInSource = false
            searchError = error.localizedDescription
        }
    }

    private func loadMoreSourceSearch(container: AppContainer) async {
        let term = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !selectedSourceID.isEmpty else { return }
        let gen = sourceSearchGeneration
        let nextPage = sourceSearchPage + 1
        isLoadingMoreSearch = true
        searchLoadMoreError = nil
        do {
            let pageResult = try await container.pluginRuntime.searchPage(
                sourceID: selectedSourceID,
                keyword: term,
                page: nextPage
            )
            guard !Task.isCancelled, gen == sourceSearchGeneration else { return }
            let before = searchResults.count
            for item in pageResult.books where seenSearchBookIDs.insert(item.id).inserted {
                searchResults.append(item)
            }
            sourceSearchPage = nextPage
            searchHasMore = pageResult.hasMore && searchResults.count > before
            isLoadingMoreSearch = false
        } catch {
            if Self.isCancellationError(error) {
                if gen == sourceSearchGeneration { isLoadingMoreSearch = false }
                return
            }
            guard gen == sourceSearchGeneration else { return }
            isLoadingMoreSearch = false
            searchLoadMoreError = error.localizedDescription
        }
    }
}
