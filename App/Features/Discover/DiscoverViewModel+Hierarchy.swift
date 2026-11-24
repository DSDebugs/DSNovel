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
