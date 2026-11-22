import DSCore
import DSDesignSystem
import SwiftUI
import UIKit

/// 发现根视图（1:1 复刻 v2.8：隐藏系统导航栏、紧凑双行顶栏、书源选择 Sheet、多布局内容流、源内搜索与骨架/空错态）
struct DiscoverRootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner
    @AppStorage("discover.layout.style") private var layoutStyleRaw: String = DiscoverLayoutStyle.grid.rawValue

    @State private var vm = DiscoverViewModel()
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
        "\(vm.selectedSourceID)|\(vm.selectedCategoryID)|\(vm.isSearchActive)"
    }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverHeaderBar(
                currentSourceName: vm.currentSourceName,
                searchKeyword: $vm.searchKeyword,
                isSearchActive: vm.isSearchActive,
                layoutStyle: layoutStyleBinding,
                categoryChips: vm.categoryChips,
                selectedCategoryID: vm.selectedCategoryID,
                isSearchFocused: $isSearchFocused,
                onOpenSourcePicker: { showSourcePickerSheet = true },
                onSubmitSearch: {
                    isSearchFocused = false
                    vm.submitSourceSearch(container: container)
                },
                onClearSearch: {
                    isSearchFocused = false
                    vm.clearSourceSearch()
                },
                onSelectCategory: { categoryID in
                    Task { await vm.selectCategory(id: categoryID, container: container) }
                }
            )

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("discover_root")
        .background(DSColors.surfaceBase)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSourcePickerSheet) {
            sourcePickerSheet
        }
        .onChange(of: vm.searchKeyword) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.isSearchActive {
                vm.clearSourceSearch()
            }
        }
        .onChange(of: container.sourcesRevision) { _, _ in
            Task { await vm.syncSourcesIncremental(container: container) }
        }
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await vm.loadShelfBookIDs(container: container) }
        }
        .task {
            await vm.loadShelfBookIDs(container: container)
            if vm.sources.isEmpty {
                await vm.loadSources(container: container)
            }
        }
    }

    private var sourcePickerSheet: some View {
        DSSheetScaffold(title: "选择书源", banner: banner, onDismiss: { showSourcePickerSheet = false }) {
            List {
                ForEach(vm.sourceSections) { section in
                    Section(section.title) {
                        ForEach(section.sources) { src in
                            let isSelected = (src.id == vm.selectedSourceID)
                            Button {
                                showSourcePickerSheet = false
                                Task { await vm.selectSource(src.id, container: container) }
                            } label: {
                                HStack {
                                    DSSourceBadge(name: src.name, showHealthAndLatency: false)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(DSColors.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .listRowBackground(DSColors.surfaceCard)
                        }
                    }
                }

                Section {
                    Button {
                        showSourcePickerSheet = false
                        router.push(.sources)
                    } label: {
                        HStack(spacing: DSSpacing.xs) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(DSColors.accent)
                            Text("管理书源")
                                .font(DSTypography.body.weight(.medium))
                                .foregroundStyle(DSColors.accent)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DSColors.surfaceCard)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var contentArea: some View {
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
        } else if vm.isSearchActive {
            scopedSearchContent
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
            discoverBooksContent(books: vm.books, isPaged: true)
        }
    }

    @ViewBuilder
    private var scopedSearchContent: some View {
        if vm.isSearchingInSource && vm.searchResults.isEmpty {
            DSSkeleton(mode: loadingSkeletonMode)
                .padding(.top, DSSpacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let err = vm.searchError, vm.searchResults.isEmpty {
            centeredState {
                DSStateView(
                    kind: .error(detail: err),
                    primaryTitleOverride: "重试",
                    secondaryTitleOverride: "返回发现",
                    onPrimary: { vm.submitSourceSearch(container: container) },
                    onSecondary: { vm.clearSourceSearch() }
                )
            }
        } else if vm.searchResults.isEmpty {
            centeredState {
                DSStateView(
                    kind: .empty,
                    titleOverride: "未找到相关书籍",
                    messageOverride: "当前书源暂无匹配结果，试试更换关键词",
                    primaryTitleOverride: "返回发现",
                    secondaryTitleOverride: "重新搜索",
                    onPrimary: { vm.clearSourceSearch() },
                    onSecondary: { vm.submitSourceSearch(container: container) }
                )
            }
        } else {
            discoverBooksContent(books: vm.searchResults, isPaged: false)
        }
    }

    private func centeredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: DSSpacing.lg)
            content()
            Spacer(minLength: DSSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func discoverBooksContent(books: [BookSummaryDTO], isPaged: Bool) -> some View {
        DiscoverContent(
            books: books,
            shelfBookIDs: vm.shelfBookIDs,
            pipeline: container.coverPipeline,
            layoutStyle: currentLayoutStyle,
            canLoadMore: isPaged ? vm.hasMore : false,
            isLoadingMore: isPaged ? vm.isLoading : false,
            loadMoreError: isPaged ? vm.loadMoreError : nil,
            scrollResetToken: discoverScrollResetToken,
            scrollToTopCount: router.scrollToTopTrigger[.discover] ?? 0,
            onRefresh: {
                if vm.isSearchActive {
                    await vm.refreshSourceSearch(container: container)
                } else {
                    await vm.refreshCurrentCategory(container: container)
                    if !vm.books.isEmpty, let err = vm.errorMessage {
                        banner.show("刷新失败：\(err)", tone: .error)
                    }
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
                if isPaged {
                    vm.loadNextPageIfNeeded(currentItemID: itemID, container: container)
                }
            },
            onRetryLoadMore: {
                if isPaged {
                    vm.retryLoadMore(container: container)
                }
            }
        )
    }
}
