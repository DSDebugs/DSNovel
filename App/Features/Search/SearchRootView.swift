import DSCore
import DSDesignSystem
import SwiftUI

/// 搜索根视图（零跳屏、搜索历史芯片、跳过源恢复入口、零视图内集合过滤）
struct SearchRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var vm = SearchViewModel()
    @State private var showFailedSheet = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if vm.isSearching {
                HStack(spacing: DSSpacing.xs) {
                    ProgressView()
                    Text("正在搜索书源（\(vm.completedSources)/\(vm.totalSources)）...")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                    Spacer()
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)
            }

            if !vm.failedSourceNames.isEmpty {
                HStack {
                    Text("部分书源超时跳过：\(vm.failedSourceNames.joined(separator: "、"))")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.warning)
                        .lineLimit(1)
                    Spacer()
                    Button("详情") {
                        showFailedSheet = true
                    }
                    .font(DSTypography.caption)
                    .frame(minHeight: 36)
                    Button("重试") {
                        vm.executeSearch(container: container)
                    }
                    .font(DSTypography.caption)
                    .frame(minHeight: 36)
                }
                .padding(.horizontal, DSSpacing.md)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 1).id("search-top")
                    if vm.results.isEmpty && !vm.isSearching {
                        if let emptyTerm = vm.lastSearchedTerm, !emptyTerm.isEmpty {
                            DSStateView(
                                icon: "magnifyingglass.circle",
                                title: "未找到「\(emptyTerm)」相关有声书",
                                message: "可尝试缩短关键词、更换作者/主播名，或在书源页确认已启用书源。"
                            )
                            .padding(.top, DSSpacing.md)
                            .padding(.horizontal, DSSpacing.md)
                        }
                        historySection
                    } else {
                        let sourceTabs = vm.availableResultSources
                        if sourceTabs.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: DSSpacing.xs) {
                                    sourceFilterChip(id: nil, title: "全部 (\(vm.results.count))")
                                    ForEach(sourceTabs, id: \.id) { item in
                                        sourceFilterChip(id: item.id, title: item.name)
                                    }
                                }
                                .padding(.horizontal, DSSpacing.md)
                                .padding(.top, DSSpacing.xs)
                            }
                        }
                        LazyVStack(spacing: DSSpacing.sm) {
                            ForEach(vm.filteredResults) { book in
                                DSBookRow(book: book, pipeline: container.coverPipeline) {
                                    router.push(.bookDetail(book))
                                }
                                .padding(DSSpacing.sm)
                                .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.md))
                            }
                        }
                        .padding(DSSpacing.md)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: router.scrollToTopTrigger[.search] ?? 0) { _, _ in
                    DSMotion.withResolved(.easeOut(duration: 0.25), reduceMotion: reduceMotion) {
                        proxy.scrollTo("search-top", anchor: .top)
                    }
                }
            }
        }
        .accessibilityIdentifier("search_root")
        .background(DSColors.surfaceBase)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFailedSheet) {
            FailedSourcesSheet(
                failedSourceNames: vm.failedSourceNames,
                onRetryAll: { vm.executeSearch(container: container) },
                onDismiss: { showFailedSheet = false }
            )
        }
        .onChange(of: vm.query) { _, next in
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vm.resetSearch()
            }
        }
        .task { await vm.loadHistory(container: container) }
    }

    private var searchBar: some View {
        HStack(spacing: DSSpacing.xs) {
            DSClearableSearchField("搜索书名、作者或演播", text: $vm.query) {
                vm.executeSearch(container: container)
            }
            Button("搜索") {
                vm.executeSearch(container: container)
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            if !vm.history.isEmpty {
                HStack {
                    Text("最近搜索")
                        .font(DSTypography.headline)
                    Spacer()
                    Button("清空") {
                        Task { await vm.clearHistory(container: container) }
                    }
                    .font(DSTypography.footnote)
                    .frame(minHeight: 44)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: DSSpacing.xs)], spacing: DSSpacing.xs) {
                    ForEach(vm.history, id: \.self) { kw in
                        Button {
                            vm.executeSearch(keyword: kw, container: container)
                        } label: {
                            Text(kw)
                                .font(DSTypography.footnote)
                                .lineLimit(1)
                                .padding(.horizontal, DSSpacing.sm)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(DSColors.surfaceCard, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HotBooksPanel { kw in
                vm.executeSearch(keyword: kw, container: container)
            }
            if vm.history.isEmpty {
                DSStateView(
                    icon: "magnifyingglass",
                    title: "全网有声书聚合搜索",
                    message: "输入书名、作者或主播名，立即并发检索全部已启用书源。"
                )
                .padding(.top, DSSpacing.xl)
            }
        }
        .padding(DSSpacing.md)
    }

    private func sourceFilterChip(id: String?, title: String) -> some View {
        let active = (vm.selectedSourceFilterID == id)
        return Button {
            vm.selectedSourceFilterID = id
        } label: {
            Text(title)
                .font(DSTypography.caption)
                .foregroundStyle(active ? DSColors.onAccent : DSColors.inkPrimary)
                .padding(.horizontal, DSSpacing.sm)
                .frame(minHeight: 36)
                .background(active ? DSColors.accent : DSColors.surfaceCard, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
