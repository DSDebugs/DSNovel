import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSStorage
import SwiftUI

/// 书架根视图（1:1 复刻 v2.8：标题「书籍」/编辑态「已选 N 项」、ContinueSection、4 组 DSChipBar、3 列网格/64pt 列表、隐藏底栏 + 液态玻璃 ShelfSelectionBar）
struct LibraryRootView: View {
    @Environment(\.accessibilityReduceMotion) var systemReduceMotion
    @Environment(\.dsReduceMotion) var appReduceMotion
    @Environment(AppContainer.self) var container
    @Environment(AppRouter.self) var router
    @Environment(AppSettingsStore.self) var settings
    @Environment(DSBannerCoordinator.self) var banner
    @Environment(PlaybackCoordinator.self) var playback
    @Environment(DownloadCoordinator.self) var downloads

    @State var shelfItems: [LibraryBookItem] = []
    @State var downloadedItems: [LibraryBookItem] = []
    @State var continueItem: LibraryBookItem?
    @State var recentItems: [LibraryBookItem] = []
    @State var displayedItems: [LibraryBookItem] = []
    @State var filterChips: [DSChipItem<ShelfFilter>] = []

    @State var selectedFilter: ShelfFilter = .all
    @State var sortOrder: ShelfSortOrder = .recentPlayed
    @State var isLoading = false
    @State var isEditing = false
    @State var selectedIDs: Set<String> = []
    @State var pendingRemoveBook: LibraryBookItem?
    @State var pendingBatchDeleteItems: [LibraryBookItem] = []

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        @Bindable var bindableSettings = settings
        let dlOverview = LibraryOrganizerHelper.computeDownloadedOverview(from: downloads.manualRecords)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    Color.clear.frame(height: 0).id("library-top")

                    if !isEditing {
                        ListeningStatsCard(
                            overview: container.listeningStats.overview,
                            onOpenDetail: { router.push(.listeningStats) }
                        )
                    }

                    if !isEditing, let cont = continueItem {
                        let isCurrentBook = (playback.currentBook?.id == cont.id)
                        ContinueSection(
                            item: cont,
                            recentItems: recentItems,
                            playingBookID: playback.currentBook?.id,
                            isPlaying: isCurrentBook && playback.state.isPlaying,
                            isCurrentPlaybackBook: isCurrentBook,
                            liveChapterTitle: isCurrentBook ? playback.currentChapter?.title : nil,
                            pipeline: container.coverPipeline,
                            onOpenBook: { router.push(.bookDetail(cont.book)) },
                            onSelectRecent: { recent in router.push(.bookDetail(recent.book)) },
                            onTogglePlay: { Task { await playBookImmediately(cont) } },
                            onOpenHistory: { router.push(.history) }
                        )
                    }

                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        DSSectionHeader(
                            title: selectedFilter == .downloaded ? "已下载书籍" : "我的书架",
                            subtitle: "\(displayedItems.count) 本"
                        )
                        DSChipBar(items: filterChips, selection: $selectedFilter, isCompact: true)
                    }

                    if selectedFilter == .downloaded {
                        downloadedFilterStatusCard(overview: dlOverview)
                    }

                    mainShelfContent
                }
                .padding(.vertical, DSSpacing.xs)
            }
            .onChange(of: router.scrollToTopTrigger[.library] ?? 0) { _, _ in
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                    proxy.scrollTo("library-top", anchor: .top)
                }
            }
        }
        .accessibilityIdentifier("library_root")
        .background(DSColors.surfaceBase)
        .navigationTitle(isEditing ? "已选 \(selectedIDs.count) 项" : "书架")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isEditing) { _, hidden in
            router.isBottomBarHidden = hidden
        }
        .onChange(of: selectedFilter) { _, _ in
            selectedIDs.removeAll()
            recomputeDisplayed()
        }
        .onChange(of: sortOrder) { _, _ in
            recomputeDisplayed()
        }
        .toolbar {
            ShelfToolbar(
                isEditing: isEditing,
                allSelected: !displayedItems.isEmpty && selectedIDs.count == displayedItems.count,
                isShelfEmpty: displayedItems.isEmpty,
                isDownloadedFilter: selectedFilter == .downloaded,
                sortOrder: $sortOrder,
                layoutStyle: $bindableSettings.shelfLayout,
                onToggleEdit: {
                    isEditing.toggle()
                    if !isEditing { selectedIDs.removeAll() }
                },
                onToggleSelectAll: {
                    if selectedIDs.count == displayedItems.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(displayedItems.map(\.id))
                    }
                },
                onOpenHistory: { router.push(.history) },
                onOpenDownloads: { router.push(.downloads) }
            )
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                ShelfSelectionBar(
                    selectedCount: selectedIDs.count,
                    isDownloadedFilter: selectedFilter == .downloaded,
                    onDownload: { Task { await batchDownloadSelected() } },
                    onPin: { Task { await batchTogglePinSelected() } },
                    onRemove: { handleBatchRemoveTap() }
                )
            }
        }
        .alert(
            selectedFilter == .downloaded ? "删除离线音频" : "移出书架",
            isPresented: Binding(
                get: { pendingRemoveBook != nil },
                set: { if !$0 { pendingRemoveBook = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingRemoveBook = nil }
            Button(selectedFilter == .downloaded ? "删除离线章节" : "移出书架", role: .destructive) {
                if let target = pendingRemoveBook {
                    Task {
                        if selectedFilter == .downloaded {
                            await downloads.deleteBookDownloads(bookID: target.id)
                            banner.show("已删除《\(target.book.title)》全部离线章节", tone: .info)
                            await reloadShelf()
                        } else {
                            await removeFromShelf(target)
                        }
                    }
                }
                pendingRemoveBook = nil
            }
        } message: {
            Text(
                selectedFilter == .downloaded
                    ? "仅删除本地离线音频文件，不会移除您的书架收藏与收听进度。"
                    : "移出书架不会清除收听历史或已下载的本地音频。"
            )
        }
        .alert(
            selectedFilter == .downloaded ? "批量删除离线音频" : "批量移出书架",
            isPresented: Binding(
                get: { !pendingBatchDeleteItems.isEmpty },
                set: { if !$0 { pendingBatchDeleteItems.removeAll() } }
            )
        ) {
            Button("取消", role: .cancel) { pendingBatchDeleteItems.removeAll() }
            Button("确认", role: .destructive) {
                let targets = pendingBatchDeleteItems
                pendingBatchDeleteItems.removeAll()
                Task { await executeBatchRemove(targets) }
            }
        } message: {
            Text(
                selectedFilter == .downloaded
                    ? "确认删除所选 \(pendingBatchDeleteItems.count) 本书的离线音频？不会影响书架与进度。"
                    : "确定将已选的 \(pendingBatchDeleteItems.count) 本书移出书架？此操作不会清除收听历史或本地离线音频。"
            )
        }
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await reloadShelf() }
        }
        .onChange(of: downloads.completedRevision) { _, _ in
            Task { await reloadShelf() }
        }
        .onChange(of: router.selectedTab) { _, tab in
            if tab == .library { Task { await reloadShelf() } }
        }
        .onChange(of: playback.currentBook?.id) { _, _ in
            if router.selectedTab == .library {
                Task { await reloadShelf() }
            }
        }
        .onChange(of: playback.currentChapterIndex) { _, _ in
            if router.selectedTab == .library {
                Task { await reloadShelf() }
            }
        }
        .task { await reloadShelf() }
        .refreshable { await reloadShelf() }
        .onDisappear {
            if isEditing { isEditing = false }
            if !selectedIDs.isEmpty { selectedIDs.removeAll() }
            router.isBottomBarHidden = false
        }
    }

    @ViewBuilder
    private func downloadedFilterStatusCard(overview: DownloadedShelfOverview) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已下载书籍 · \(overview.bookCount) 本")
                        .font(DSTypography.rowTitle)
                    Text("共 \(overview.completedChapters) 章离线音频 · 占用 \(overview.formattedBytes)")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
                Spacer()
                Button {
                    router.push(.downloads)
                } label: {
                    Text("管理队列")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DSColors.surfaceGrouped))
                }
                .buttonStyle(.plain)
            }
            if overview.activeChapters > 0 {
                HStack(spacing: DSSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在下载 \(overview.activeChapters) 章…")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkPrimary)
                    Spacer()
                }
            }
            if overview.failedChapters > 0 {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DSColors.danger)
                    Text("\(overview.failedChapters) 章下载失败")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.danger)
                    Spacer()
                    Button("全部重试") {
                        Task { await downloads.resumeAll() }
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(DSColors.surfaceCard))
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    @ViewBuilder
    private var mainShelfContent: some View {
        if displayedItems.isEmpty && !isLoading {
            if selectedFilter == .downloaded {
                DSStateView(
                    kind: .empty,
                    titleOverride: "暂无已下载书籍",
                    messageOverride: "在书籍详情页点击下载章节后，即可在此离线收听与管理",
                    primaryTitleOverride: "返回全部书架",
                    secondaryTitleOverride: "去首页",
                    onPrimary: { selectedFilter = .all },
                    onSecondary: { router.selectTab(.discover) }
                )
            } else if shelfItems.isEmpty {
                DSStateView(
                    kind: .empty,
                    titleOverride: "书架还是空的",
                    messageOverride: "去首页逛逛或搜索想听的有声书",
                    primaryTitleOverride: "去首页",
                    secondaryTitleOverride: "去搜索",
                    onPrimary: { router.selectTab(.discover) },
                    onSecondary: { router.openSearch() }
                )
            } else {
                DSStateView(
                    kind: .empty,
                    titleOverride: "当前筛选下暂无书籍",
                    messageOverride: "试试切换回全部书架查看",
                    primaryTitleOverride: "查看全部",
                    onPrimary: { selectedFilter = .all },
                    onSecondary: nil
                )
            }
        } else {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                if settings.shelfLayout == .list || selectedFilter == .downloaded {
                    ShelfList(
                        items: displayedItems,
                        playingBookID: playback.currentBook?.id,
                        isEnginePlaying: playback.state.isPlaying,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        isDownloadedFilter: selectedFilter == .downloaded,
                        pipeline: container.coverPipeline,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { item in Task { await playBookImmediately(item) } },
                        onTogglePin: { item in Task { await togglePin(item) } },
                        onDownloadUnread: { item in Task { await downloadUnread(item) } },
                        onRemove: { pendingRemoveBook = $0 }
                    )
                } else {
                    ShelfGrid(
                        items: displayedItems,
                        playingBookID: playback.currentBook?.id,
                        isEnginePlaying: playback.state.isPlaying,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        pipeline: container.coverPipeline,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { item in Task { await playBookImmediately(item) } },
                        onTogglePin: { item in Task { await togglePin(item) } },
                        onDownloadUnread: { item in Task { await downloadUnread(item) } },
                        onRemove: { pendingRemoveBook = $0 }
                    )
                }
            }
        }
    }
}
