import SwiftUI
import SwiftData

struct SearchRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SearchHistory.updatedAt, order: .reverse)])
    private var histories: [SearchHistory]

    @State private var searchStore = SearchStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var showFailedSheet = false

    init() {}

    private var activeSources: [PluginRecord] {
        searchStore.activeTargetSources(from: sourceStore.allSources, groups: sourceStore.groups)
    }

    var body: some View {
        VStack(spacing: Spacing.s2) {
            if searchStore.mergedItems.isEmpty && !searchStore.isSearching && searchStore.totalSourcesCount == 0 {
                preSearchView
            } else {
                searchResultsView
            }
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle("搜索")
        .searchable(text: $searchStore.keyword, prompt: "搜索书名、作者或演播")
        .onSubmit(of: .search) {
            searchStore.submit(sources: activeSources, modelContext: modelContext)
        }
        .sheet(isPresented: $showFailedSheet) {
            FailedSourcesSheet(
                failedSources: searchStore.failedSources,
                onLogin: { item in
                    AuthCoordinator.shared.presentLogin(forSourceID: item.sourceID)
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
        .onAppear {
            sourceStore.modelContext = modelContext
        }
    }

    private var preSearchView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sectionVertical) {
                if sourceStore.searchableSources.isEmpty {
                    DSStateView(
                        kind: .noSource,
                        onPrimary: { AppRouter.shared.open(.sourceImport) },
                        onSecondary: { AppRouter.shared.open(.sourceList) }
                    )
                } else {
                    SearchScopeBar(
                        selectedScope: $searchStore.selectedScope,
                        groups: sourceStore.groups,
                        activeSourceCount: activeSources.count,
                        onManageSources: { AppRouter.shared.open(.sourceList) }
                    )

                    let suggestions = searchStore.prefixSuggestions(from: histories)
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.s2) {
                            DSSectionHeader(title: "输入建议")
                            ForEach(suggestions, id: \.self) { sug in
                                Button {
                                    searchStore.submit(keyword: sug, sources: activeSources, modelContext: modelContext)
                                } label: {
                                    Label(sug, systemImage: "magnifyingglass")
                                        .font(DSTypography.body)
                                        .padding(.horizontal, Spacing.pageHorizontal)
                                        .padding(.vertical, Spacing.s1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    SearchHistoryChips(
                        histories: histories,
                        onTapKeyword: { kw in
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
            }
            .padding(.vertical, Spacing.s3)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchResultsView: some View {
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
            } else if searchStore.mergedItems.isEmpty && !searchStore.failedSources.isEmpty {
                DSStateView(
                    kind: .error(detail: "全部书源检索失败"),
                    onPrimary: { showFailedSheet = true },
                    onSecondary: { searchStore.submit(sources: activeSources, modelContext: modelContext) }
                )
            } else if searchStore.mergedItems.isEmpty {
                DSStateView(
                    kind: .empty,
                    onPrimary: {
                        searchStore.selectedScope = .all
                        searchStore.submit(sources: activeSources, modelContext: modelContext)
                    },
                    onSecondary: { AppRouter.shared.open(.sourceList) }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.s2) {
                        ForEach(searchStore.displayedItems) { item in
                            let srcName = sourceStore.sourceName(for: item.primary.sourceID)
                            let altBadge = item.alternatives.isEmpty ? srcName : "\(srcName) +\(item.alternatives.count)"
                            let model = BookCardModel(
                                id: item.id,
                                title: item.primary.title,
                                author: item.primary.author,
                                sourceName: altBadge,
                                coverURL: item.primary.cover,
                                progressSubtitle: item.primary.discoverSubtitle
                            )
                            DSBookRow(
                                model: model,
                                onSelect: {
                                    AppRouter.shared.open(.book(item.primary, alternatives: item.alternatives))
                                }
                            )
                            .padding(.horizontal, Spacing.pageHorizontal)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }
}
