import DSCore
import DSDesignSystem
import Foundation
import Observation

/// 首页发现状态控制器（去重分页、书源记忆、书源分组缓存与代际防抖）
@Observable
@MainActor
final class DiscoverViewModel {
    var customSourceGroups: [String] = [] {
        didSet {
            if oldValue != customSourceGroups {
                rebuildSourceSections()
            }
        }
    }
    var sources: [SourceMetaDTO] = [] {
        didSet { rebuildSourceSections() }
    }
    var selectedSourceID: String = ""
    var categories: [DiscoverCategoryDTO] = [] {
        didSet { rebuildCategoryChips() }
    }
    var selectedCategoryID: String = ""
    var books: [BookSummaryDTO] = []
    var isLoading = false
    var hasMore = true
    var errorMessage: String?
    var loadMoreError: String?

    var shelfBookIDs: Set<String> = []

    var sourceSections: [DiscoverSourceSection] = []
    var categoryChips: [DSChipItem<String>] = []
    var categorySections: [DiscoverCategorySection] = []
    var sectionChips: [DSChipItem<Int>] = []
    var tabChips: [DSChipItem<Int>] = []
    var subTabChips: [DSChipItem<Int>] = []
    var selectedSectionIndex: Int = 0
    var selectedTabIndex: Int = 0
    var selectedSubTabIndex: Int = 0
    var sortOption: DiscoverSortOption = .hot
    var currentSectionTitle: String {
        categorySections.indices.contains(selectedSectionIndex) ? categorySections[selectedSectionIndex].title : ""
    }

    var currentPage = 1
    var nextPageURL: String?
    var seenBookIDs: Set<String> = []
    var consecutiveDuplicatePages = 0
    var rawCategories: [DiscoverCategoryDTO] = []
    private var generation: UInt64 = 0
    private var loadMoreTask: Task<Void, Never>?
    var activeFeedTask: Task<Void, Never>?
    var categoryProbeTask: Task<Void, Never>?
    var coverPrefetchTask: Task<Void, Never>?
    var categoriesCache: [String: DiscoverCategoryCacheEntry] = [:]
    var feedCache: [String: DiscoverFeedCacheEntry] = [:]
    var feedCacheOrder: [String] = []
    var emptyCategoriesBySource: [String: [String: TimeInterval]] = [:]
    var prefetchedCoverURLs: Set<String> = []

    init() {
        loadPersistedEmptyCategories()
    }

    /// 托管单条前台加载任务：切换分类或书源时立刻取消前序在飞请求与后台预探测，杜绝并发抢槽与限流假空态
    func triggerForegroundTask(_ work: @escaping @MainActor () async -> Void) {
        activeFeedTask?.cancel()
        cancelBackgroundPreloads()
        activeFeedTask = Task { [weak self] in
            await work()
            self?.activeFeedTask = nil
        }
    }

    var currentSourceName: String {
        sources.first(where: { $0.id == selectedSourceID })?.name ?? "发现"
    }

    func loadSources(container: AppContainer) async {
        await container.ensureSourcesRegistered()
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let enabled = Self.filterDiscoverSources(all.map(\.meta))
        customSourceGroups = container.settings.customSourceGroups
        sources = enabled
        let prevSourceID = selectedSourceID
        if selectedSourceID.isEmpty || !enabled.contains(where: { $0.id == selectedSourceID }) {
            let savedID = container.settings.lastDiscoverSourceID
            if !savedID.isEmpty && enabled.contains(where: { $0.id == savedID }) {
                selectedSourceID = savedID
            } else {
                selectedSourceID = enabled.first?.id ?? ""
            }
        }
        container.activeDiscoverSourceID = selectedSourceID
        if !selectedSourceID.isEmpty && container.settings.lastDiscoverSourceID != selectedSourceID {
            container.settings.lastDiscoverSourceID = selectedSourceID
        }
        guard !selectedSourceID.isEmpty else {
            resetDiscoverFeedState()
            return
        }
        if prevSourceID == selectedSourceID && !books.isEmpty && errorMessage == nil {
            return
        }
        await loadCategoriesAndFirstPage(container: container)
    }

    /// 监听书源变更时增量同步书源列表，仅在当前选中源失效、原为空或处于失败空态时重载内容
    func syncSourcesIncremental(container: AppContainer) async {
        invalidateDiscoverCaches()
        await container.ensureSourcesRegistered()
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let enabled = Self.filterDiscoverSources(all.map(\.meta))
        customSourceGroups = container.settings.customSourceGroups
        sources = enabled
        if !selectedSourceID.isEmpty && enabled.contains(where: { $0.id == selectedSourceID }) {
            container.activeDiscoverSourceID = selectedSourceID
            if books.isEmpty && !isLoading {
                await loadCategoriesAndFirstPage(container: container)
            }
            return
        }
        let savedID = container.settings.lastDiscoverSourceID
        if !savedID.isEmpty && enabled.contains(where: { $0.id == savedID }) {
            selectedSourceID = savedID
        } else {
            selectedSourceID = enabled.first?.id ?? ""
        }
        container.activeDiscoverSourceID = selectedSourceID
        if !selectedSourceID.isEmpty && container.settings.lastDiscoverSourceID != selectedSourceID {
            container.settings.lastDiscoverSourceID = selectedSourceID
        }
        guard !selectedSourceID.isEmpty else {
            resetDiscoverFeedState()
            return
        }
        await loadCategoriesAndFirstPage(container: container)
    }

    func selectSource(_ id: String, container: AppContainer) async {
        cancelLoadMoreTask()
        cancelBackgroundPreloads()
        selectedSourceID = id
        container.activeDiscoverSourceID = id
        container.settings.lastDiscoverSourceID = id
        await loadCategoriesAndFirstPage(container: container)
    }

    /// 下拉原地刷新当前选中书源与分类（同时重置本源空分类黑名单以便重新检验）
    func refreshCurrentCategory(container: AppContainer) async {
        cancelLoadMoreTask()
        cancelBackgroundPreloads()
        guard !selectedSourceID.isEmpty else {
            await loadSources(container: container)
            return
        }
        clearEmptyCategories(for: selectedSourceID)
        if !rawCategories.isEmpty && rawCategories.count != categories.count {
            categories = rawCategories
        }
        let activeURL = resolvedRequestURL(for: activeCategoryURL)
        await loadFirstPage(categoryURL: activeURL, container: container, preserveExistingOnFailure: true, forceRemote: true)
    }

    func selectCategory(_ cat: DiscoverCategoryDTO, container: AppContainer) async {
        cancelLoadMoreTask()
        selectedCategoryID = cat.id
        await loadFirstPage(categoryURL: resolvedRequestURL(for: cat.url), container: container)
    }

    func selectCategory(id: String, container: AppContainer) async {
        guard let target = categories.first(where: { $0.id == id }) else { return }
        await selectCategory(target, container: container)
    }

    func loadNextPageIfNeeded(currentItemID: String, container: AppContainer) {
        if let idx = books.firstIndex(where: { $0.id == currentItemID }) {
            prefetchCovers(startingAt: idx + 1, container: container)
            guard !isLoading, loadMoreTask == nil, hasMore, loadMoreError == nil, !books.isEmpty else { return }
            let tailIndex = max(0, books.count - 6)
            if idx >= tailIndex {
                startLoadMoreTask(container: container)
            }
        }
    }

    func retryLoadMore(container: AppContainer) {
        guard !isLoading, loadMoreTask == nil, hasMore else { return }
        startLoadMoreTask(container: container)
    }

    private func resetDiscoverFeedState() {
        cancelLoadMoreTask()
        books = []
        categories = []
        selectedCategoryID = ""
        seenBookIDs.removeAll()
        currentPage = 1
        nextPageURL = nil
        hasMore = false
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
        if let cachedCats = cachedCategories(for: selectedSourceID) {
            rawCategories = cachedCats
            let visible = filteredVisibleCategories(from: cachedCats, sourceID: selectedSourceID)
            selectedCategoryID = visible.first?.id ?? ""
            categories = visible
            await loadFirstPage(categoryURL: resolvedRequestURL(for: visible.first?.url ?? ""), container: container)
            return
        }
        do {
            let cats = try await container.pluginRuntime.discoverCategories(sourceID: selectedSourceID)
            guard gen == generation else { return }
            storeCategoriesCache(cats, for: selectedSourceID)
            rawCategories = cats
            let visible = filteredVisibleCategories(from: cats, sourceID: selectedSourceID)
            selectedCategoryID = visible.first?.id ?? ""
            categories = visible
            await loadFirstPage(categoryURL: resolvedRequestURL(for: visible.first?.url ?? ""), container: container)
        } catch {
            if Self.isCancellationError(error) {
                if gen == generation { isLoading = false }
                return
            }
            guard gen == generation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func loadFirstPage(
        categoryURL: String,
        container: AppContainer,
        preserveExistingOnFailure: Bool = false,
        forceRemote: Bool = false
    ) async {
        cancelLoadMoreTask()
        generation &+= 1
        let gen = generation
        let cacheKey = feedCacheKey(sourceID: selectedSourceID, categoryURL: categoryURL)
        cancelBackgroundPreloads()
        if !forceRemote, let cached = cachedFeed(for: cacheKey) {
            applyCachedFeed(cached)
            prefetchCovers(startingAt: 0, container: container)
            scheduleCategoryProbeIfNeeded(container: container)
            return
        }
        isLoading = true
        errorMessage = nil
        loadMoreError = nil

        if !preserveExistingOnFailure {
            currentPage = 1
            nextPageURL = nil
            seenBookIDs.removeAll()
            consecutiveDuplicatePages = 0
            books = []
            hasMore = true
        }

        do {
            var pageResult = try await container.pluginRuntime.discoverPage(
                sourceID: selectedSourceID,
                categoryURL: categoryURL,
                page: 1
            )
            guard gen == generation else { return }
            // 首次返回空数组时延迟 350ms 静默重试 1 次，化解首次种 Cookie / 瞬时限流导致的假空态
            if pageResult.books.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, gen == generation else { return }
                pageResult = try await container.pluginRuntime.discoverPage(
                    sourceID: selectedSourceID,
                    categoryURL: categoryURL,
                    page: 1
                )
                guard gen == generation else { return }
            }
            seenBookIDs.removeAll()
            consecutiveDuplicatePages = 0
            books = []
            currentPage = 1
            appendUnique(pageResult.books)
            nextPageURL = pageResult.nextURL
            hasMore = pageResult.hasMore
            isLoading = false
            if !books.isEmpty {
                markCategoryHasContent(sourceID: selectedSourceID, categoryID: selectedCategoryID)
                storeFeedCache(key: cacheKey)
                prefetchCovers(startingAt: 0, container: container)
            }
            scheduleCategoryProbeIfNeeded(container: container)
        } catch {
            if Self.isCancellationError(error) {
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

    private func appendUnique(_ incoming: [BookSummaryDTO]) {
        for item in incoming where seenBookIDs.insert(item.id).inserted {
            books.append(item)
        }
    }

}
