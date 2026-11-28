import DSCore
import DSDesignSystem
import SwiftUI
import UIKit

/// 首页融合搜索内容区（承载三态：准备态[历史+全源热门书籍]、实时联想态[直达卡片+高亮词]、多源聚合结果态）
struct SearchRootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner

    @Bindable var vm: SearchViewModel
    @FocusState.Binding var isSearchFocused: Bool
    @State private var showFailedSheet = false

    private var isShowingSearchPhase: Bool {
        vm.isSearching || vm.lastSearchedTerm != nil || !vm.results.isEmpty
    }

    private var scopeSelectionBinding: Binding<String> {
        Binding(
            get: { vm.selectedScopeID },
            set: { next in
                guard vm.selectedScopeID != next else { return }
                vm.selectedScopeID = next
                vm.recomputeHotBooksFromCache()
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
            if !vm.isShowingSuggestions {
                searchScopeHeader
            }
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
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
    }

    @ViewBuilder
    private var searchScopeHeader: some View {
        let showResultFilter = isShowingSearchPhase && vm.availableResultSources.count > 1
        let showScopeChips = !showResultFilter && !vm.scopeChips.isEmpty
        let showSkippedBar = !vm.skippedSourceIDs.isEmpty

        if showResultFilter || showScopeChips || showSkippedBar {
            VStack(spacing: DSSpacing.xs) {
                if showResultFilter {
                    DSChipBar(
                        items: vm.resultFilterChips,
                        selection: resultFilterBinding,
                        isCompact: true
                    )
                } else if showScopeChips {
                    DSChipBar(
                        items: vm.scopeChips,
                        selection: scopeSelectionBinding,
                        isCompact: true
                    )
                }

                if showSkippedBar {
                    skippedSourcesBanner
                }
            }
            .padding(.bottom, DSSpacing.xs)
            .background(.bar)
        }
    }

    private var skippedSourcesBanner: some View {
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

    @ViewBuilder
    private var phaseContent: some View {
        if vm.isShowingSuggestions {
            SearchSuggestionsView(
                query: vm.query,
                directBooks: vm.suggestedBooks,
                keywords: vm.suggestedKeywords,
                isLoading: vm.isLoadingSuggestions,
                shelfBookIDs: vm.shelfBookIDs,
                pipeline: container.coverPipeline,
                onSelectBook: { book in
                    isSearchFocused = false
                    router.push(.bookDetail(book))
                },
                onSelectKeyword: { keyword in
                    isSearchFocused = false
                    vm.executeSearch(keyword: keyword, container: container)
                }
            )
        } else if !isShowingSearchPhase {
            prepareScrollView
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

    private var prepareScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
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
                        isLoading: vm.isLoadingHotBooks,
                        priorityCaption: vm.hotBooksPriorityCaption,
                        shelfBookIDs: vm.shelfBookIDs,
                        pipeline: container.coverPipeline,
                        onSelectBook: { book in
                            isSearchFocused = false
                            router.push(.bookDetail(book))
                        },
                        onSelectNarrator: { narrator in
                            isSearchFocused = false
                            vm.selectedScopeID = SearchViewModel.allSourcesChipID
                            vm.executeSearch(keyword: narrator, container: container)
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
                ScrollView {
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
                                    vm.selectedScopeID = SearchViewModel.allSourcesChipID
                                    vm.executeSearch(keyword: narrator, container: container)
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.md)
            } else if let err = vm.loadMoreError {
                Button {
                    vm.retryLoadMore(container: container)
                } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "arrow.clockwise")
                        Text("加载更多失败（\(err)），点按重试")
                            .lineLimit(1)
                    }
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DSSpacing.pageHorizontal)
            } else if vm.canLoadMoreForCurrentFilter {
                Button {
                    vm.retryLoadMore(container: container)
                } label: {
                    Text("加载更多搜索结果")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            } else if !vm.isSearching && !vm.filteredResults.isEmpty {
                Text("已加载全部搜索结果")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DSSpacing.md)
            }
        }
    }
}
