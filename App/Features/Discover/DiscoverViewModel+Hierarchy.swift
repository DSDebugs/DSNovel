import DSCore
import DSDesignSystem
import Foundation

extension DiscoverViewModel {
    var activeCategoryURL: String {
        categories.first(where: { $0.id == selectedCategoryID })?.url ?? ""
    }

    var isRankMode: Bool {
        activeCategoryURL.hasPrefix("xm-rank:")
            || activeCategoryURL.hasPrefix("tingyou:rank:")
            || currentSectionTitle == "排行榜"
            || currentSectionTitle == "热播榜单"
    }

    var supportsSort: Bool {
        !isRankMode && DiscoverSortHelper.supportsSort(url: activeCategoryURL)
    }

    var currentCategoryDisplayTitle: String {
        guard categorySections.indices.contains(selectedSectionIndex) else { return "" }
        let sec = categorySections[selectedSectionIndex]
        guard sec.tabs.indices.contains(selectedTabIndex) else { return sec.title }
        let tabTitle = sec.tabs[selectedTabIndex].shortTitle
        if sec.title.isEmpty || sec.title == "分类" {
            return tabTitle
        }
        return "\(sec.title) · \(tabTitle)"
    }

    func resolvedRequestURL(for rawURL: String) -> String {
        DiscoverSortHelper.supportsSort(url: rawURL)
            ? DiscoverSortHelper.applyingSort(sortOption, to: rawURL)
            : rawURL
    }

    func selectSubTab(index: Int, container: AppContainer) async {
        guard categorySections.indices.contains(selectedSectionIndex) else { return }
        let tabs = categorySections[selectedSectionIndex].tabs
        guard tabs.indices.contains(selectedTabIndex) else { return }
        let subTabs = tabs[selectedTabIndex].subTabs
        guard subTabs.indices.contains(index), index != selectedSubTabIndex else { return }
        selectedSubTabIndex = index
        await selectCategory(subTabs[index].category, container: container)
    }

    func selectSortOption(_ option: DiscoverSortOption, container: AppContainer) async {
        guard option != sortOption else { return }
        sortOption = option
        let rawURL = activeCategoryURL
        guard !rawURL.isEmpty else { return }
        await loadFirstPage(categoryURL: resolvedRequestURL(for: rawURL), container: container)
    }

    func rebuildSubTabChips() {
        guard categorySections.indices.contains(selectedSectionIndex) else {
            subTabChips = []
            return
        }
        let tabs = categorySections[selectedSectionIndex].tabs
        guard tabs.indices.contains(selectedTabIndex) else {
            subTabChips = []
            return
        }
        subTabChips = tabs[selectedTabIndex].subTabs.map { DSChipItem(id: $0.id, title: $0.shortTitle) }
    }

    func rebuildSourceSections() {
        var grouped: [String: [SourceMetaDTO]] = [:]
        for src in sources {
            let key = SourceListHelper.normalizedGroupName(src.groupName)
            grouped[key, default: []].append(src)
        }
        let orderedNames = SourceListHelper.allGroupNames(sources: sources, customGroups: [])
        sourceSections = orderedNames.compactMap { name in
            guard let list = grouped[name], !list.isEmpty else { return nil }
            let sorted = list.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.sortOrder < rhs.sortOrder
            }
            return DiscoverSourceSection(id: name, title: name, sources: sorted)
        }
    }
}

struct DiscoverCategoryCacheEntry {
    let categories: [DiscoverCategoryDTO]
    let cachedAt: Date
}

struct DiscoverFeedCacheEntry {
    let books: [BookSummaryDTO]
    let currentPage: Int
    let nextPageURL: String?
    let hasMore: Bool
    let cachedAt: Date
}

extension DiscoverViewModel {
    static let categoriesCacheTTL: TimeInterval = 30 * 60
    static let feedCacheTTL: TimeInterval = 10 * 60
    static let maxFeedCacheEntries = 20

    func feedCacheKey(sourceID: String, categoryURL: String) -> String {
        "\(sourceID)|\(categoryURL)|\(sortOption.rawValue)"
    }

    func cachedCategories(for sourceID: String) -> [DiscoverCategoryDTO]? {
        guard let entry = categoriesCache[sourceID],
              Date().timeIntervalSince(entry.cachedAt) < Self.categoriesCacheTTL,
              !entry.categories.isEmpty else { return nil }
        return entry.categories
    }

    func storeCategoriesCache(_ cats: [DiscoverCategoryDTO], for sourceID: String) {
        guard !sourceID.isEmpty, !cats.isEmpty else { return }
        categoriesCache[sourceID] = DiscoverCategoryCacheEntry(categories: cats, cachedAt: Date())
    }

    func cachedFeed(for key: String) -> DiscoverFeedCacheEntry? {
        guard let entry = feedCache[key],
              Date().timeIntervalSince(entry.cachedAt) < Self.feedCacheTTL,
              !entry.books.isEmpty else { return nil }
        feedCacheOrder.removeAll { $0 == key }
        feedCacheOrder.append(key)
        return entry
    }

    func storeFeedCache(key: String) {
        guard !books.isEmpty else { return }
        feedCache[key] = DiscoverFeedCacheEntry(
            books: books,
            currentPage: currentPage,
            nextPageURL: nextPageURL,
            hasMore: hasMore,
            cachedAt: Date()
        )
        feedCacheOrder.removeAll { $0 == key }
        feedCacheOrder.append(key)
        while feedCacheOrder.count > Self.maxFeedCacheEntries {
            let evicted = feedCacheOrder.removeFirst()
            feedCache.removeValue(forKey: evicted)
        }
    }

    func invalidateDiscoverCaches() {
        categoriesCache.removeAll()
        feedCache.removeAll()
        feedCacheOrder.removeAll()
    }

    func applyCachedFeed(_ cached: DiscoverFeedCacheEntry) {
        seenBookIDs = Set(cached.books.map(\.id))
        consecutiveDuplicatePages = 0
        books = cached.books
        currentPage = cached.currentPage
        nextPageURL = cached.nextPageURL
        hasMore = cached.hasMore
        isLoading = false
        errorMessage = nil
        loadMoreError = nil
    }

    static func isCancellationError(_ error: Error) -> Bool {
        Task.isCancelled
            || error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || error.localizedDescription.contains("请求已取消")
    }

    static func filterDiscoverSources(_ all: [SourceMetaDTO]) -> [SourceMetaDTO] {
        all.filter { $0.isEnabled && ($0.methods.contains("discover") || $0.methods.contains("categoryPage") || $0.methods.contains("categoryMenus")) }
    }
}
