import SwiftUI
import SwiftData

/// 书架页（5.2 节）：顶部「继续收听」一键续听、分类胶囊条、播放状态实时同步、多选编辑底部唯一玻璃悬浮操作栏
struct ShelfView: View {
    let onSwitchToDiscover: () -> Void
    let onSelectBook: (BookRef) -> Void
    let onOpenDownloads: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Book.addedAt, order: .reverse)]) private var books: [Book]
    @Query(sort: [SortDescriptor(\ShelfCategory.order)]) private var categories: [ShelfCategory]

    init(
        onSwitchToDiscover: @escaping () -> Void,
        onSelectBook: @escaping (BookRef) -> Void,
        onOpenDownloads: @escaping () -> Void
    ) {
        self.onSwitchToDiscover = onSwitchToDiscover
        self.onSelectBook = onSelectBook
        self.onOpenDownloads = onOpenDownloads
    }

    @State private var selectedCategoryID: String? = nil
    @State private var isEditingSelection = false
    @State private var selectedBookIDs: Set<String> = []
    @State private var showCategoryManageSheet = false
    @State private var showNewCategoryAlert = false
    @State private var newCategoryName = ""
    @State private var showMoveCategoryDialog = false

    private var player = PlayerEngine.shared
    private var settings = AppSettingsStore.shared

    private var mostRecentBook: Book? {
        books
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            .first
    }

    private var filteredBooks: [Book] {
        let base = books.filter { book in
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
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    shelfTrailingToolbarItems
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
            .sheet(isPresented: $showCategoryManageSheet) {
                CategoryManageSheet()
            }
    }

    private var shelfMainStack: some View {
        ZStack(alignment: .bottom) {
            shelfPrimaryContent
                .background(DSColor.contentBackground)

            // 书架编辑模式下的底部操作栏（书架页唯一的玻璃元素，符合 5.2 节步骤 4）
            if isEditingSelection && !selectedBookIDs.isEmpty {
                shelfEditingFloatingBar
            }
        }
    }

    @ViewBuilder
    private var shelfPrimaryContent: some View {
        if books.isEmpty {
            ContentUnavailableView {
                Label("书架还是空的，去发现页看看", systemImage: "books.vertical")
            } description: {
                Text("收藏喜欢的有声书后，会自动记住每一集的收听位置与倍速设置")
            } actions: {
                Button("去发现页") {
                    onSwitchToDiscover()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 0) {
                if let recent = mostRecentBook {
                    continueListeningCard(for: recent)
                }
                categoryCapsuleStrip
                shelfCollectionBody
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
                Label("删除", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var shelfTrailingToolbarItems: some View {
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

        Menu {
            Button {
                isEditingSelection.toggle()
                selectedBookIDs.removeAll()
            } label: {
                Label(isEditingSelection ? "完成编辑" : "批量编辑", systemImage: "checkmark.circle")
            }

            Button {
                showCategoryManageSheet = true
            } label: {
                Label("分类管理", systemImage: "folder.badge.gearshape")
            }

            Button {
                onOpenDownloads()
            } label: {
                Label("下载管理", systemImage: "arrow.down.circle")
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
                Text("继续收听 · \(book.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(book.lastChapterTitle ?? "点击继续上次位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if book.lastPositionMs > 0 {
                    Text("已播至 \(PlaybackClock.formatSeconds(Double(book.lastPositionMs) / 1000.0))")
                        .font(.caption2)
                        .foregroundStyle(DSColor.primary)
                }
            }
            Spacer()

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
    }

    private var categoryCapsuleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let allSelected = selectedCategoryID == nil
                Button {
                    selectedCategoryID = nil
                } label: {
                    Text("全部")
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
                    ForEach(filteredBooks) { book in
                        shelfGridItem(for: book)
                    }
                }
                .padding(DSSpacing.lg)
            }
        } else {
            List(filteredBooks) { book in
                shelfListItem(for: book)
            }
            .listStyle(.plain)
        }
    }

    private func shelfGridItem(for book: Book) -> some View {
        let isThisPlaying = player.currentBookID == book.id && player.state == .playing
        let isSelected = selectedBookIDs.contains(book.id)

        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CoverImageView(url: book.cover, title: book.title, width: 104, height: 138, cornerRadius: 8)

                // 封面右下角叠加不透明圆形纯色播放状态角标（5.2 节）
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
            Text(book.lastChapterTitle ?? (book.author.isEmpty ? "未开始收听" : book.author))
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text(book.lastChapterTitle ?? "尚未收听")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if book.sourceUnavailable {
                    Text("来源不可用 · 点击详情可换源")
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
            modelContext.delete(book)
            try? modelContext.save()
            ToastManager.shared.show("已移出书架")
        } label: {
            Label("移出书架", systemImage: "trash")
        }
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
        for book in books where selectedBookIDs.contains(book.id) {
            book.categoryID = categoryID
        }
        try? modelContext.save()
        selectedBookIDs.removeAll()
        isEditingSelection = false
    }

    private func batchDownloadSelected() {
        for book in books where selectedBookIDs.contains(book.id) {
            if let chaps = ChapterCacheStore.loadChapters(for: book.id) {
                DownloadManager.shared.enqueueChapters(chaps, for: book.bookRef, kind: "manual")
            }
        }
        ToastManager.shared.show("已批量加入下载队列")
        selectedBookIDs.removeAll()
        isEditingSelection = false
    }

    private func batchDeleteSelected() {
        for book in books where selectedBookIDs.contains(book.id) {
            modelContext.delete(book)
        }
        try? modelContext.save()
        ToastManager.shared.show("已移除所选书籍")
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
                        // 删除分类时书籍回到「全部」（5.2 节步骤 5）
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
