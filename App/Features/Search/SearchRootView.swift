import DSCore
import DSDesignSystem
import SwiftUI
import UIKit

/// 搜索根视图（1:1 复刻 v2.8：隐藏导航栏、.background(.bar) 顶栏 + DSSearchField + DSChipBar、历史芯片 + 热门书籍、进度条 + 64pt DSBookRow 结果流与演播联动）
struct SearchRootView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner

    @State private var vm = SearchViewModel()
    @State private var showFailedSheet = false
    @FocusState private var isSearchFocused: Bool

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var isShowingSearchPhase: Bool {
        vm.isSearching || vm.lastSearchedTerm != nil || !vm.results.isEmpty
    }

    private var scopeSelectionBinding: Binding<String> {
        Binding(
            get: { vm.selectedScopeID },
            set: { next in
                guard vm.selectedScopeID != next else { return }
                vm.selectedScopeID = next
                if vm.lastSearchedTerm != nil && !vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vm.executeSearch(container: container)
                }
            }
        )
    }

    private var resultFilterBinding: Binding<String> {
        Binding(
            get: { vm.selectedSourceFilterID ?? SearchViewModel.allSourcesChipID },
            set: { next in
                vm.selectedSourceFilterID = (next == SearchViewModel.allSourcesChipID) ? nil : next
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeaderBar
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("search_root")
        .background(DSColors.surfaceBase)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showFailedSheet) {
            FailedSourcesSheet(
                failedItems: vm.failedSourceItems,
                onSkipSource: { item in
                    vm.skipFailedSource(item.sourceID)
                    if vm.failedSourceItems.isEmpty {
                        showFailedSheet = false
                    }
                },
                onRetryAll: { vm.executeSearch(container: container) },
                onDismiss: { showFailedSheet = false }
            )
        }
        .onChange(of: vm.query) { _, next in
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isShowingSearchPhase {
                vm.resetSearch()
            }
        }
        .onChange(of: router.pendingNarratorSearch) { _, _ in consumePendingNarratorSearchIfNeeded() }
        .onChange(of: container.sourcesRevision) { _, _ in
            Task {
                await vm.loadSearchableSources(container: container)
                if vm.hotBooks.isEmpty { await vm.loadHotBooksIfNeeded(container: container) }
            }
        }
        .onChange(of: container.libraryRevision) { _, _ in Task { await vm.loadShelfBookIDs(container: container) } }
        .onAppear { consumePendingNarratorSearchIfNeeded() }
        .task {
            await vm.loadHistory(container: container)
            await vm.loadSearchableSources(container: container)
            await vm.loadShelfBookIDs(container: container)
            await vm.loadHotBooksIfNeeded(container: container)
            consumePendingNarratorSearchIfNeeded()
        }
    }

    private var searchHeaderBar: some View {
        VStack(spacing: DSSpacing.xs) {
            DSSearchField(
                text: $vm.query,
                isFocused: $isSearchFocused,
                onSubmit: {
                    isSearchFocused = false
                    vm.executeSearch(container: container)
                },
                onClear: { vm.resetSearch() },
                onCancel: { vm.resetSearch() }
            )

            if isShowingSearchPhase && vm.availableResultSources.count > 1 {
                DSChipBar(
                    items: vm.resultFilterChips,
                    selection: resultFilterBinding,
                    isCompact: true
                )
            } else if !vm.scopeChips.isEmpty {
                DSChipBar(
                    items: vm.scopeChips,
                    selection: scopeSelectionBinding,
                    isCompact: true,
                    trailingActionTitle: "已选 \(vm.activeScopeSourceCount(activeDiscoverSourceID: container.activeDiscoverSourceID)) 个书源",
                    onTrailingAction: { router.push(.sources) }
                )
            }

            if !vm.skippedSourceIDs.isEmpty {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.accent)
                    Text("本次会话已跳过 \(vm.skippedSourceIDs.count) 个书源")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        vm.restoreSkippedSources()
                        DSHaptics.selection()
                        banner.show("已恢复全部跳过的书源", tone: .info)
                        if isShowingSearchPhase {
                            vm.executeSearch(container: container)
                        }
                    } label: {
                        Text("一键恢复")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                            .padding(.horizontal, DSSpacing.xs)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
            }
        }
        .padding(.vertical, DSSpacing.xs)
        .background(.bar)
    }

    @ViewBuilder
    private var phaseContent: some View {
        if !isShowingSearchPhase {
            idleScrollView
        } else if !vm.isSearching && vm.results.isEmpty && !vm.failedSourceItems.isEmpty && vm.completedSources == vm.totalSources {
            ScrollView {
                DSStateView(
                    kind: .error(detail: "全部书源检索失败"),
                    titleOverride: "全部书源检索失败",
                    messageOverride: "网络或书源响应异常，可重试或查看失败详情",
                    primaryTitleOverride: "重试",
                    secondaryTitleOverride: "查看失败原因",
                    onPrimary: { vm.executeSearch(container: container) },
                    onSecondary: { showFailedSheet = true }
                )
                .padding(.top, DSSpacing.xl)
            }
            .scrollDismissesKeyboard(.immediately)
        } else if !vm.isSearching && vm.results.isEmpty {
            ScrollView {
                DSStateView(
                    kind: .empty,
                    titleOverride: "未找到相关书籍",
                    messageOverride: "试试更换关键词、演播名或管理已启用书源",
                    primaryTitleOverride: "重试搜索",
                    secondaryTitleOverride: "管理书源",
                    onPrimary: { vm.executeSearch(container: container) },
                    onSecondary: { router.push(.sources) }
                )
                .padding(.top, DSSpacing.xl)
            }
            .scrollDismissesKeyboard(.immediately)
        } else {
            resultsView
        }
    }

    private var idleScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id("search-top")

                VStack(alignment: .leading, spacing: DSSpacing.sectionVertical) {
                    if vm.history.isEmpty {
                        Text("输入书名、作者或演播名称开始搜索")
                            .font(DSTypography.subtitle)
                            .foregroundStyle(DSColors.inkSecondary)
                            .padding(.horizontal, DSSpacing.pageHorizontal)
                    } else {
                        SearchHistoryChips(
                            histories: vm.history,
                            onTapKeyword: { kw in
                                isSearchFocused = false
                                vm.executeSearch(keyword: kw, container: container)
                            },
                            onDeleteKeyword: { kw in
                                Task { await vm.deleteHistoryKeyword(kw, container: container) }
                            },
                            onClearAll: {
                                Task { await vm.clearHistory(container: container) }
                            }
                        )
                    }

                    if !vm.hotBooks.isEmpty || vm.isLoadingHotBooks {
                        HotBooksSection(
                            books: vm.hotBooks,
                            sourceName: vm.hotBooksSourceName,
                            isLoading: vm.isLoadingHotBooks,
                            shelfBookIDs: vm.shelfBookIDs,
                            pipeline: container.coverPipeline,
                            onSelectBook: { book in
                                router.push(.bookDetail(book))
                            },
                            onSelectNarrator: { narrator in
                                isSearchFocused = false
                                router.searchByNarrator(narrator)
                            },
                            onRefresh: {
                                Task { await vm.loadHotBooksIfNeeded(container: container, forceReload: true) }
                            }
                        )
                    } else {
                        HotBooksPanel { kw in
                            isSearchFocused = false
                            vm.executeSearch(keyword: kw, container: container)
                        }
                    }
                }
                .padding(.vertical, DSSpacing.sm)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: router.scrollToTopTrigger[.search] ?? 0) { _, _ in
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                    proxy.scrollTo("search-top", anchor: .top)
                }
            }
        }
    }

    private var resultsView: some View {
        VStack(spacing: DSSpacing.xs) {
            SearchProgressHeader(
                isSearching: vm.isSearching,
                completedCount: vm.completedSources,
                totalCount: vm.totalSources,
                resultCount: vm.results.count,
                elapsedSeconds: vm.elapsedSeconds,
                failedCount: vm.failedSourceItems.count,
                onStop: { vm.stopSearch() },
                onOpenFailedSheet: { showFailedSheet = true }
            )

            if vm.isSearching && vm.results.isEmpty {
                DSSkeleton(mode: .list(rows: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear
                            .frame(height: 0)
                            .id("search-results-top")

                        LazyVStack(spacing: DSSpacing.xs) {
                            ForEach(vm.filteredResults) { book in
                                let isInShelf = vm.shelfBookIDs.contains(book.id)
                                SearchBookRow(
                                    book: book,
                                    pipeline: container.coverPipeline,
                                    inShelf: isInShelf,
                                    onTap: { router.push(.bookDetail(book)) },
                                    onNarratorTap: { narrator in
                                        isSearchFocused = false
                                        router.searchByNarrator(narrator)
                                    }
                                )
                                .contextMenu {
                                    Button {
                                        Task {
                                            let nowInShelf = await vm.toggleShelf(for: book, container: container)
                                            DSHaptics.lightImpact()
                                            banner.show(nowInShelf ? "已加入书架" : "已从书架移除", tone: nowInShelf ? .success : .info)
                                        }
                                    } label: {
                                        Label(
                                            isInShelf ? "移出书架" : "加入书架",
                                            systemImage: isInShelf ? "heart.slash" : "heart.fill"
                                        )
                                    }

                                    Button {
                                        UIPasteboard.general.string = book.bookURL
                                        DSHaptics.selection()
                                        banner.show("已复制书籍链接", tone: .info)
                                    } label: {
                                        Label("复制链接", systemImage: "doc.on.doc")
                                    }
                                }
                                .padding(.horizontal, DSSpacing.pageHorizontal)
                                .onAppear {
                                    vm.loadNextPageIfNeeded(currentItemID: book.id, container: container)
                                }
                            }
                        }

                        searchLoadMoreFooter
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onChange(of: router.scrollToTopTrigger[.search] ?? 0) { _, _ in
                        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                            proxy.scrollTo("search-results-top", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchLoadMoreFooter: some View {
        Group {
            if vm.isLoadingMore {
                HStack(spacing: DSSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在加载更多…")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            } else if vm.loadMoreError != nil {
                Button {
                    vm.retryLoadMore(container: container)
                } label: {
                    Text("加载失败，点按重试")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, DSSpacing.xs)
                        .background(Capsule().fill(DSColors.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            } else if !vm.isSearching && vm.canLoadMoreForCurrentFilter {
                Color.clear
                    .onAppear {
                        if let lastID = vm.filteredResults.last?.id {
                            vm.loadNextPageIfNeeded(currentItemID: lastID, container: container)
                        }
                    }
            } else if !vm.isSearching && !vm.filteredResults.isEmpty {
                Text("已加载全部")
                    .font(DSTypography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .padding(.bottom, DSSpacing.md)
    }

    private func consumePendingNarratorSearchIfNeeded() {
        guard let pending = router.consumePendingNarratorSearch(), !pending.isEmpty else { return }
        isSearchFocused = false
        vm.executeSearch(keyword: pending, container: container)
    }
}
