import SwiftUI
import SwiftData

/// 书架与最近播放页：
/// 1. 顶部清晰分离「我的书架」与「最近播放」两个独立视图；
/// 2. 只有用户主动点击「加入书架」的书籍（`inShelf == true`）才在「我的书架」展示；
/// 3. 所有播放过的历史记录（`lastPlayedAt != nil`）在「最近播放」按时间倒序展示，未加入书架的书籍支持一键「+ 加入书架」；
/// 4. 「我的书架」与「最近播放」均完整记录并展示每本书的最后播放章节、播放进度时间点与最后播放时间。
struct ShelfView: View {
    let onSwitchToDiscover: () -> Void
    let onSwitchToSearch: () -> Void
    let onSelectBook: (BookRef) -> Void
    let onOpenDownloads: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Book.addedAt, order: .reverse)]) private var books: [Book]
    @Query(sort: [SortDescriptor(\ShelfCategory.order)]) private var categories: [ShelfCategory]
    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]

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
    @State private var showCategoryManageSheet = false
    @State private var showNewCategoryAlert = false
    @State private var newCategoryName = ""
    @State private var showMoveCategoryDialog = false
    @State private var showClearRecentConfirm = false

    private var player = PlayerEngine.shared
    private var settings = AppSettingsStore.shared

    private var sourceNameByID: [String: String] {
        Dictionary(plugins.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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

    /// 书架内最近播放的一本书（用于书架顶部快捷续听卡片）
    private var mostRecentShelfBook: Book? {
        shelfBooks
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            .first
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

    var body: some View {
        shelfMainStack
            .navigationTitle(sectionMode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    sectionModeSwitcher
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    shelfTrailingToolbarItems
                }
            }
            .onChange(of: sectionMode) { _, _ in
                if isEditingSelection {
                    isEditingSelection = false
                    selectedBookIDs.removeAll()
                }
            }
            .alert("新建书架分类", isPresented: $showNewCategoryAlert) {
                TextField("分类名称", text: $newCategoryName)
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
                Button("清空最近播放（不影响已加入书架的书籍）", role: .destructive) {
                    clearAllRecentHistory()
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showCategoryManageSheet) {
                CategoryManageSheet()
            }
    }

    // MARK: - 顶部「我的书架 / 最近播放」分段切换器

    private var sectionModeSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(ShelfSectionMode.allCases) { mode in
                let isSelected = sectionMode == mode
                let count = mode == .shelf ? shelfBooks.count : recentBooks.count
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sectionMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(mode.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.white.opacity(0.24) : Color.secondary.opacity(0.14))
                                )
                        }
                    }
                    .foregroundStyle(isSelected ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? DSColor.primary : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(DSColor.cardSurface)
        )
    }

    private var shelfMainStack: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch sectionMode {
                case .shelf:
                    shelfPrimaryContent
                case .recent:
                    recentPlayedPrimaryContent
                }
            }
            .background(DSColor.contentBackground)

            // 书架编辑模式下的底部操作栏（书架页唯一的玻璃元素）
            if sectionMode == .shelf && isEditingSelection && !selectedBookIDs.isEmpty {
                shelfEditingFloatingBar
            }
        }
    }

    // MARK: - 1. 「我的书架」视图（仅展示用户主动加入书架的书籍）

    @ViewBuilder
    private var shelfPrimaryContent: some View {
        if shelfBooks.isEmpty {
            ContentUnavailableView {
                Label("书架还是空的", systemImage: "books.vertical")
            } description: {
                Text("只有你在书籍详情页或最近播放中点击「加入书架」的书籍才会展示在这里，并持久记录最后播放章节与时间")
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
        } else {
            VStack(spacing: 0) {
                if let recent = mostRecentShelfBook {
                    continueListeningCard(for: recent)
                }
                categoryCapsuleStrip
                shelfCollectionBody
            }
        }
    }

    // MARK: - 2. 「最近播放」视图（展示全部历史播放记录，记录最后播放章节、进度与时间）

    @ViewBuilder
    private var recentPlayedPrimaryContent: some View {
        if recentBooks.isEmpty {
            ContentUnavailableView {
                Label("暂无最近播放记录", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("点击任意书籍章节开始收听后，这里会自动记录最后播放章节、收听进度与播放时间")
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
        } else {
            List {
                Section {
                    ForEach(recentBooks) { book in
                        recentPlayedRow(for: book)
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
                } header: {
                    HStack {
                        Text("按最后播放时间排序（共 \(recentBooks.count) 本）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清空记录") {
                            showClearRecentConfirm = true
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func recentPlayedRow(for book: Book) -> some View {
        let isThisPlaying = player.currentBookID == book.id && player.state == .playing
        let sourceName = sourceNameByID[book.sourceID] ?? book.sourceID

        return HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CoverImageView(url: book.cover, title: book.title, width: 60, height: 80, cornerRadius: 8)
                if isThisPlaying {
                    Image(systemName: "waveform")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(DSColor.primary))
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(book.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if book.inShelf {
                        Text("已在书架")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DSColor.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(DSColor.primary.opacity(0.12))
                            )
                    }
                }

                // 最后播放章节
                HStack(spacing: 4) {
                    Image(systemName: "headphones")
                        .font(.caption2)
                        .foregroundStyle(DSColor.primary)
                    Text(book.lastChapterTitle ?? "未知章节")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                // 播放进度位置 + 最后播放时间 + 书源名称
                HStack(spacing: 6) {
                    Text("进度 \(book.formattedPositionText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DSColor.primary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(book.formattedLastPlayedAtText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("· \(sourceName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    triggerQuickPlay(for: book)
                } label: {
                    Image(systemName: isThisPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(DSColor.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isThisPlaying ? "暂停" : "继续播放")

                if !book.inShelf {
                    Button {
                        addBookToShelf(book)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus")
                            Text("书架")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DSColor.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .strokeBorder(DSColor.primary.opacity(0.6), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectBook(book.bookRef)
        }
        .contextMenu {
            Button {
                triggerQuickPlay(for: book)
            } label: {
                Label("继续播放", systemImage: "play.fill")
            }

            if !book.inShelf {
                Button {
                    addBookToShelf(book)
                } label: {
                    Label("加入书架", systemImage: "books.vertical")
                }
            } else {
                Button(role: .destructive) {
                    removeFromShelf(book)
                } label: {
                    Label("移出书架", systemImage: "folder.badge.minus")
                }
            }

            Button(role: .destructive) {
                removeRecentHistory(book)
            } label: {
                Label("删除此条播放记录", systemImage: "trash")
            }
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
    private var shelfTrailingToolbarItems: some View {
        if sectionMode == .shelf {
            Button {
                settings.shelfLayout = settings.shelfLayout == .grid ? .list : .grid
            } label: {
                Image(systemName: settings.shelfLayout == .grid ? "list.bullet" : "square.grid.2x2")
            }
            .accessibilityLabel(settings.shelfLayout == .grid ? "切换为列表" : "切换为网格")

            Menu {
                Picker("排序方式", selection: Bindable(settings).shelfSort) {
                    ForEach(ShelfSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("排序方式")
        } else if !recentBooks.isEmpty {
            Button {
                showClearRecentConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("清空最近播放")
        }

        Menu {
            if sectionMode == .shelf && !shelfBooks.isEmpty {
                Button {
                    isEditingSelection.toggle()
                    selectedBookIDs.removeAll()
                } label: {
                    Label(isEditingSelection ? "完成编辑" : "批量管理书架", systemImage: "checkmark.circle")
                }

                Button {
                    showCategoryManageSheet = true
                } label: {
                    Label("分类管理", systemImage: "folder.badge.gearshape")
                }
            }

            Button {
                onOpenDownloads()
            } label: {
                Label("离线下载管理", systemImage: "arrow.down.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多操作")
    }

    private func createNewCategory() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let cat = ShelfCategory(name: trimmed, order: categories.count)
            modelContext.insert(cat)
            try? modelContext.save()
        }
        newCategoryName = ""
    }

    private func continueListeningCard(for book: Book) -> some View {
        let isThisPlaying = player.currentBookID == book.id && player.state == .playing
        return HStack(spacing: 12) {
            CoverImageView(url: book.cover, title: book.title, width: 52, height: 70, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("继续收听 · \(book.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(book.formattedLastPlayedAtText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(book.lastChapterTitle ?? "点击继续上次位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("已播至 \(book.formattedPositionText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DSColor.primary)
            }
            Spacer(minLength: 4)

            Button {
                triggerQuickPlay(for: book)
            } label: {
                Image(systemName: isThisPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(DSColor.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isThisPlaying ? "暂停" : "继续播放")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DSColor.cardSurface)
        )
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, DSSpacing.sm)
        .onTapGesture {
            onSelectBook(book.bookRef)
        }
    }

    private var categoryCapsuleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let allSelected = selectedCategoryID == nil
                Button {
                    selectedCategoryID = nil
                } label: {
                    Text("全部 (\(shelfBooks.count))")
                        .font(.caption.weight(allSelected ? .semibold : .regular))
                        .foregroundStyle(allSelected ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(allSelected ? DSColor.primary : DSColor.cardSurface)
                        )
                }
                .buttonStyle(.plain)

                ForEach(categories) { cat in
                    let isSelected = selectedCategoryID == cat.id
                    Button {
                        selectedCategoryID = cat.id
                    } label: {
                        Text(cat.name)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? DSColor.primary : DSColor.cardSurface)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showNewCategoryAlert = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(DSColor.cardSurface)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建分类")
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
        } else {
            List(filteredShelfBooks) { book in
                shelfListItem(for: book)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeFromShelf(book)
                        } label: {
                            Label("移出书架", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.plain)
        }
    }

    private func shelfGridItem(for book: Book) -> some View {
        let isThisPlaying = player.currentBookID == book.id && player.state == .playing
        let isSelected = selectedBookIDs.contains(book.id)

        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                CoverImageView(url: book.cover, title: book.title, width: 104, height: 138, cornerRadius: 8)

                // 封面右下角叠加不透明圆形纯色播放状态角标
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

            HStack(spacing: 4) {
                if book.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(DSColor.primary)
                }
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }

            // 最后播放章节
            Text(book.lastChapterTitle ?? "尚未收听")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // 最后播放进度与时间
            if book.lastPlayedAt != nil {
                Text("\(book.formattedPositionText) · \(book.formattedLastPlayedAtText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DSColor.primary)
                    .lineLimit(1)
            } else {
                Text(book.author.isEmpty ? "待收听" : book.author)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
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

    private func shelfListItem(for book: Book) -> some View {
        let isThisPlaying = player.currentBookID == book.id && player.state == .playing
        return HStack(spacing: 12) {
            CoverImageView(url: book.cover, title: book.title, width: 56, height: 76, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if book.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(DSColor.primary)
                    }
                    Text(book.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }

                // 最后播放章节
                Text(book.lastChapterTitle.map { "上次听到：\($0)" } ?? "尚未开始收听")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // 最后播放进度与时间
                if book.lastPlayedAt != nil {
                    HStack(spacing: 6) {
                        Text("进度 \(book.formattedPositionText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(DSColor.primary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(book.formattedLastPlayedAtText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if book.sourceUnavailable {
                    Text("书源不可用 · 点击详情可换源")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                triggerQuickPlay(for: book)
            } label: {
                Image(systemName: isThisPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DSColor.primary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
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

    @ViewBuilder
    private func bookContextMenu(for book: Book) -> some View {
        Button {
            triggerQuickPlay(for: book)
        } label: {
            Label("继续播放", systemImage: "play.fill")
        }

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

        Button(role: .destructive) {
            removeFromShelf(book)
        } label: {
            Label("移出书架", systemImage: "trash")
        }
    }

    // MARK: - 书架与最近播放操作方法

    private func addBookToShelf(_ book: Book) {
        book.inShelf = true
        book.addedAt = .now
        try? modelContext.save()
        ToastManager.shared.show("已加入书架")
    }

    /// 从「我的书架」移出：若该书有播放历史，保留在「最近播放」中；若无播放历史则彻底删除
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

    /// 从「最近播放」删除单条记录：若该书已在书架，保留书架收藏并清空最近播放时间戳；若未在书架则彻底删除
    private func removeRecentHistory(_ book: Book) {
        if book.inShelf {
            book.lastPlayedAt = nil
        } else {
            modelContext.delete(book)
        }
        try? modelContext.save()
        ToastManager.shared.show("已移除该条播放记录")
    }

    /// 清空全部最近播放历史（不影响「我的书架」中的书籍）
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
