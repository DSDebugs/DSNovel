import DSCore
import Foundation

/// DiscoverViewModel 分页加载与去重追加逻辑（拆分保持单文件 ≤ 384 行）
extension DiscoverViewModel {
    func loadMore(container: AppContainer) async {
        guard !selectedSourceID.isEmpty else { return }
        let gen = generation
        isLoading = true
        loadMoreError = nil
        let nextPage = currentPage + 1
        let targetURL = nextPageURL ?? resolvedRequestURL(for: activeCategoryURL)
        do {
            let pageResult = try await container.pluginRuntime.discoverPage(
                sourceID: selectedSourceID,
                categoryURL: targetURL,
                page: nextPage
            )
            guard gen == generation else { return }
            let before = books.count
            appendUnique(pageResult.books)
            currentPage = nextPage
            nextPageURL = pageResult.nextURL
            if books.count > before {
                consecutiveDuplicatePages = 0
                hasMore = pageResult.hasMore
                isLoading = false
                storeFeedCache(key: feedCacheKey(sourceID: selectedSourceID, categoryURL: resolvedRequestURL(for: activeCategoryURL)))
            } else if pageResult.hasMore && !pageResult.books.isEmpty && consecutiveDuplicatePages < 2 {
                consecutiveDuplicatePages += 1
                hasMore = true
                await loadMore(container: container)
                return
            } else {
                hasMore = false
                isLoading = false
            }
        } catch {
            if Self.isCancellationError(error) {
                if gen == generation { isLoading = false }
                return
            }
            guard gen == generation else { return }
            isLoading = false
            loadMoreError = error.localizedDescription
        }
    }

    func appendUnique(_ incoming: [BookSummaryDTO]) {
        for item in incoming where seenBookIDs.insert(item.id).inserted {
            books.append(item)
        }
    }
}
