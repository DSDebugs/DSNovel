import SwiftUI
import SwiftData
import UIKit

struct SearchRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dsReduceMotion) private var reduceMotion
    @Query(sort: [SortDescriptor(\SearchHistory.updatedAt, order: .reverse)])
    private var histories: [SearchHistory]

    @State private var searchStore = SearchStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var discoverStore = DiscoverStore.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var showFailedSheet = false
    @State private var pendingAuthRequest: (sourceID: String, isVerification: Bool)?
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
            if let request = pendingAuthRequest {
                pendingAuthRequest = nil
                AuthCoordinator.shared.presentLogin(
                    forSourceID: request.sourceID,
                    isVerification: request.isVerification
                )
            }
        }) {
            FailedSourcesSheet(
                failedSources: searchStore.failedSources,
                onLogin: { item in
                    let isVerify: Bool
                    if case .needVerify = item.stateKind {
                        isVerify = true
                    } else {
                        isVerify = false
                    }
                    pendingAuthRequest = (item.sourceID, isVerify)
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

            if searchStore.skippedSourceCount > 0 {
                HStack(spacing: Spacing.s2) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(DSTypography.caption)
                        .foregroundStyle(Color.dsAccent)
                    Text("本次会话已跳过 \(searchStore.skippedSourceCount) 个书源")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        searchStore.restoreSkippedSources()
                        DSHapticPolicy.fire(.selection)
                        BannerCenter.shared.show("已恢复全部跳过的书源", kind: .info)
                        if searchStore.phase == .results || searchStore.phase == .empty || searchStore.phase == .allFailed {
                            searchStore.submit(sources: activeSources, modelContext: modelContext)
                        }
                    } label: {
                        Text("一键恢复")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                            .padding(.horizontal, Spacing.s2)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.pageHorizontal)
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
                let isAllScope = searchStore.selectedScope == .all
                DSStateView(
                    kind: .empty,
                    titleOverride: "未找到相关书籍",
                    messageOverride: "试试更换关键词、演播名或扩大搜索范围",
                    primaryTitleOverride: isAllScope ? "重试搜索" : "搜索全部书源",
                    secondaryTitleOverride: "管理书源",
                    onPrimary: {
                        if isAllScope {
                            searchStore.submit(sources: activeSources, modelContext: modelContext)
                        } else {
                            // 仅切换范围，由 .onChange(of: searchStore.selectedScope) 单次触发搜索，避免重复请求
                            searchStore.selectedScope = .all
                        }
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
                Motion.withResolved(Motion.snappy, reduce: reduceMotion) {
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
        let shelfIDs = libraryStore.shelfBookIDs
        return VStack(spacing: Spacing.s2) {
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
                    Motion.withResolved(Motion.snappy, reduce: reduceMotion) {
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
                                let isInShelf = shelfIDs.contains(item.primary.id)
                                let model = BookCardModel(
                                    id: item.id,
                                    title: item.primary.title,
                                    author: item.primary.author,
                                    sourceName: srcName,
                                    coverURL: item.primary.cover,
                                    progressSubtitle: item.primary.discoverSubtitle,
                                    inShelf: isInShelf
                                )
                                DSBookRow(
                                    model: model,
                                    onSelect: {
                                        AppRouter.shared.open(.book(item.primary))
                                    }
                                )
                                .contextMenu {
                                    Button {
                                        let nowInShelf = libraryStore.toggleShelfImmediate(
                                            for: item.primary,
                                            context: modelContext
                                        )
                                        DSHapticPolicy.fire(nowInShelf ? .success : .selection)
                                        BannerCenter.shared.show(
                                            nowInShelf ? "已加入书架" : "已从书架移除",
                                            kind: nowInShelf ? .success : .info,
                                            bypassDeduplication: true
                                        )
                                    } label: {
                                        Label(
                                            isInShelf ? "移出书架" : "加入书架",
                                            systemImage: isInShelf ? "heart.slash" : "heart.fill"
                                        )
                                    }

                                    Button {
                                        UIPasteboard.general.string = item.primary.bookURL
                                        BannerCenter.shared.show("已复制书籍链接", kind: .info)
                                    } label: {
                                        Label("复制链接", systemImage: "doc.on.doc")
                                    }
                                }
                                .padding(.horizontal, Spacing.pageHorizontal)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        let offsetY = geo.contentOffset.y + geo.contentInsets.top
                        let threshold = max(120, geo.containerSize.height * 0.45)
                        return offsetY > threshold
                    } action: { _, isPastFirstScreen in
                        searchStore.updateScrollPastFirstScreen(isPastFirstScreen)
                    }
                    .onChange(of: ScrollToTopCenter.shared.count(for: .search)) { _, _ in
                        Motion.withResolved(Motion.snappy, reduce: reduceMotion) {
                            proxy.scrollTo("searchResultsTop", anchor: .top)
                        }
                    }
                }
            }
        }
    }
}
