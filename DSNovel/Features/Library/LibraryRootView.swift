import SwiftUI
import SwiftData

struct LibraryRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var settings = AppSettingsStore.shared
    @State private var player = PlayerEngine.shared
    @State private var downloadManager = DownloadManager.shared

    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var pendingDeleteDownloadBook: Book?

    init() {}

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let dlOverview = LibraryCardMapper.computeDownloadedOverview(from: downloadManager)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sectionVertical) {
                    Color.clear.frame(height: 0).id("libraryTop")

                    if let cont = libraryStore.continueBook {
                        ContinueSection(
                            continueModel: LibraryCardMapper.makeModel(from: cont, sourceStore: sourceStore, player: player),
                            recentModels: libraryStore.recentBooks.map {
                                LibraryCardMapper.makeModel(from: $0, sourceStore: sourceStore, player: player)
                            },
                            onOpenBook: { id in openBookByID(id) },
                            onTogglePlay: {
                                DSHapticPolicy.fire(.playPause)
                                LibraryCardMapper.playBookImmediately(cont, player: player)
                            },
                            onOpenHistory: { AppRouter.shared.open(.history) }
                        )
                    }

                    DSChipBar(
                        items: LibraryCardMapper.makeFilterChips(from: libraryStore),
                        selection: $libraryStore.selectedFilter
                    )

                    if libraryStore.selectedFilter == .downloaded {
                        downloadedFilterStatusCard(overview: dlOverview)
                    }

                    mainShelfContent(dlOverview: dlOverview)
                }
                .padding(.vertical, Spacing.s3)
            }
            .onChange(of: ScrollToTopCenter.shared.count(for: .library)) { _, _ in
                withAnimation(Motion.snappy) {
                    proxy.scrollTo("libraryTop", anchor: .top)
                }
            }
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle(isEditing ? "已选 \(selectedIDs.count) 项" : "书籍")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isEditing) { _, hidden in AppRouter.shared.isBottomBarHidden = hidden }
        .toolbar {
            ShelfToolbar(
                isEditing: isEditing,
                allSelected: !libraryStore.shelfBooks.isEmpty && selectedIDs.count == libraryStore.shelfBooks.count,
                sortOrder: $libraryStore.sortOrder,
                layoutStyle: $settings.shelfLayout,
                onToggleEdit: {
                    isEditing.toggle()
                    if !isEditing { selectedIDs.removeAll() }
                },
                onToggleSelectAll: {
                    if selectedIDs.count == libraryStore.shelfBooks.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(libraryStore.shelfBooks.map(\.id))
                    }
                },
                onOpenHistory: { AppRouter.shared.open(.history) },
                onOpenDownloads: { AppRouter.shared.open(.downloads) }
            )
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                ShelfSelectionBar(
                    selectedCount: selectedIDs.count,
                    onDownload: { batchDownloadSelected() },
                    onPin: { batchTogglePinSelected() },
                    onRemove: { batchRemoveSelected() }
                )
            }
        }
        .refreshable {
            let count = await libraryStore.checkUpdates()
            BannerCenter.shared.show(count > 0 ? "\(count) 本有新章节" : "已是最新章节", kind: .info)
        }
        .alert(
            pendingDeleteDownloadBook.map { book in
                let sum = downloadManager.summariesByBookID[book.id]
                let count = sum?.completedCount ?? 0
                let sizeStr = formatBytes(sum?.totalBytes ?? 0)
                return "确认删除《\(book.title)》的 \(count) 章已下载音频（\(sizeStr)）？"
            } ?? "确认删除该书离线音频？",
            isPresented: Binding(
                get: { pendingDeleteDownloadBook != nil },
                set: { if !$0 { pendingDeleteDownloadBook = nil } }
            )
        ) {
            Button("删除离线章节", role: .destructive) {
                if let target = pendingDeleteDownloadBook {
                    DSHapticPolicy.fire(.warning)
                    downloadManager.removeDownloads(forBookID: target.id)
                    libraryStore.recomputeDerived()
                    BannerCenter.shared.show("已删除《\(target.title)》全部离线章节", kind: .info, bypassDeduplication: true)
                }
                pendingDeleteDownloadBook = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteDownloadBook = nil
            }
        } message: {
            Text("仅删除本地离线音频文件，不会移除您的书架收藏与收听进度。")
        }
        .onAppear {
            libraryStore.modelContext = modelContext
            sourceStore.modelContext = modelContext
            downloadManager.modelContext = modelContext
            downloadManager.reconcileCompletedFilesIfNeeded()
        }
        .onDisappear {
            if isEditing {
                AppRouter.shared.isBottomBarHidden = false
            }
        }
    }

    @ViewBuilder
    private func downloadedFilterStatusCard(overview: DownloadedBooksOverview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已下载书籍 · \(overview.bookCount) 本")
                        .font(DSTypography.rowTitle)
                    Text("共 \(overview.completedChapters) 章离线音频 · 占用 \(overview.formattedBytes) · 点击书籍优先展示已下载章节")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    AppRouter.shared.open(.downloads)
                } label: {
                    Text("管理队列")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.dsSurfaceGrouped))
                }
                .buttonStyle(.plain)
            }

            if overview.activeChapters > 0 {
                HStack(spacing: Spacing.s2) {
                    ProgressView().controlSize(.small)
                    Text("正在下载 \(overview.activeChapters) 章…")
                        .font(DSTypography.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }

            if overview.failedChapters > 0 {
                HStack(spacing: Spacing.s2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("\(overview.failedChapters) 章下载失败")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer()
                    Button("全部重试") {
                        downloadManager.retryAllFailed()
                        BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ViewBuilder
    private func mainShelfContent(dlOverview: DownloadedBooksOverview) -> some View {
        if sourceStore.allSources.isEmpty {
            DSStateView(
                kind: .noSource,
                onPrimary: { AppRouter.shared.open(.sourceImport) },
                onSecondary: { AppRouter.shared.open(.sourceList) }
            )
        } else if libraryStore.selectedFilter == .downloaded && libraryStore.shelfBooks.isEmpty {
            VStack(spacing: Spacing.s3) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("暂无已下载书籍")
                    .font(DSTypography.rowTitle)
                Text("在书籍详情页点击下载章节后，即可在此离线收听与管理")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: Spacing.s3) {
                    Button {
                        libraryStore.selectedFilter = .all
                    } label: {
                        Text("返回全部书架")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(Color.dsOnAccent)
                            .padding(.horizontal, Spacing.s4)
                            .padding(.vertical, Spacing.s2)
                            .background(Capsule().fill(Color.dsAccent))
                    }
                    .buttonStyle(.plain)

                    Button {
                        AppRouter.shared.selectedTab = .discover
                    } label: {
                        Text("去发现页")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Spacing.s4)
                            .padding(.vertical, Spacing.s2)
                            .background(Capsule().fill(Color.dsSurfaceGrouped))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.s6)
            .frame(maxWidth: .infinity)
        } else if libraryStore.allShelfBooks.isEmpty && libraryStore.continueBook == nil && libraryStore.shelfBooks.isEmpty {
            DSStateView(
                kind: .empty,
                titleOverride: "书架还是空的",
                messageOverride: "去发现页逛逛或搜索想听的有声书",
                primaryTitleOverride: "去发现",
                secondaryTitleOverride: "去搜索",
                onPrimary: { AppRouter.shared.selectedTab = .discover },
                onSecondary: { AppRouter.shared.selectedTab = .search }
            )
        } else if libraryStore.allShelfBooks.isEmpty && libraryStore.continueBook != nil && libraryStore.selectedFilter == .all {
            VStack(spacing: Spacing.s3) {
                Text("听过的书加入书架即可长期保存")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.secondary)
                DSActionButton(title: "全部加入", icon: "plus.circle.fill", role: .secondary) {
                    LibraryCardMapper.addAllRecentToShelf(store: libraryStore, context: modelContext)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.s6)
        } else if libraryStore.shelfBooks.isEmpty {
            DSStateView(
                kind: .empty,
                titleOverride: "当前筛选下暂无书籍",
                messageOverride: "试试切换回全部书架查看",
                primaryTitleOverride: "查看全部",
                onPrimary: { libraryStore.selectedFilter = .all },
                onSecondary: nil
            )
        } else {
            let models = libraryStore.shelfBooks.map {
                LibraryCardMapper.makeModel(from: $0, sourceStore: sourceStore, player: player)
            }
            let sectionTitle = libraryStore.selectedFilter == .downloaded ? "已下载书籍" : "我的书架"
            VStack(alignment: .leading, spacing: Spacing.s3) {
                DSSectionHeader(title: sectionTitle, subtitle: "\(models.count) 本")
                if settings.shelfLayout == .list || libraryStore.selectedFilter == .downloaded {
                    ShelfList(
                        models: models,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        isDownloadedFilter: libraryStore.selectedFilter == .downloaded,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { playByModel($0) },
                        onTogglePin: { togglePin($0.id) },
                        onDownloadUnread: { downloadUnread($0.id) },
                        onRemove: { handleRemoveAction($0.id) }
                    )
                } else {
                    ShelfGrid(
                        models: models,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { playByModel($0) },
                        onTogglePin: { togglePin($0.id) },
                        onDownloadUnread: { downloadUnread($0.id) },
                        onRemove: { handleRemoveAction($0.id) }
                    )
                }
            }
        }
    }

    private func handleCardTap(_ model: BookCardModel) {
        if isEditing {
            if selectedIDs.contains(model.id) {
                selectedIDs.remove(model.id)
            } else {
                selectedIDs.insert(model.id)
            }
        } else {
            openBookByID(model.id)
        }
    }

    private func openBookByID(_ id: String) {
        let preferDL = (libraryStore.selectedFilter == .downloaded)
            || ((downloadManager.summariesByBookID[id]?.completedCount ?? 0) > 0)
        if let book = libraryStore.book(for: id, fallbackContext: modelContext)
            ?? libraryStore.shelfBooks.first(where: { $0.id == id }) {
            libraryStore.markUpdateRead(bookID: book.id)
            AppRouter.shared.open(.book(book.bookRef, preferDownloaded: preferDL))
        }
    }

    private func playByModel(_ model: BookCardModel) {
        if let book = libraryStore.book(for: model.id, fallbackContext: modelContext)
            ?? libraryStore.shelfBooks.first(where: { $0.id == model.id }) {
            DSHapticPolicy.fire(.playPause)
            LibraryCardMapper.playBookImmediately(book, player: player)
        }
    }

    private func togglePin(_ id: String) {
        guard let book = libraryStore.book(for: id, fallbackContext: modelContext) else { return }
        book.isPinned.toggle()
        try? modelContext.save()
        libraryStore.refreshNow()
    }

    private func downloadUnread(_ id: String) {
        guard let book = libraryStore.book(for: id, fallbackContext: modelContext) else { return }
        guard let chapters = ChapterCacheStore.loadChapters(for: book.id), !chapters.isEmpty else {
            BannerCenter.shared.show("请先进入书籍详情加载章节目录", kind: .info)
            return
        }
        let unread = LibraryCardMapper.unreadChapters(from: chapters, lastChapterIndex: book.lastChapterIndex)
        guard !unread.isEmpty else {
            BannerCenter.shared.show("《\(book.title)》暂无未听章节", kind: .info)
            return
        }
        DownloadManager.shared.enqueueChapters(unread, for: book.bookRef, kind: "manual")
        BannerCenter.shared.show("已加入下载 \(unread.count) 章未听章节", kind: .success)
    }

    private func handleRemoveAction(_ id: String) {
        guard let book = libraryStore.book(for: id, fallbackContext: modelContext)
            ?? libraryStore.shelfBooks.first(where: { $0.id == id }) else { return }
        if libraryStore.selectedFilter == .downloaded {
            pendingDeleteDownloadBook = book
        } else {
            DSHapticPolicy.fire(.warning)
            libraryStore.removeFromShelfDeferred([book])
        }
    }

    private func batchDownloadSelected() {
        var enqueuedBooks = 0
        var enqueuedChapters = 0
        for book in libraryStore.allShelfBooks where selectedIDs.contains(book.id) {
            if let chs = ChapterCacheStore.loadChapters(for: book.id), !chs.isEmpty {
                let unread = LibraryCardMapper.unreadChapters(from: chs, lastChapterIndex: book.lastChapterIndex)
                let target = unread.isEmpty ? chs : unread
                DownloadManager.shared.enqueueChapters(target, for: book.bookRef, kind: "manual")
                enqueuedBooks += 1
                enqueuedChapters += target.count
            }
        }
        isEditing = false
        selectedIDs.removeAll()
        if enqueuedChapters > 0 {
            BannerCenter.shared.show("已将 \(enqueuedBooks) 本书共 \(enqueuedChapters) 章加入下载队列", kind: .success)
        } else {
            BannerCenter.shared.show("所选书籍暂无目录缓存，请先打开书籍详情", kind: .info)
        }
    }

    private func batchTogglePinSelected() {
        for book in libraryStore.allShelfBooks where selectedIDs.contains(book.id) {
            book.isPinned.toggle()
        }
        try? modelContext.save()
        isEditing = false
        selectedIDs.removeAll()
        libraryStore.refreshNow()
    }

    private func batchRemoveSelected() {
        let targets = LibraryCardMapper.filterShelfBooks(libraryStore.allShelfBooks, selectedIDs: selectedIDs)
        isEditing = false
        selectedIDs.removeAll()
        DSHapticPolicy.fire(.warning)
        libraryStore.removeFromShelfDeferred(targets)
    }
}
