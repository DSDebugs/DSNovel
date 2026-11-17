import SwiftUI
import SwiftData

/// 书架与最近播放及已下载聚合页：
/// 1. 左对齐大字号三栏沉浸顶栏：「书架 · 最近播放 · 已下载」（已完整去除书签）+ 右侧旋转刷新与更多管理菜单；
/// 2. 「书架」下展示「全部 N」+ 各自定义分类计数胶囊 + 显式「+ 新建分类」描边胶囊；
/// 3. 书籍卡片统一采用高辨识度三行布局（书名 / 演播·书源 / 主题色高亮 `第 X/Y 集 · mm:ss`）+ 右侧主题色圆形播放键；
/// 4. 「已下载」标签页按书籍聚合展示离线占用空间（MB）、已下载集数与一键清理按钮。
struct ShelfView: View {
    let onSwitchToDiscover: () -> Void
    let onSwitchToSearch: () -> Void
    let onSelectBook: (BookRef) -> Void
    let onOpenDownloads: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Book.addedAt, order: .reverse)]) private var books: [Book]
    @Query(sort: [SortDescriptor(\ShelfCategory.order)]) private var categories: [ShelfCategory]
    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\DownloadItem.createdAt, order: .reverse)]) private var downloadItems: [DownloadItem]

    init(
        onSwitchToDiscover: @escaping () -> Void,
        onSwitchToSearch: @escaping () -> Void = {},
        onSelectBook: @escaping (BookRef) -> Void,
        onOpenDownloads: @escaping () -> Void
    ) {
        self.onSwitchToDiscover = onSwitchToDiscover
        self.onSwitchToSearch = onSwitchToSearch
        self.onSelectBook = onSelectBook
        self.onOpenDownloads = onOpenDownloads
    }

    @State private var sectionMode: ShelfSectionMode = .shelf
    @State private var selectedCategoryID: String? = nil
    @State private var isEditingSelection = false
    @State private var selectedBookIDs: Set<String> = []
    @State private var isRefreshingShelf = false
    @State private var showCategoryManageSheet = false
    @State private var showNewCategoryAlert = false
    @State private var newCategoryName = ""
    @State private var showMoveCategoryDialog = false
    @State private var showClearRecentConfirm = false
    @State private var pendingDeleteDownloadBook: DownloadedBookSummary?

    private var player = PlayerEngine.shared
    private var settings = AppSettingsStore.shared

    private var sourceNameByID: [String: String] {
        Dictionary(plugins.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private var bookByID: [String: Book] {
        Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 严格仅包含用户主动加入书架的书籍
    private var shelfBooks: [Book] {
        books.filter(\.inShelf)
    }

    /// 所有产生过播放记录的书籍（按最后播放时间倒序）
    private var recentBooks: [Book] {
        books
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    private var filteredShelfBooks: [Book] {
        let base = shelfBooks.filter { book in
            guard let catID = selectedCategoryID else { return true }
            return book.categoryID == catID
        }
        return base.sorted { a, b in
            if a.isPinned != b.isPinned {
                return a.isPinned && !b.isPinned
            }
            switch settings.shelfSort {
            case .lastPlayed:
                return (a.lastPlayedAt ?? a.addedAt) > (b.lastPlayedAt ?? b.addedAt)
            case .addedAt:
                return a.addedAt > b.addedAt
            case .title:
                return a.title.localizedCompare(b.title) == .orderedAscending
            }
        }
    }

    /// 按书籍聚合的手动离线下载汇总
    private struct DownloadedBookSummary: Identifiable {
        var id: String { bookID }
        let bookID: String
        let bookTitle: String
        let sourceID: String
        let completedCount: Int
        let pendingCount: Int
        let failedCount: Int
        let totalBytes: Int64
        let latestAt: Date
    }

    private var manualDownloads: [DownloadItem] {
        downloadItems.filter { $0.kind == "manual" }
    }

    private var downloadedBookSummaries: [DownloadedBookSummary] {
        let grouped = Dictionary(grouping: manualDownloads, by: \.bookID)
        return grouped.map { bookID, items in
            let completed = items.filter { $0.state == "completed" }
            let pending = items.filter { $0.state == "queued" || $0.state == "downloading" }
            let failed = items.filter { $0.state == "failed" }
            let bytes = completed.reduce(Int64(0)) { $0 + $1.bytes }
            let latest = items.map(\.createdAt).max() ?? .distantPast
            return DownloadedBookSummary(
                bookID: bookID,
                bookTitle: items.first?.bookTitle ?? bookByID[bookID]?.title ?? "未知书籍",
                sourceID: items.first?.sourceID ?? bookByID[bookID]?.sourceID ?? "",
                completedCount: completed.count,
                pendingCount: pending.count,
                failedCount: failed.count,
                totalBytes: bytes,
                latestAt: latest
            )
        }
        .sorted { $0.latestAt > $1.latestAt }
    }

    private var totalManualDownloadBytes: Int64 {
        manualDownloads.filter { $0.state == "completed" }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                shelfTopHeaderBar

                Group {
                    switch sectionMode {
                    case .shelf:
                        shelfPrimaryContent
                    case .recent:
                        recentPlayedPrimaryContent
                    case .downloaded:
                        downloadedPrimaryContent
                    }
                }
            }
            .background(DSColor.contentBackground)

            // 书架编辑模式下的底部操作栏
            if sectionMode == .shelf && isEditingSelection && !selectedBookIDs.isEmpty {
                shelfEditingFloatingBar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: sectionMode) { _, _ in
            if isEditingSelection {
                isEditingSelection = false
                selectedBookIDs.removeAll()
            }
        }
        .onChange(of: isEditingSelection) { _, editing in
            BottomDockController.shared.isSuppressedByEditing = (editing && sectionMode == .shelf)
        }
        .onDisappear {
            BottomDockController.shared.isSuppressedByEditing = false
        }
        .task {
            backfillMissingChapterCountsIfNeeded()
        }
        .onAppear {
            backfillMissingChapterCountsIfNeeded()
        }
        .onChange(of: books.count) { _, _ in
            backfillMissingChapterCountsIfNeeded()
        }
        .alert("新建分类", isPresented: $showNewCategoryAlert) {
            TextField("输入分类名称", text: $newCategoryName)
            Button("取消", role: .cancel) { newCategoryName = "" }
            Button("创建") {
                createNewCategory()
            }
        }
        .confirmationDialog("移动选中书籍到分类", isPresented: $showMoveCategoryDialog) {
            Button("全部（取消分类）") {
                moveSelectedBooks(to: nil)
            }
            ForEach(categories) { cat in
                Button(cat.name) {
                    moveSelectedBooks(to: cat.id)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确定清空全部最近播放记录？", isPresented: $showClearRecentConfirm, titleVisibility: .visible) {
            Button("清空最近播放（不影响书架收藏）", role: .destructive) {
                clearAllRecentHistory()
            }
            Button("取消", role: .cancel) {}
        }
        .alert("删除离线缓存", isPresented: Binding(
            get: { pendingDeleteDownloadBook != nil },
            set: { if !$0 { pendingDeleteDownloadBook = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeleteDownloadBook = nil }
            Button("删除", role: .destructive) {
                if let target = pendingDeleteDownloadBook {
                    DownloadManager.shared.removeDownloads(forBookID: target.bookID)
                    ToastManager.shared.show("已清理「\(target.bookTitle)」离线音频")
                }
                pendingDeleteDownloadBook = nil
            }
        } message: {
            Text("确认删除「\(pendingDeleteDownloadBook?.bookTitle ?? "")」的全部离线下载音频文件吗？")
        }
        .sheet(isPresented: $showCategoryManageSheet) {
            CategoryManageSheet()
        }
    }

    // MARK: - 1. 顶部左对齐大字号三栏导航（书架 · 最近播放 · 已下载）

    private var shelfTopHeaderBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            ForEach(ShelfSectionMode.allCases) { mode in
                let isSelected = sectionMode == mode
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        sectionMode = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: isSelected ? 24 : 17, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            Menu {
                if sectionMode == .shelf && !shelfBooks.isEmpty {
                    Picker("排序方式", selection: Bindable(settings).shelfSort) {
                        ForEach(ShelfSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }

                    Button {
                        settings.shelfLayout = settings.shelfLayout == .grid ? .list : .grid
                    } label: {
                        Label(settings.shelfLayout == .grid ? "切换为列表视图" : "切换为网格视图",
                              systemImage: settings.shelfLayout == .grid ? "list.bullet" : "square.grid.2x2")
                    }

                    Button {
                        isEditingSelection.toggle()
                        selectedBookIDs.removeAll()
                    } label: {
                        Label(isEditingSelection ? "完成批量管理" : "批量管理书架", systemImage: "checkmark.circle")
                    }

                    Button {
                        showCategoryManageSheet = true
                    } label: {
                        Label("管理分类", systemImage: "folder.badge.gearshape")
                    }
                } else if sectionMode == .recent && !recentBooks.isEmpty {
                    Button(role: .destructive) {
                        showClearRecentConfirm = true
                    } label: {
                        Label("清空最近播放", systemImage: "trash")
                    }
                }

                Button {
                    onOpenDownloads()
                } label: {
                    Label("详细下载队列", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")

            Button {
                Task { await refreshCurrentSection() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .rotationEffect(.degrees(isRefreshingShelf ? 360 : 0))
                    .animation(
                        isRefreshingShelf
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshingShelf
                    )
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新")
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 2. 「书架」视图（分组胶囊 + 三行信息卡片 + 右侧圆形播放键）

    @ViewBuilder
    private var shelfPrimaryContent: some View {
        VStack(spacing: 0) {
            categoryCapsuleStrip

            if shelfBooks.isEmpty {
                ContentUnavailableView {
                    Label("书架还是空的", systemImage: "books.vertical")
                } description: {
                    Text("在书籍详情页点击右上角收藏心形或「加入书架」，即可在此分类管理并同步播放集数进度")
                } actions: {
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Button("去发现页") {
                                onSwitchToDiscover()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("去搜索书籍") {
                                onSwitchToSearch()
                            }
                            .buttonStyle(.bordered)
                        }

                        if !recentBooks.isEmpty {
                            Button("查看最近播放记录 (\(recentBooks.count))") {
                                sectionMode = .recent
                            }
                            .font(.footnote.weight(.medium))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredShelfBooks.isEmpty {
                ContentUnavailableView {
                    Label("该分类下暂无书籍", systemImage: "folder")
                } description: {
                    Text("长按任意书架书籍选择「移动到分类」，即可归类到当前分组")
                } actions: {
                    Button("查看全部书架") {
                        selectedCategoryID = nil
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                shelfCollectionBody
            }
        }
    }

    private var categoryCapsuleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                let allSelected = selectedCategoryID == nil
                Button {
                    selectedCategoryID = nil
                } label: {
                    Text("全部 \(shelfBooks.count)")
                        .font(.system(size: 13, weight: allSelected ? .semibold : .regular))
                        .foregroundStyle(allSelected ? DSColor.primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(allSelected ? DSColor.primary.opacity(0.16) : Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    allSelected ? DSColor.primary.opacity(0.45) : Color.primary.opacity(0.16),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)

                ForEach(categories) { cat in
                    let isSelected = selectedCategoryID == cat.id
                    let catCount = shelfBooks.filter { $0.categoryID == cat.id }.count
                    Button {
                        selectedCategoryID = cat.id
                    } label: {
                        Text("\(cat.name) \(catCount)")
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? DSColor.primary : .secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? DSColor.primary.opacity(0.16) : Color.clear)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        isSelected ? DSColor.primary.opacity(0.45) : Color.primary.opacity(0.16),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            showCategoryManageSheet = true
                        } label: {
                            Label("管理/排序分类", systemImage: "folder.badge.gearshape")
                        }
                    }
                }

                // 显式「+ 新建分类」描边胶囊（对齐参考截图 4）
                Button {
                    newCategoryName = ""
                    showNewCategoryAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("新建分类")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var shelfCollectionBody: some View {
        if settings.shelfLayout == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], spacing: 18) {
                    ForEach(filteredShelfBooks) { book in
                        shelfGridItem(for: book)
                    }
                }
                .padding(DSSpacing.lg)
            }
            .dsAdaptiveBottomDockScroll()
        } else {
            List(filteredShelfBooks) { book in
                shelfThreeLineCard(for: book, showAddToShelfButton: false)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: DSSpacing.lg, bottom: 7, trailing: DSSpacing.lg))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeFromShelf(book)
                        } label: {
                            Label("移出书架", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .dsAdaptiveBottomDockScroll()
        }
    }

    // MARK: - 3. 「最近播放」视图

    @ViewBuilder
    private var recentPlayedPrimaryContent: some View {
        if recentBooks.isEmpty {
            ContentUnavailableView {
                Label("暂无最近播放记录", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("点击任意书籍章节开始收听后，这里会自动记录播至第几集与时间进度")
            } actions: {
                HStack(spacing: 12) {
                    Button("去发现页听书") {
                        onSwitchToDiscover()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("去搜索书籍") {
                        onSwitchToSearch()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(recentBooks) { book in
                    shelfThreeLineCard(for: book, showAddToShelfButton: !book.inShelf)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 7, leading: DSSpacing.lg, bottom: 7, trailing: DSSpacing.lg))
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removeRecentHistory(book)
                            } label: {
                                Label("移除记录", systemImage: "trash")
                            }

                            if !book.inShelf {
                                Button {
                                    addBookToShelf(book)
                                } label: {
                                    Label("加入书架", systemImage: "plus.circle")
                                }
                                .tint(DSColor.primary)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .dsAdaptiveBottomDockScroll()
        }
    }

    // MARK: - 4. 「已下载」按书聚合视图（对齐参考截图 2）

    @ViewBuilder
    private var downloadedPrimaryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            let formattedSize = ByteCountFormatter.string(fromByteCount: totalManualDownloadBytes, countStyle: .file)
            Text("共占用 \(formattedSize) · 文件存在应用自己的目录里，卸载应用时会一起删除")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, 8)

            if downloadedBookSummaries.isEmpty {
                ContentUnavailableView {
                    Label("暂无已下载书籍", systemImage: "arrow.down.circle")
                } description: {
                    Text("在书籍详情页点击章节右侧下载箭头或「区间下载」，即可离线保存音频")
                } actions: {
                    Button("查看详细下载队列") {
                        onOpenDownloads()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(downloadedBookSummaries) { summary in
                        downloadedBookRow(summary)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 7, leading: DSSpacing.lg, bottom: 7, trailing: DSSpacing.lg))
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .dsAdaptiveBottomDockScroll()
            }
        }
    }

    private func downloadedBookRow(_ summary: DownloadedBookSummary) -> some View {
        let bookRecord = bookByID[summary.bookID]
        let sourceName = sourceNameByID[summary.sourceID] ?? summary.sourceID
        let sizeText = ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)

        return HStack(alignment: .center, spacing: 14) {
            CoverImageView(
                url: bookRecord?.cover ?? "",
                title: summary.bookTitle,
                width: 60,
                height: 80,
                cornerRadius: 7
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(summary.bookTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(sourceName.isEmpty ? "离线音频" : sourceName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("已下载 \(summary.completedCount) 集 · \(sizeText)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(DSColor.primary)

                    if summary.pendingCount > 0 {
                        Text("(\(summary.pendingCount) 集下载中)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if summary.failedCount > 0 {
                        Text("(\(summary.failedCount) 集失败)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                pendingDeleteDownloadBook = summary
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除本书离线下载")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if let existing = bookRecord {
                onSelectBook(existing.bookRef)
            } else {
                onOpenDownloads()
            }
        }
    }

    // MARK: - 5. 统一三行式书籍信息卡（对齐参考截图 3 / 图 4）

    private func shelfThreeLineCard(for book: Book, showAddToShelfButton: Bool) -> some View {
        let isThisPlaying = player.currentBookID == book.id && player.state == .playing
        let isSelected = selectedBookIDs.contains(book.id)
        let sourceName = sourceNameByID[book.sourceID] ?? book.sourceID

        return HStack(alignment: .center, spacing: 14) {
            CoverImageView(url: book.cover, title: book.title, width: 60, height: 80, cornerRadius: 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6)
                )

            VStack(alignment: .leading, spacing: 5) {
                // 第一行：书名
                HStack(spacing: 5) {
                    if book.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(DSColor.primary)
                    }
                    Text(book.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                // 第二行：演播名称 · 书源名称
                Text(book.authorAndSourceSubtitle(sourceName: sourceName))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // 第三行：第 X/Y 集 · mm:ss
                Text(book.episodeAndTimeProgressText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(book.lastPlayedAt != nil ? DSColor.primary : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isEditingSelection && sectionMode == .shelf {
                Button {
                    toggleSelection(for: book.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? DSColor.primary : .secondary)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    if showAddToShelfButton {
                        Button {
                            addBookToShelf(book)
                        } label: {
                            Text("+ 书架")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DSColor.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .strokeBorder(DSColor.primary.opacity(0.55), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        triggerQuickPlay(for: book)
                    } label: {
                        Circle()
                            .fill(DSColor.primary)
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: isThisPlaying ? 0 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isThisPlaying ? "暂停" : "继续播放")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditingSelection && sectionMode == .shelf {
                toggleSelection(for: book.id)
            } else {
                onSelectBook(book.bookRef)
            }
        }
        .contextMenu {
            bookContextMenu(for: book)
        }
    }

    private func shelfGridItem(for book: Book) -> some View {
        let isThisPlaying = player.currentBookID == book.id && player.state == .playing
        let isSelected = selectedBookIDs.contains(book.id)
        let sourceName = sourceNameByID[book.sourceID] ?? book.sourceID

        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                CoverImageView(url: book.cover, title: book.title, width: 104, height: 138, cornerRadius: 8)

                Button {
                    if isEditingSelection {
                        toggleSelection(for: book.id)
                    } else {
                        triggerQuickPlay(for: book)
                    }
                } label: {
                    Circle()
                        .fill(isEditingSelection ? (isSelected ? DSColor.primary : Color.gray) : DSColor.primary)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: isEditingSelection
                                  ? (isSelected ? "checkmark" : "circle")
                                  : (isThisPlaying ? "pause.fill" : "play.fill"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                }
                .buttonStyle(.plain)
                .padding(6)
            }

            Text(book.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(book.authorAndSourceSubtitle(sourceName: sourceName))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(book.episodeAndTimeProgressText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(DSColor.primary)
                .lineLimit(1)
        }
        .frame(width: 104, alignment: .leading)
        .onTapGesture {
            if isEditingSelection {
                toggleSelection(for: book.id)
            } else {
                onSelectBook(book.bookRef)
            }
        }
        .contextMenu {
            bookContextMenu(for: book)
        }
    }

    private var shelfEditingFloatingBar: some View {
        GlassFloatingBar {
            GlassButton {
                showMoveCategoryDialog = true
            } label: {
                Label("移动(\(selectedBookIDs.count))", systemImage: "folder")
                    .font(.subheadline.weight(.medium))
            }

            GlassButton {
                batchDownloadSelected()
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
            }

            GlassButton {
                batchDeleteSelected()
            } label: {
                Label("移出书架", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func bookContextMenu(for book: Book) -> some View {
        Button {
            triggerQuickPlay(for: book)
        } label: {
            Label("继续播放", systemImage: "play.fill")
        }

        if book.inShelf {
            Button {
                book.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(book.isPinned ? "取消置顶" : "置顶书籍", systemImage: "pin")
            }

            Menu("移动到分类") {
                Button("全部（无分类）") {
                    book.categoryID = nil
                    try? modelContext.save()
                }
                ForEach(categories) { cat in
                    Button(cat.name) {
                        book.categoryID = cat.id
                        try? modelContext.save()
                    }
                }
            }
        } else {
            Button {
                addBookToShelf(book)
            } label: {
                Label("加入书架", systemImage: "plus.circle")
            }
        }

        Button {
            if let chaps = ChapterCacheStore.loadChapters(for: book.id), !chaps.isEmpty {
                DownloadManager.shared.enqueueChapters(chaps, for: book.bookRef, kind: "manual")
                ToastManager.shared.show("已加入全部章节下载队列")
            } else {
                ToastManager.shared.show("请先打开详情页加载章节列表")
            }
        } label: {
            Label("下载全部", systemImage: "arrow.down.circle")
        }

        if book.inShelf {
            Button(role: .destructive) {
                removeFromShelf(book)
            } label: {
                Label("移出书架", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                removeRecentHistory(book)
            } label: {
                Label("删除播放记录", systemImage: "trash")
            }
        }
    }

    // MARK: - 6. 数据同步与操作方法

    private func backfillMissingChapterCountsIfNeeded() {
        var updated = false
        for book in books where book.totalChapters == 0 || (book.lastChapterID != nil && book.lastChapterIndex == 0) {
            guard let cached = ChapterCacheStore.loadChapters(for: book.id), !cached.isEmpty else { continue }
            if book.totalChapters != cached.count {
                book.totalChapters = cached.count
                updated = true
            }
            if let lastID = book.lastChapterID,
               let idx = cached.firstIndex(where: { $0.id == lastID }),
               book.lastChapterIndex != idx + 1 {
                book.lastChapterIndex = idx + 1
                updated = true
            }
        }
        if updated {
            try? modelContext.save()
        }
    }

    private func refreshCurrentSection() async {
        guard !isRefreshingShelf else { return }
        isRefreshingShelf = true
        defer { isRefreshingShelf = false }

        if sectionMode == .downloaded {
            DownloadManager.shared.reconcileCompletedFiles()
            ToastManager.shared.show("已刷新离线文件占用状态")
            return
        }

        let targets = Array((sectionMode == .shelf ? shelfBooks : recentBooks).prefix(12))
        let targetSnapshots = targets.map { (id: $0.id, sourceID: $0.sourceID, bookURL: $0.bookURL) }
        var fetchedResults: [(String, [ChapterDTO])] = []

        await withTaskGroup(of: (String, [ChapterDTO])?.self) { group in
            var nextIdx = 0
            let maxConcurrency = 3
            for _ in 0..<min(maxConcurrency, targetSnapshots.count) {
                let snap = targetSnapshots[nextIdx]
                nextIdx += 1
                group.addTask {
                    if let detail = try? await PluginRuntime.shared.bookDetail(
                        sourceID: snap.sourceID,
                        bookURL: snap.bookURL,
                        loadEpisodes: true,
                        loadFullPages: false
                    ), !detail.chapters.isEmpty {
                        return (snap.id, detail.chapters)
                    }
                    return nil
                }
            }
            for await item in group {
                if let item { fetchedResults.append(item) }
                if nextIdx < targetSnapshots.count {
                    let snap = targetSnapshots[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        if let detail = try? await PluginRuntime.shared.bookDetail(
                            sourceID: snap.sourceID,
                            bookURL: snap.bookURL,
                            loadEpisodes: true,
                            loadFullPages: false
                        ), !detail.chapters.isEmpty {
                            return (snap.id, detail.chapters)
                        }
                        return nil
                    }
                }
            }
        }

        var updatedCount = 0
        for (bookID, chapters) in fetchedResults {
            guard let book = bookByID[bookID] else { continue }
            if chapters.count > book.totalChapters {
                updatedCount += 1
                book.totalChapters = chapters.count
                ChapterCacheStore.saveChapters(chapters, for: book.id)
            }
            if let lastID = book.lastChapterID,
               let idx = chapters.firstIndex(where: { $0.id == lastID }) {
                book.lastChapterIndex = idx + 1
            }
        }
        try? modelContext.save()
        ToastManager.shared.show(updatedCount > 0 ? "发现 \(updatedCount) 本书有章节更新" : "书架进度已同步")
    }

    private func createNewCategory() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let cat = ShelfCategory(name: trimmed, order: categories.count)
            modelContext.insert(cat)
            try? modelContext.save()
            selectedCategoryID = cat.id
        }
        newCategoryName = ""
    }

    private func addBookToShelf(_ book: Book) {
        book.inShelf = true
        book.addedAt = .now
        try? modelContext.save()
        ToastManager.shared.show("已加入书架")
    }

    private func removeFromShelf(_ book: Book) {
        if book.lastPlayedAt != nil {
            book.inShelf = false
            book.isPinned = false
            book.categoryID = nil
        } else {
            modelContext.delete(book)
        }
        try? modelContext.save()
        ToastManager.shared.show("已移出书架")
    }

    private func removeRecentHistory(_ book: Book) {
        if book.inShelf {
            book.lastPlayedAt = nil
        } else {
            modelContext.delete(book)
        }
        try? modelContext.save()
        ToastManager.shared.show("已移除该条播放记录")
    }

    private func clearAllRecentHistory() {
        for book in recentBooks {
            if book.inShelf {
                book.lastPlayedAt = nil
            } else {
                modelContext.delete(book)
            }
        }
        try? modelContext.save()
        ToastManager.shared.show("已清空最近播放记录")
    }

    private func triggerQuickPlay(for book: Book) {
        if player.currentBookID == book.id {
            player.togglePlayPause()
            return
        }
        if let chapters = ChapterCacheStore.loadChapters(for: book.id), !chapters.isEmpty {
            let target = chapters.first(where: { $0.id == book.lastChapterID }) ?? chapters[0]
            player.startPlayback(
                book: book.bookRef,
                chapters: chapters,
                startChapter: target,
                initialPositionMs: book.lastPositionMs
            )
        } else {
            onSelectBook(book.bookRef)
        }
    }

    private func toggleSelection(for id: String) {
        if selectedBookIDs.contains(id) {
            selectedBookIDs.remove(id)
        } else {
            selectedBookIDs.insert(id)
        }
    }

    private func moveSelectedBooks(to categoryID: String?) {
        for book in shelfBooks where selectedBookIDs.contains(book.id) {
            book.categoryID = categoryID
        }
        try? modelContext.save()
        selectedBookIDs.removeAll()
        isEditingSelection = false
    }

    private func batchDownloadSelected() {
        for book in shelfBooks where selectedBookIDs.contains(book.id) {
            if let chaps = ChapterCacheStore.loadChapters(for: book.id) {
                DownloadManager.shared.enqueueChapters(chaps, for: book.bookRef, kind: "manual")
            }
        }
        ToastManager.shared.show("已批量加入下载队列")
        selectedBookIDs.removeAll()
        isEditingSelection = false
    }

    private func batchDeleteSelected() {
        for book in shelfBooks where selectedBookIDs.contains(book.id) {
            if book.lastPlayedAt != nil {
                book.inShelf = false
                book.isPinned = false
                book.categoryID = nil
            } else {
                modelContext.delete(book)
            }
        }
        try? modelContext.save()
        ToastManager.shared.show("已从书架移除所选书籍")
        selectedBookIDs.removeAll()
        isEditingSelection = false
    }
}

struct CategoryManageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ShelfCategory.order)]) private var categories: [ShelfCategory]

    init() {}
    @Query private var books: [Book]

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories) { cat in
                    Text(cat.name)
                }
                .onMove { indices, newOffset in
                    var reordered = categories
                    reordered.move(fromOffsets: indices, toOffset: newOffset)
                    for (idx, item) in reordered.enumerated() {
                        item.order = idx
                    }
                    try? modelContext.save()
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        let target = categories[idx]
                        for b in books where b.categoryID == target.id {
                            b.categoryID = nil
                        }
                        modelContext.delete(target)
                    }
                    try? modelContext.save()
                }
            }
            .navigationTitle("分类管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct DownloadManageView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\DownloadItem.createdAt, order: .reverse)]) private var items: [DownloadItem]

    init() {}

    private var manualItems: [DownloadItem] {
        items.filter { $0.kind == "manual" }
    }

    private struct DownloadedBookGroup: Identifiable {
        var id: String { bookID }
        let bookID: String
        let bookTitle: String
        let chapters: [DownloadItem]
    }

    private var groupedByBook: [DownloadedBookGroup] {
        let dict = Dictionary(grouping: manualItems, by: \.bookID)
        return dict.map { key, val in
            DownloadedBookGroup(
                bookID: key,
                bookTitle: val.first?.bookTitle ?? "未知书籍",
                chapters: val
            )
        }.sorted { $0.bookTitle < $1.bookTitle }
    }

    var body: some View {
        List {
            if groupedByBook.isEmpty {
                ContentUnavailableView(
                    "暂无离线下载任务",
                    systemImage: "arrow.down.circle",
                    description: Text("在书籍详情页选择章节或区间即可离线下载")
                )
            } else {
                ForEach(groupedByBook) { group in
                    Section {
                        ForEach(group.chapters) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.chapterTitle)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(statusLabel(for: item))
                                        .font(.caption2)
                                        .foregroundStyle(item.state == "failed" ? .red : .secondary)
                                }
                                Spacer()
                                if item.state == "failed" {
                                    Button("重试") {
                                        DownloadManager.shared.retryFailedItem(item)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.bookTitle)
                            Spacer()
                            Button("清理本书", role: .destructive) {
                                DownloadManager.shared.removeDownloads(forBookID: group.bookID)
                            }
                            .font(.caption)
                        }
                    }
                }

                Section {
                    let bytes = DownloadManager.shared.totalManualDownloadedBytes()
                    Text("总离线占用：\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("下载管理")
    }

    private func statusLabel(for item: DownloadItem) -> String {
        switch item.state {
        case "completed":
            return "已完成 · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))"
        case "downloading":
            return "正在下载…"
        case "failed":
            return "下载失败（已重试 \(item.retryCount) 次）"
        default:
            return "排队等待中"
        }
    }
}
