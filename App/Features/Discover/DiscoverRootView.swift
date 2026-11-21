import DSCore
import DSDesignSystem
import SwiftUI

/// 发现根视图（VM 托管分页 + 无 GeometryReader + 源失效自动回退 + 零视图内集合过滤）
struct DiscoverRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var vm = DiscoverViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: DSSpacing.sm),
        GridItem(.flexible(), spacing: DSSpacing.sm),
        GridItem(.flexible(), spacing: DSSpacing.sm)
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    Color.clear.frame(height: 1).id("discover-top")
                    sourceBar
                    categoryBar

                    if vm.isLoading && vm.books.isEmpty {
                        ProgressView("正在加载发现内容...")
                            .frame(maxWidth: .infinity)
                            .padding(.top, DSSpacing.xl)
                    } else if let err = vm.errorMessage, vm.books.isEmpty {
                        DSStateView(
                            icon: "wifi.exclamationmark",
                            title: "加载失败",
                            message: err,
                            actionTitle: "重试"
                        ) {
                            Task { await vm.loadSources(container: container) }
                        }
                    } else if vm.books.isEmpty {
                        DSStateView(
                            icon: "safari",
                            title: "暂无发现榜单",
                            message: "请检查书源管理中是否已启用支持发现页的书源。",
                            actionTitle: "管理书源"
                        ) {
                            router.push(.sources)
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: DSSpacing.md) {
                            ForEach(vm.books) { book in
                                DSBookCard(book: book, pipeline: container.coverPipeline) {
                                    router.push(.bookDetail(book))
                                }
                                .onAppear {
                                    vm.loadNextPageIfNeeded(currentItemID: book.id, container: container)
                                }
                            }
                        }
                        .padding(.horizontal, DSSpacing.md)
                        if vm.isLoading {
                            ProgressView("正在加载更多...")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DSSpacing.md)
                        } else if let loadErr = vm.loadMoreError {
                            VStack(spacing: DSSpacing.xs) {
                                Text("加载更多失败：\(loadErr)")
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.inkSecondary)
                                    .lineLimit(2)
                                Button("点击重试") {
                                    vm.retryLoadMore(container: container)
                                }
                                .font(DSTypography.caption)
                                .buttonStyle(.bordered)
                                .frame(minHeight: 36)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DSSpacing.sm)
                        } else if !vm.hasMore {
                            Text("已加载全部榜单")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.inkSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DSSpacing.sm)
                        }
                    }
                }
                .padding(.top, DSSpacing.xs)
            }
            .onChange(of: router.scrollToTopTrigger[.discover] ?? 0) { _, _ in
                DSMotion.withResolved(.easeOut(duration: 0.25), reduceMotion: reduceMotion) {
                    proxy.scrollTo("discover-top", anchor: .top)
                }
            }
        }
        .accessibilityIdentifier("discover_root")
        .background(DSColors.surfaceBase)
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await vm.refreshCurrentCategory(container: container)
            if !vm.books.isEmpty, let err = vm.errorMessage {
                banner.show("刷新失败：\(err)", tone: .error)
            }
        }
        .onChange(of: container.sourcesRevision) { _, _ in
            Task { await vm.syncSourcesIncremental(container: container) }
        }
        .task {
            if vm.sources.isEmpty {
                await vm.loadSources(container: container)
            }
        }
    }

    private var sourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.xs) {
                ForEach(vm.sources) { src in
                    let active = (src.id == vm.selectedSourceID)
                    Button {
                        Task { await vm.selectSource(src.id, container: container) }
                    } label: {
                        HStack(spacing: DSSpacing.xxs) {
                            DSSourceAvatar(name: src.name)
                            Text(src.name)
                                .font(DSTypography.footnote.weight(active ? .semibold : .regular))
                        }
                        .padding(.horizontal, DSSpacing.sm)
                        .frame(minHeight: 44)
                        .background(active ? DSColors.accent.opacity(0.16) : DSColors.surfaceCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSSpacing.md)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.xs) {
                ForEach(vm.categories) { cat in
                    let active = (cat.id == vm.selectedCategoryID)
                    Button {
                        Task { await vm.selectCategory(cat, container: container) }
                    } label: {
                        Text(cat.title)
                            .font(DSTypography.footnote)
                            .foregroundStyle(active ? DSColors.onAccent : DSColors.inkPrimary)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 36)
                            .background(active ? DSColors.accent : DSColors.surfaceCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSSpacing.md)
        }
    }
}
