import SwiftUI
import SwiftData

struct SearchRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SearchHistory.updatedAt, order: .reverse)])
    private var histories: [SearchHistory]

    @State private var searchStore = SearchStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var discoverStore = DiscoverStore.shared
    @State private var showFailedSheet = false
    @State private var pendingLoginSourceID: String?
    @FocusState private var isSearchFocused: Bool

    init() {}

    private var activeSources: [PluginRecord] {
        searchStore.activeTargetSources(from: sourceStore.allSources, groups: sourceStore.groups)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeaderBar
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dsSurfaceBase)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: searchStore.keyword) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if searchStore.phase != .idle {
                    searchStore.resetKeepingFocusIfNeeded()
                }
            } else {
                searchStore.updateTypingState(isFocused: isSearchFocused || searchStore.phase == .idle || searchStore.phase == .typing)
            }
        }
        .onChange(of: searchStore.selectedScope) { _, _ in
            if searchStore.phase == .results || searchStore.phase == .empty || searchStore.phase == .allFailed {
                searchStore.submit(sources: activeSources, modelContext: modelContext)
            }
        }
        .sheet(isPresented: $showFailedSheet, onDismiss: {
            if let sourceID = pendingLoginSourceID {
                pendingLoginSourceID = nil
                AuthCoordinator.shared.presentLogin(forSourceID: sourceID)
            }
        }) {
            FailedSourcesSheet(
                failedSources: searchStore.failedSources,
                onLogin: { item in
                    pendingLoginSourceID = item.sourceID
                    showFailedSheet = false
                },
                onRetryAll: {
                    searchStore.submit(sources: activeSources, modelContext: modelContext)
                },
                onSkipSource: { item in
                    searchStore.skipFailedSource(item.sourceID)
                },
                onClose: { showFailedSheet = false }
            )
        }
        .task(id: discoverStore.currentSourceID) {
            sourceStore.modelContext = modelContext
            await searchStore.loadHotBooksIfNeeded(sources: sourceStore.discoverableSources)
        }
    }

    private var searchHeaderBar: some View {
        VStack(spacing: Spacing.s2) {
            DSSearchField(
                text: $searchStore.keyword,
                isFocused: $isSearchFocused,
                onSubmit: {
                    isSearchFocused = false
                    searchStore.submit(sources: activeSources, modelContext: modelContext)
                },
                onClear: {
                    searchStore.reset()
                },
                onCancel: {
                    searchStore.reset()
                }
            )
            .id("search.header.field")

            if !sourceStore.searchableSources.isEmpty {
                SearchScopeBar(
                    selectedScope: $searchStore.selectedScope,
                    groups: sourceStore.groups,
                    activeSourceCount: activeSources.count,
                    onManageSources: { AppRouter.shared.open(.sourceList) }
                )
            }
        }
        .padding(.vertical, Spacing.s2)
        .background(.bar)
    }

    @ViewBuilder
    private var phaseContent: some View {
        if sourceStore.searchableSources.isEmpty {
            DSStateView(
                kind: .noSource,
                onPrimary: { AppRouter.shared.open(.sourceImport) },
                onSecondary: { AppRouter.shared.open(.sourceList) }
            )
        } else {
            switch searchStore.phase {
            case .idle, .typing:
                browseScrollView
            case .searching, .results:
                resultsView
            case .empty:
                DSStateView(
                    kind: .empty,
                    titleOverride: "未找到相关书籍",
                    messageOverride: "试试更换关键词、演播名或扩大搜索范围",
                    primaryTitleOverride: "搜索全部书源",
                    secondaryTitleOverride: "管理书源",
                    onPrimary: {
                        searchStore.selectedScope = .all
                        searchStore.submit(sources: activeSources, modelContext: modelContext)
                    },
                    onSecondary: { AppRouter.shared.open(.sourceList) }
                )
            case .allFailed:
                DSStateView(
                    kind: .error(detail: "全部书源检索失败"),
                    titleOverride: "全部书源检索失败",
                    messageOverride: "网络或书源响应异常，可重试或查看失败详情",
                    primaryTitleOverride: "重试",
                    secondaryTitleOverride: "查看失败原因",
                    onPrimary: { searchStore.submit(sources: activeSources, modelContext: modelContext) },
                    onSecondary: { showFailedSheet = true }
                )
            }
        }
    }

    private var browseScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id("searchBrowseTop")

                if searchStore.phase == .typing && !searchStore.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    typingSuggestionsContent
                } else {
                    idleSectionsContent
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: ScrollToTopCenter.shared.count(for: .search)) { _, _ in
                withAnimation(Motion.snappy) {
                    proxy.scrollTo("searchBrowseTop", anchor: .top)
                }
            }
        }
    }

    private var idleSectionsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionVertical) {
            if histories.isEmpty {
                Text("输入书名、作者或演播名称开始搜索")
                    .font(DSTypography.subtitle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.pageHorizontal)
            } else {
                SearchHistoryChips(
                    histories: histories,
                    onTapKeyword: { kw in
                        isSearchFocused = false
                        searchStore.submit(keyword: kw, sources: activeSources, modelContext: modelContext)
                    },
                    onDeleteKeyword: { item in
                        modelContext.delete(item)
                        try? modelContext.save()
                    },
                    onClearAll: {
                        for h in histories { modelContext.delete(h) }
                        try? modelContext.save()
                    }
                )
            }

            HotBooksSection(
                books: searchStore.hotBooks,
                sourceName: searchStore.hotBooksSourceName,
                isLoading: searchStore.isLoadingHotBooks,
                onSelectBook: { ref in
                    AppRouter.shared.open(.book(ref))
                },
                onSelectNarrator: { narrator in
                    isSearchFocused = false
                    AppRouter.shared.searchByNarrator(narrator)
                },
                onRefresh: {
                    Task {
                        await searchStore.loadHotBooksIfNeeded(sources: sourceStore.discoverableSources, forceReload: true)
                    }
                }
            )
        }
        .padding(.vertical, Spacing.s3)
    }

    private var typingSuggestionsContent: some View {
        let suggestions = searchStore.prefixSuggestions(from: histories)
        return VStack(alignment: .leading, spacing: Spacing.s2) {
            if suggestions.isEmpty {
                Button {
                    isSearchFocused = false
                    searchStore.submit(sources: activeSources, modelContext: modelContext)
                } label: {
                    Label("搜索「\(searchStore.keyword)」", systemImage: "magnifyingglass")
                        .font(DSTypography.body)
                        .foregroundStyle(Color.dsAccent)
                        .padding(.horizontal, Spacing.pageHorizontal)
                        .padding(.vertical, Spacing.s2)
                }
                .buttonStyle(.plain)
            } else {
                DSSectionHeader(title: "历史联想")
                ForEach(suggestions, id: \.self) { sug in
                    Button {
                        isSearchFocused = false
                        searchStore.submit(keyword: sug, sources: activeSources, modelContext: modelContext)
                    } label: {
                        Label(sug, systemImage: "magnifyingglass")
                            .font(DSTypography.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.pageHorizontal)
                            .padding(.vertical, Spacing.s2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, Spacing.s2)
    }

    private var resultsView: some View {
        VStack(spacing: Spacing.s2) {
            SearchProgressHeader(
                isSearching: searchStore.isSearching,
                completedCount: searchStore.completedSourcesCount,
                totalCount: searchStore.totalSourcesCount,
                resultCount: searchStore.mergedItems.count,
                elapsedSeconds: searchStore.elapsedSeconds,
                failedCount: searchStore.failedSources.count,
                pendingHigherRelevanceCount: searchStore.pendingHigherRelevanceCount,
                onStop: { searchStore.cancelCurrentSearch() },
                onOpenFailedSheet: { showFailedSheet = true },
                onResort: {
                    withAnimation(Motion.snappy) {
                        searchStore.applyRelevanceResort()
                    }
                }
            )

            if searchStore.isSearching && searchStore.mergedItems.isEmpty {
                DSSkeleton(mode: .list(rows: 6))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear
                            .frame(height: 0)
                            .id("searchResultsTop")

                        LazyVStack(spacing: Spacing.s2) {
                            ForEach(searchStore.displayedItems) { item in
                                let srcName = sourceStore.sourceName(for: item.primary.sourceID)
                                let model = BookCardModel(
                                    id: item.id,
                                    title: item.primary.title,
                                    author: item.primary.author,
                                    sourceName: srcName,
                                    coverURL: item.primary.cover,
                                    progressSubtitle: item.primary.discoverSubtitle
                                )
                                DSBookRow(
                                    model: model,
                                    onSelect: {
                                        AppRouter.shared.open(.book(item.primary))
                                    }
                                )
                                .padding(.horizontal, Spacing.pageHorizontal)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: ScrollToTopCenter.shared.count(for: .search)) { _, _ in
                        withAnimation(Motion.snappy) {
                            proxy.scrollTo("searchResultsTop", anchor: .top)
                        }
                    }
                }
            }
        }
    }
}
