import DSCore
import DSDesignSystem
import SwiftUI
import UIKit

/// 首页根视图（融合单源逛分类 + 原地四态聚合搜索，退出搜索无损保留原浏览分类与滚动位置）
struct DiscoverRootView: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner
    @AppStorage("discover.layout.style") private var layoutStyleRaw: String = DiscoverLayoutStyle.grid.rawValue

    @State private var vm = DiscoverViewModel()
    @State private var searchVM = SearchViewModel()
    @State private var isSearchMode = false
    @State private var showSourcePickerSheet = false
    @FocusState private var isSearchFocused: Bool

    private var layoutStyleBinding: Binding<DiscoverLayoutStyle> {
        Binding(
            get: { DiscoverLayoutStyle(rawValue: layoutStyleRaw) ?? .grid },
            set: { layoutStyleRaw = $0.rawValue }
        )
    }

    private var currentLayoutStyle: DiscoverLayoutStyle {
        DiscoverLayoutStyle(rawValue: layoutStyleRaw) ?? .grid
    }

    private var loadingSkeletonMode: DSSkeletonMode {
        currentLayoutStyle == .list ? .list(rows: 6) : .grid
    }

    private var discoverScrollResetToken: String {
        "\(vm.selectedSourceID)|\(vm.selectedCategoryID)|\(vm.sortOption.rawValue)"
    }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverHeaderBar(
                currentSourceName: vm.currentSourceName,
                searchKeyword: $searchVM.query,
                isSearchMode: isSearchMode,
                layoutStyle: layoutStyleBinding,
                sectionChips: vm.sectionChips,
                tabChips: vm.tabChips,
                subTabChips: vm.subTabChips,
                selectedSectionIndex: vm.selectedSectionIndex,
                selectedTabIndex: vm.selectedTabIndex,
                selectedSubTabIndex: vm.selectedSubTabIndex,
                currentSectionTitle: vm.currentSectionTitle,
                isSearchFocused: $isSearchFocused,
                onOpenSourcePicker: { showSourcePickerSheet = true },
                onSubmitSearch: {
                    isSearchFocused = false
                    enterSearchModeIfNeeded()
                    searchVM.executeSearch(container: container)
                },
                onClearKeyword: {
                    searchVM.clearToPrepareState()
                },
                onCancelSearch: {
                    exitSearchMode()
                },
                onSelectSection: { secIdx in
                    Task { await vm.selectSection(index: secIdx, container: container) }
                },
                onSelectTab: { tabIdx in
                    Task { await vm.selectTab(index: tabIdx, container: container) }
                },
                onSelectSubTab: { subIdx in
                    Task { await vm.selectSubTab(index: subIdx, container: container) }
                }
            )

            ZStack(alignment: .top) {
                browseContentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .opacity(isSearchMode ? 0 : 1)
                    .allowsHitTesting(!isSearchMode)
                    .accessibilityHidden(isSearchMode)

                if isSearchMode {
                    SearchRootView(vm: searchVM, isSearchFocused: $isSearchFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover_root")
        .background(DSColors.surfaceBase)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSourcePickerSheet) {
            sourcePickerSheet
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused {
                enterSearchModeIfNeeded()
                let trimmed = searchVM.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    searchVM.updateLiveSuggestions(
                        for: trimmed,
                        activeDiscoverSourceID: container.activeDiscoverSourceID,
                        container: container
                    )
                }
            }
        }
        .onChange(of: searchVM.query) { _, next in
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                searchVM.resetSearch()
                return
            }
            if trimmed == searchVM.lastSearchedTerm && (searchVM.isSearching || !isSearchFocused) {
                return
            }
            if !isSearchMode {
                enterSearchModeIfNeeded()
            }
            searchVM.updateLiveSuggestions(
                for: trimmed,
                activeDiscoverSourceID: container.activeDiscoverSourceID,
                container: container
            )
        }
        .onChange(of: router.pendingNarratorSearch) { _, _ in
            consumePendingNarratorSearchIfNeeded()
        }
        .onChange(of: router.pendingOpenSearch) { _, _ in
            consumePendingOpenSearchIfNeeded()
        }
        .onChange(of: router.scrollToTopTrigger[.discover] ?? 0) { _, _ in
            if isSearchMode {
                exitSearchMode()
            }
        }
        .onChange(of: isSearchMode) { _, active in
            router.isBottomBarHidden = active
        }
        .onChange(of: vm.selectedSourceID) { _, nextID in
            searchVM.activeDiscoverSourceID = nextID
            searchVM.activeDiscoverSourceName = vm.sources.isEmpty ? "" : vm.currentSourceName
        }
        .onChange(of: container.sourcesRevision) { _, _ in
            Task {
                await vm.syncSourcesIncremental(container: container)
                await searchVM.loadSearchableSources(container: container)
                searchVM.invalidateHotBooksCache()
                await searchVM.loadHotBooksIfNeeded(container: container, forceReload: true)
            }
        }
        .onChange(of: container.libraryRevision) { _, _ in
            Task {
                await vm.loadShelfBookIDs(container: container)
                await searchVM.loadShelfBookIDs(container: container)
            }
        }
        .onAppear {
            consumePendingNarratorSearchIfNeeded()
            consumePendingOpenSearchIfNeeded()
            Task {
                await vm.loadShelfBookIDs(container: container)
                await searchVM.loadShelfBookIDs(container: container)
                if vm.sources.isEmpty || (vm.books.isEmpty && !vm.isLoading) {
                    await vm.loadSources(container: container)
                }
            }
        }
        .onDisappear {
            if isSearchMode {
                router.isBottomBarHidden = false
            }
        }
        .task {
            searchVM.activeDiscoverSourceID = vm.selectedSourceID.isEmpty ? container.activeDiscoverSourceID : vm.selectedSourceID
            await searchVM.loadHistory(container: container)
            await searchVM.loadSearchableSources(container: container)
            await searchVM.loadShelfBookIDs(container: container)
            await searchVM.loadHotBooksIfNeeded(container: container)
            consumePendingNarratorSearchIfNeeded()
            consumePendingOpenSearchIfNeeded()
        }
    }

    private func enterSearchModeIfNeeded() {
        searchVM.activeDiscoverSourceID = vm.selectedSourceID.isEmpty ? container.activeDiscoverSourceID : vm.selectedSourceID
        searchVM.activeDiscoverSourceName = vm.sources.isEmpty ? "" : vm.currentSourceName
        if !isSearchMode {
            DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                isSearchMode = true
            }
            router.isBottomBarHidden = true
            Task {
                await searchVM.loadSearchableSources(container: container)
                await searchVM.loadHistory(container: container)
                await searchVM.loadHotBooksIfNeeded(container: container)
            }
        }
    }

    private func exitSearchMode() {
        isSearchFocused = false
        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
            isSearchMode = false
        }
        router.isBottomBarHidden = false
        searchVM.clearToPrepareState()
    }

    private func consumePendingNarratorSearchIfNeeded() {
        guard let narrator = router.consumePendingNarratorSearch() else { return }
        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
            isSearchMode = true
        }
        isSearchFocused = false
        searchVM.selectedScopeID = SearchViewModel.allSourcesChipID
        searchVM.executeSearch(keyword: narrator, container: container)
    }

    private func consumePendingOpenSearchIfNeeded() {
        guard router.consumePendingOpenSearch() else { return }
        enterSearchModeIfNeeded()
        isSearchFocused = true
    }

    private var sourcePickerSheet: some View {
        DiscoverSourcePickerSheet(
            sections: vm.sourceSections,
            selectedSourceID: vm.selectedSourceID,
            onSelectSource: { id in
                showSourcePickerSheet = false
                Task { await vm.selectSource(id, container: container) }
            },
            onManageSources: {
                showSourcePickerSheet = false
                router.push(.sources)
            }
        )
    }

    @ViewBuilder
    private var browseContentArea: some View {
        if vm.sources.isEmpty && !vm.isLoading {
            centeredState {
                DSStateView(
                    kind: .noSource,
                    primaryTitleOverride: "管理书源",
                    secondaryTitleOverride: "重新加载",
                    onPrimary: { router.push(.sources) },
                    onSecondary: { Task { await vm.loadSources(container: container) } }
                )
            }
        } else if vm.isLoading && vm.books.isEmpty {
            DSSkeleton(mode: loadingSkeletonMode)
                .padding(.top, DSSpacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let err = vm.errorMessage, vm.books.isEmpty {
            centeredState {
                DSStateView(
                    kind: .error(detail: err),
                    onPrimary: { Task { await vm.loadSources(container: container) } },
                    onSecondary: { showSourcePickerSheet = true }
                )
            }
        } else if vm.books.isEmpty {
            centeredState {
                DSStateView(
                    kind: .empty,
                    onPrimary: { showSourcePickerSheet = true },
                    onSecondary: { Task { await vm.refreshCurrentCategory(container: container) } }
                )
            }
        } else {
            discoverBooksContent
        }
    }

    private func centeredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack {
                Spacer(minLength: DSSpacing.xl)
                content()
                Spacer(minLength: DSSpacing.xl)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var discoverBooksContent: some View {
        DiscoverContent(
            books: vm.books,
            shelfBookIDs: vm.shelfBookIDs,
            pipeline: container.coverPipeline,
            layoutStyle: currentLayoutStyle,
            canLoadMore: vm.hasMore,
            isLoadingMore: vm.isLoading,
            loadMoreError: vm.loadMoreError,
            scrollResetToken: discoverScrollResetToken,
            scrollToTopCount: isSearchMode ? 0 : (router.scrollToTopTrigger[.discover] ?? 0),
            showRankBadges: vm.isRankMode,
            categoryHeaderTitle: vm.currentCategoryDisplayTitle,
            sortOption: vm.sortOption,
            supportsSort: vm.supportsSort,
            onSelectSort: { option in
                Task { await vm.selectSortOption(option, container: container) }
            },
            onRefresh: {
                await vm.refreshCurrentCategory(container: container)
                if !vm.books.isEmpty, let err = vm.errorMessage {
                    banner.show("刷新失败：\(err)", tone: .error)
                }
            },
            onSelectBook: { book in
                router.push(.bookDetail(book))
            },
            onSelectNarrator: { narrator in
                isSearchFocused = false
                router.searchByNarrator(narrator)
            },
            onAddToShelf: { book in
                Task {
                    let added = await vm.addToShelf(book, container: container)
                    if added {
                        DSHaptics.lightImpact()
                        banner.show("已加入书架", tone: .success)
                    }
                }
            },
            onCopyLink: { book in
                UIPasteboard.general.string = book.bookURL
                DSHaptics.selection()
                banner.show("已复制书籍链接", tone: .info)
            },
            onReachLoadMoreTrigger: { itemID in
                vm.loadNextPageIfNeeded(currentItemID: itemID, container: container)
            },
            onRetryLoadMore: {
                vm.retryLoadMore(container: container)
            }
        )
    }
}
