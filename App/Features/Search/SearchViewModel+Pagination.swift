import DSCore
import Foundation

/// 单书源搜索分页游标（支持聚合「全部」与单源筛选两种模式的独立续页）
struct SearchSourcePageCursor: Sendable {
    let sourceID: String
    let sourceName: String
    var nextPage: Int
    var hasMore: Bool
}

/// 搜索页多源聚合真分页扩展（拆分自 SearchViewModel 保持单文件 ≤ 385 行）
extension SearchViewModel {
    var canLoadMoreForCurrentFilter: Bool {
        if let filterID = selectedSourceFilterID {
            return sourcePageCursors[filterID]?.hasMore == true
        }
        return sourcePageCursors.values.contains(where: \.hasMore)
    }

    func cancelLoadMoreTask() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
    }

    func loadNextPageIfNeeded(currentItemID: String, container: AppContainer) {
        guard !isSearching,
              !isLoadingMore,
              loadMoreTask == nil,
              loadMoreError == nil,
              canLoadMoreForCurrentFilter,
              !filteredResults.isEmpty else { return }
        let tailIndex = max(0, filteredResults.count - 6)
        if let idx = filteredResults.firstIndex(where: { $0.id == currentItemID }), idx >= tailIndex {
            startLoadMoreTask(container: container)
        }
    }

    func retryLoadMore(container: AppContainer) {
        guard !isSearching, !isLoadingMore, loadMoreTask == nil, canLoadMoreForCurrentFilter else { return }
        startLoadMoreTask(container: container)
    }

    private func startLoadMoreTask(container: AppContainer) {
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoadMore(container: container)
            self.loadMoreTask = nil
        }
    }

    private func targetCursorsForLoadMore() -> [SearchSourcePageCursor] {
        if let filterID = selectedSourceFilterID {
            if let cursor = sourcePageCursors[filterID], cursor.hasMore {
                return [cursor]
            }
            return []
        }
        return sourcePageCursors.values
            .filter(\.hasMore)
            .sorted { $0.sourceName < $1.sourceName }
    }

    private func performLoadMore(container: AppContainer) async {
        guard let term = lastSearchedTerm, !term.isEmpty else { return }
        let targets = targetCursorsForLoadMore()
        guard !targets.isEmpty else { return }

        let gen = searchGeneration
        isLoadingMore = true
        loadMoreError = nil

        var succeededCount = 0
        var lastErrText: String?

        await withTaskGroup(
            of: (sourceID: String, requestedPage: Int, books: [BookSummaryDTO]?, hasMore: Bool, errorReason: String?).self
        ) { group in
            for cursor in targets {
                group.addTask {
                    guard !Task.isCancelled else {
                        return (cursor.sourceID, cursor.nextPage, nil, cursor.hasMore, nil)
                    }
                    do {
                        let pageResult = try await container.pluginRuntime.searchPage(
                            sourceID: cursor.sourceID,
                            keyword: term,
                            page: cursor.nextPage
                        )
                        return (cursor.sourceID, cursor.nextPage, pageResult.books, pageResult.hasMore, nil)
                    } catch {
                        return (cursor.sourceID, cursor.nextPage, nil, cursor.hasMore, error.localizedDescription)
                    }
                }
            }

            for await item in group {
                if Task.isCancelled || gen != self.searchGeneration {
                    group.cancelAll()
                    break
                }
                if let list = item.books {
                    succeededCount += 1
                    let unique = list.filter { self.seenBookIDs.insert($0.id).inserted }
                    if !unique.isEmpty {
                        self.results.append(contentsOf: unique)
                    }
                    if var cursor = self.sourcePageCursors[item.sourceID] {
                        cursor.nextPage = item.requestedPage + 1
                        cursor.hasMore = item.hasMore && !unique.isEmpty
                        self.sourcePageCursors[item.sourceID] = cursor
                    }
                } else if let reason = item.errorReason, !reason.isEmpty {
                    lastErrText = reason
                }
            }
            group.cancelAll()
        }

        guard !Task.isCancelled, gen == searchGeneration else { return }
        isLoadingMore = false
        if succeededCount == 0, let err = lastErrText {
            loadMoreError = err
        }
    }
}
