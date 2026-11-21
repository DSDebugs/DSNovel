import DSCore
import Foundation
import Observation

/// 发现页状态控制器（去重分页、内部 Task 托管取消、源切换回退与代际防抖，独立于 View 文件以遵守规则 #8）
@Observable
@MainActor
final class DiscoverViewModel {
    var sources: [SourceMetaDTO] = []
    var selectedSourceID: String = ""
    var categories: [DiscoverCategoryDTO] = []
    var selectedCategoryID: String = ""
    var books: [BookSummaryDTO] = []
    var isLoading = false
    var hasMore = true
    var errorMessage: String?
    var loadMoreError: String?

    private var currentPage = 1
    private var nextPageURL: String? = nil
    private var seenBookIDs: Set<String> = []
    private var generation: UInt64 = 0
    private var loadMoreTask: Task<Void, Never>?

    func loadSources(container: AppContainer) async {
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let enabled = Self.filterDiscoverSources(all.map(\.meta))
        sources = enabled
        if selectedSourceID.isEmpty || !enabled.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = enabled.first?.id ?? ""
        }
        container.activeDiscoverSourceID = selectedSourceID
        guard !selectedSourceID.isEmpty else {
            cancelLoadMoreTask()
            books = []
            categories = []
            selectedCategoryID = ""
            seenBookIDs.removeAll()
            currentPage = 1
            nextPageURL = nil
            hasMore = false
            return
        }
        await loadCategoriesAndFirstPage(container: container)
    }

    /// P1-23：监听书源变更时增量同步书源列表，仅在当前选中源失效或原为空时重载内容
    func syncSourcesIncremental(container: AppContainer) async {
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let enabled = Self.filterDiscoverSources(all.map(\.meta))
        sources = enabled
        if !selectedSourceID.isEmpty && enabled.contains(where: { $0.id == selectedSourceID }) {
            container.activeDiscoverSourceID = selectedSourceID
            return
        }
        selectedSourceID = enabled.first?.id ?? ""
        container.activeDiscoverSourceID = selectedSourceID
        guard !selectedSourceID.isEmpty else {
            cancelLoadMoreTask()
            books = []
            categories = []
            selectedCategoryID = ""
            seenBookIDs.removeAll()
            currentPage = 1
            nextPageURL = nil
            hasMore = false
            return
        }
        await loadCategoriesAndFirstPage(container: container)
    }

    func selectSource(_ id: String, container: AppContainer) async {
        cancelLoadMoreTask()
        selectedSourceID = id
        container.activeDiscoverSourceID = id
        await loadCategoriesAndFirstPage(container: container)
    }

    /// 下拉原地刷新当前选中书源与分类（成功后再替换列表，失败保留旧列表并提示错误）
    func refreshCurrentCategory(container: AppContainer) async {
        cancelLoadMoreTask()
        guard !selectedSourceID.isEmpty else {
            await loadSources(container: container)
            return
        }
        let activeURL = categories.first(where: { $0.id == selectedCategoryID })?.url ?? ""
        await loadFirstPage(categoryURL: activeURL, container: container, preserveExistingOnFailure: true)
    }

    func selectCategory(_ cat: DiscoverCategoryDTO, container: AppContainer) async {
        cancelLoadMoreTask()
        selectedCategoryID = cat.id
        await loadFirstPage(categoryURL: cat.url, container: container)
    }

    func loadNextPageIfNeeded(currentItemID: String, container: AppContainer) {
        guard !isLoading, loadMoreTask == nil, hasMore, loadMoreError == nil, !books.isEmpty else { return }
        let tailIndex = max(0, books.count - 6)
        if let idx = books.firstIndex(where: { $0.id == currentItemID }), idx >= tailIndex {
            startLoadMoreTask(container: container)
        }
    }

    func retryLoadMore(container: AppContainer) {
        guard !isLoading, loadMoreTask == nil, hasMore else { return }
        startLoadMoreTask(container: container)
    }

    private func cancelLoadMoreTask() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
    }

    private func startLoadMoreTask(container: AppContainer) {
        cancelLoadMoreTask()
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            await self.loadMore(container: container)
            self.loadMoreTask = nil
        }
    }

    private func loadCategoriesAndFirstPage(container: AppContainer) async {
        cancelLoadMoreTask()
        generation &+= 1
        let gen = generation
        categories = []
        selectedCategoryID = ""
        books = []
        seenBookIDs.removeAll()
        currentPage = 1
        nextPageURL = nil
        hasMore = true
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        do {
            let cats = try await container.pluginRuntime.discoverCategories(sourceID: selectedSourceID)
            guard gen == generation else { return }
            categories = cats
            selectedCategoryID = cats.first?.id ?? ""
            await loadFirstPage(categoryURL: cats.first?.url ?? "", container: container)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if gen == generation { isLoading = false }
                return
            }
            guard gen == generation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadFirstPage(
        categoryURL: String,
        container: AppContainer,
        preserveExistingOnFailure: Bool = false
    ) async {
        cancelLoadMoreTask()
        generation &+= 1
        let gen = generation
        isLoading = true
        errorMessage = nil
        loadMoreError = nil

        if !preserveExistingOnFailure {
            currentPage = 1
            nextPageURL = nil
            seenBookIDs.removeAll()
            books = []
            hasMore = true
        }

        do {
            let pageResult = try await container.pluginRuntime.discoverPage(
                sourceID: selectedSourceID,
                categoryURL: categoryURL,
                page: 1
            )
            guard gen == generation else { return }
            seenBookIDs.removeAll()
            books = []
            currentPage = 1
            appendUnique(pageResult.books)
            nextPageURL = pageResult.nextURL
            hasMore = pageResult.hasMore
            isLoading = false
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if gen == generation { isLoading = false }
                return
            }
            guard gen == generation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore(container: AppContainer) async {
        guard !selectedSourceID.isEmpty else { return }
        let gen = generation
        isLoading = true
        loadMoreError = nil
        let nextPage = currentPage + 1
        let activeCategoryURL = categories.first(where: { $0.id == selectedCategoryID })?.url
        let targetURL = nextPageURL ?? activeCategoryURL ?? ""
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
            hasMore = pageResult.hasMore && books.count > before
            isLoading = false
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if gen == generation { isLoading = false }
                return
            }
            guard gen == generation else { return }
            isLoading = false
            loadMoreError = error.localizedDescription
        }
    }

    private func appendUnique(_ incoming: [BookSummaryDTO]) {
        for item in incoming {
            if seenBookIDs.insert(item.id).inserted {
                books.append(item)
            }
        }
    }

    private static func filterDiscoverSources(_ all: [SourceMetaDTO]) -> [SourceMetaDTO] {
        all.filter { $0.isEnabled && ($0.methods.contains("discover") || $0.methods.contains("categoryPage") || $0.methods.contains("categoryMenus")) }
    }
}
