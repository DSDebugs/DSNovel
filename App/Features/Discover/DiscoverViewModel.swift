import DSCore
import DSDesignSystem
import Foundation
import Observation

/// 首页发现状态控制器（去重分页、书源记忆、书源分组缓存与代际防抖）
@Observable
@MainActor
final class DiscoverViewModel {
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
    private(set) var categoryChips: [DSChipItem<String>] = []
    private(set) var categorySections: [DiscoverCategorySection] = []
    private(set) var sectionChips: [DSChipItem<Int>] = []
    private(set) var tabChips: [DSChipItem<Int>] = []
    var subTabChips: [DSChipItem<Int>] = []
    var selectedSectionIndex: Int = 0
    var selectedTabIndex: Int = 0
    var selectedSubTabIndex: Int = 0
    var sortOption: DiscoverSortOption = .hot
    var currentSectionTitle: String {
        categorySections.indices.contains(selectedSectionIndex) ? categorySections[selectedSectionIndex].title : ""
    }

    private var currentPage = 1
    private var nextPageURL: String?
    private var seenBookIDs: Set<String> = []
    private var consecutiveDuplicatePages = 0
    private var generation: UInt64 = 0
    private var loadMoreTask: Task<Void, Never>?

    var currentSourceName: String {
        sources.first(where: { $0.id == selectedSourceID })?.name ?? "发现"
    }

    func loadSources(container: AppContainer) async {
        await container.ensureSourcesRegistered()
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let enabled = Self.filterDiscoverSources(all.map(\.meta))
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
        await container.ensureSourcesRegistered()
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let enabled = Self.filterDiscoverSources(all.map(\.meta))
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
        selectedSourceID = id
        container.activeDiscoverSourceID = id
        container.settings.lastDiscoverSourceID = id
        await loadCategoriesAndFirstPage(container: container)
    }

    /// 下拉原地刷新当前选中书源与分类（成功后再替换列表，失败保留旧列表并提示错误）
    func refreshCurrentCategory(container: AppContainer) async {
        cancelLoadMoreTask()
        guard !selectedSourceID.isEmpty else {
            await loadSources(container: container)
            return
        }
        let activeURL = resolvedRequestURL(for: activeCategoryURL)
        await loadFirstPage(categoryURL: activeURL, container: container, preserveExistingOnFailure: true)
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

    func selectSection(index: Int, container: AppContainer) async {
        guard categorySections.indices.contains(index), index != selectedSectionIndex else { return }
        selectedSectionIndex = index
        selectedTabIndex = 0
        selectedSubTabIndex = 0
        rebuildTabChips()
        rebuildSubTabChips()
        guard let firstTab = categorySections[index].tabs.first else { return }
        await selectCategory(firstTab.category, container: container)
    }

    func selectTab(index: Int, container: AppContainer) async {
        guard categorySections.indices.contains(selectedSectionIndex) else { return }
        let tabs = categorySections[selectedSectionIndex].tabs
        guard tabs.indices.contains(index), index != selectedTabIndex else { return }
        selectedTabIndex = index
        selectedSubTabIndex = 0
        rebuildSubTabChips()
        await selectCategory(tabs[index].category, container: container)
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

    func loadShelfBookIDs(container: AppContainer) async {
        let shelf = (try? await container.persistence.fetchShelfBooks()) ?? []
        shelfBookIDs = Set(shelf.map(\.id))
    }

    func addToShelf(_ book: BookSummaryDTO, container: AppContainer) async -> Bool {
        guard !shelfBookIDs.contains(book.id) else { return false }
        do {
            try await container.persistence.upsertBook(book, addToShelf: true)
            shelfBookIDs.insert(book.id)
            container.libraryRevision &+= 1
            return true
        } catch {
            return false
        }
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
        do {
            let cats = try await container.pluginRuntime.discoverCategories(sourceID: selectedSourceID)
            guard gen == generation else { return }
            categories = cats
            selectedCategoryID = cats.first?.id ?? ""
            await loadFirstPage(categoryURL: resolvedRequestURL(for: cats.first?.url ?? ""), container: container)
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
            consecutiveDuplicatePages = 0
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
            consecutiveDuplicatePages = 0
            books = []
            currentPage = 1
            appendUnique(pageResult.books)
            nextPageURL = pageResult.nextURL
            hasMore = pageResult.hasMore
            isLoading = false
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

    private func rebuildCategoryChips() {
        categoryChips = categories.map { DSChipItem(id: $0.id, title: $0.title) }
        categorySections = DiscoverCategoryGrouping.buildSections(from: categories)
        sectionChips = categorySections.map { DSChipItem(id: $0.id, title: $0.title) }
        selectedSectionIndex = 0
        selectedTabIndex = 0
        selectedSubTabIndex = 0
        rebuildTabChips()
        rebuildSubTabChips()
    }

    private func rebuildTabChips() {
        guard categorySections.indices.contains(selectedSectionIndex) else {
            tabChips = []
            return
        }
        tabChips = categorySections[selectedSectionIndex].tabs.map { DSChipItem(id: $0.id, title: $0.shortTitle) }
    }

    static func isCancellationError(_ error: Error) -> Bool {
        Task.isCancelled
            || error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || error.localizedDescription.contains("请求已取消")
    }

    private static func filterDiscoverSources(_ all: [SourceMetaDTO]) -> [SourceMetaDTO] {
        all.filter { $0.isEnabled && ($0.methods.contains("discover") || $0.methods.contains("categoryPage") || $0.methods.contains("categoryMenus")) }
    }
}
