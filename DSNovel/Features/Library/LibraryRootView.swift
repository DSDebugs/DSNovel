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
    @State private var pendingBatchDeleteDownloadBooks: [Book] = []

    init() {}

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    private func batchDeleteDownloadSummaryTitle() -> String {
        let books = pendingBatchDeleteDownloadBooks
        var totalChapters = 0
        var totalBytes: Int64 = 0
        for b in books {
            if let sum = downloadManager.summariesByBookID[b.id] {
                totalChapters += sum.completedCount
                totalBytes += sum.totalBytes
            }
        }
        if totalChapters > 0 {
            return "确认删除所选 \(books.count) 本书的 \(totalChapters) 章离线音频（\(formatBytes(totalBytes))）？"
        }
        return "确认删除所选 \(books.count) 本书的离线音频？"
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let dlOverview = LibraryCardMapper.computeDownloadedOverview(from: downloadManager)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sectionVertical) {
                    Color.clear.frame(height: 0).id("libraryTop")

                    if !isEditing, let cont = libraryStore.continueBook {
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
        .onChange(of: libraryStore.selectedFilter) { _, _ in
            selectedIDs.removeAll()
        }
        .toolbar {
            ShelfToolbar(
                isEditing: isEditing,
                allSelected: !libraryStore.shelfBooks.isEmpty && selectedIDs.count == libraryStore.shelfBooks.count,
                isShelfEmpty: libraryStore.shelfBooks.isEmpty,
                isDownloadedFilter: libraryStore.selectedFilter == .downloaded,
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
                    isDownloadedFilter: libraryStore.selectedFilter == .downloaded,
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
        .alert(
            batchDeleteDownloadSummaryTitle(),
            isPresented: Binding(
                get: { !pendingBatchDeleteDownloadBooks.isEmpty },
                set: { if !$0 { pendingBatchDeleteDownloadBooks.removeAll() } }
            )
        ) {
            Button("删除离线音频", role: .destructive) {
                let targets = pendingBatchDeleteDownloadBooks
                pendingBatchDeleteDownloadBooks.removeAll()
                isEditing = false
                selectedIDs.removeAll()
                guard !targets.isEmpty else { return }
                DSHapticPolicy.fire(.warning)
                for book in targets {
                    downloadManager.removeDownloads(forBookID: book.id)
                }
                libraryStore.recomputeDerived()
                BannerCenter.shared.show("已删除 \(targets.count) 本书的离线音频", kind: .info, bypassDeduplication: true)
            }
            Button("取消", role: .cancel) {
                pendingBatchDeleteDownloadBooks.removeAll()
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
                isEditing = false
            }
            if !selectedIDs.isEmpty {
                selectedIDs.removeAll()
            }
            AppRouter.shared.isBottomBarHidden = false
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
        let offlineBookCount = max(dlOverview.bookCount, libraryStore.filterCounts[.downloaded] ?? 0)
        if sourceStore.allSources.isEmpty && !(libraryStore.selectedFilter == .downloaded && !libraryStore.shelfBooks.isEmpty) {
            VStack(spacing: Spacing.s4) {
                if offlineBookCount > 0 {
                    Button {
                        libraryStore.selectedFilter = .downloaded
                    } label: {
                        HStack(spacing: Spacing.s3) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.dsAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本地仍有 \(offlineBookCount) 本已下载书籍")
                                    .font(DSTypography.rowTitle)
                                    .foregroundStyle(.primary)
                                Text("无需书源即可继续离线收听与管理")
                                    .font(DSTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("查看离线")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(Color.dsOnAccent)
                                .padding(.horizontal, Spacing.s3)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.dsAccent))
                        }
                        .padding(Spacing.s3)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .fill(Color.dsSurfaceCard)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.pageHorizontal)
                }
                DSStateView(
                    kind: .noSource,
                    onPrimary: { AppRouter.shared.open(.sourceImport) },
                    onSecondary: { AppRouter.shared.open(.sourceList) }
                )
            }
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
        guard let book = libraryStore.ensurePersistedBook(for: id, fallbackContext: modelContext) else { return }
        book.isPinned.toggle()
        try? modelContext.save()
        libraryStore.refreshNow()
    }

    private func downloadUnread(_ id: String) {
        guard let book = libraryStore.book(for: id, fallbackContext: modelContext)
            ?? libraryStore.shelfBooks.first(where: { $0.id == id }) else { return }
        let bookID = book.id
        let bookTitle = book.title
        let bookRef = book.bookRef
        let lastChapterIndex = book.lastChapterIndex
        Task {
            guard let chapters = await ChapterCacheStore.loadChaptersAsync(for: bookID), !chapters.isEmpty else {
                BannerCenter.shared.show("请先进入书籍详情加载章节目录", kind: .info)
                return
            }
            let unread = LibraryCardMapper.unreadChapters(from: chapters, lastChapterIndex: lastChapterIndex)
            guard !unread.isEmpty else {
                BannerCenter.shared.show("《\(bookTitle)》暂无未听章节", kind: .info)
                return
            }
            DownloadManager.shared.enqueueChapters(unread, for: bookRef, kind: "manual")
            BannerCenter.shared.show("已加入下载 \(unread.count) 章未听章节", kind: .success)
        }
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
        let targets: [(id: String, ref: BookRef, lastChapterIndex: Int)] = LibraryCardMapper
            .filterShelfBooks(libraryStore.shelfBooks, selectedIDs: selectedIDs)
            .map { ($0.id, $0.bookRef, $0.lastChapterIndex) }
        isEditing = false
        selectedIDs.removeAll()
        guard !targets.isEmpty else { return }

        Task {
            var enqueuedBooks = 0
            var enqueuedChapters = 0
            for target in targets {
                if let chs = await ChapterCacheStore.loadChaptersAsync(for: target.id), !chs.isEmpty {
                    let unread = LibraryCardMapper.unreadChapters(from: chs, lastChapterIndex: target.lastChapterIndex)
                    let toEnqueue = unread.isEmpty ? chs : unread
                    DownloadManager.shared.enqueueChapters(toEnqueue, for: target.ref, kind: "manual")
                    enqueuedBooks += 1
                    enqueuedChapters += toEnqueue.count
                }
            }
            if enqueuedChapters > 0 {
                BannerCenter.shared.show("已将 \(enqueuedBooks) 本书共 \(enqueuedChapters) 章加入下载队列", kind: .success)
            } else {
                BannerCenter.shared.show("所选书籍暂无目录缓存，请先打开书籍详情", kind: .info)
            }
        }
    }

    private func batchTogglePinSelected() {
        let targetIDs = LibraryCardMapper
            .filterShelfBooks(libraryStore.shelfBooks, selectedIDs: selectedIDs)
            .map(\.id)
        for id in targetIDs {
            if let managed = libraryStore.ensurePersistedBook(for: id, fallbackContext: modelContext) {
                managed.isPinned.toggle()
            }
        }
        try? modelContext.save()
        isEditing = false
        selectedIDs.removeAll()
        libraryStore.refreshNow()
    }

    private func batchRemoveSelected() {
        let targets = LibraryCardMapper.filterShelfBooks(libraryStore.shelfBooks, selectedIDs: selectedIDs)
        guard !targets.isEmpty else {
            isEditing = false
            selectedIDs.removeAll()
            return
        }
        if libraryStore.selectedFilter == .downloaded {
            pendingBatchDeleteDownloadBooks = targets
        } else {
            isEditing = false
            selectedIDs.removeAll()
            DSHapticPolicy.fire(.warning)
            libraryStore.removeFromShelfDeferred(targets)
        }
    }
}
