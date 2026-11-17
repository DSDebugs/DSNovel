import SwiftUI
import SwiftData

struct LibraryRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var settings = AppSettingsStore.shared
    @State private var player = PlayerEngine.shared

    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var showNewCategoryAlert = false
    @State private var newCategoryName = ""

    init() {}

    var body: some View {
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

                mainShelfContent
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
        .toolbarVisibility(isEditing ? .hidden : .visible, for: .tabBar)
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
                onManageCategories: { showNewCategoryAlert = true },
                onOpenHistory: { AppRouter.shared.open(.history) },
                onOpenDownloads: { AppRouter.shared.open(.downloads) }
            )
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                ShelfSelectionBar(
                    selectedCount: selectedIDs.count,
                    onMove: { showNewCategoryAlert = true },
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
        .alert("新建书架分类", isPresented: $showNewCategoryAlert) {
            TextField("分类名称", text: $newCategoryName)
            Button("创建") {
                let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    modelContext.insert(ShelfCategory(name: trimmed, order: libraryStore.categories.count))
                    try? modelContext.save()
                    libraryStore.refreshNow()
                }
                newCategoryName = ""
            }
            Button("取消", role: .cancel) { newCategoryName = "" }
        }
        .onAppear {
            libraryStore.modelContext = modelContext
            sourceStore.modelContext = modelContext
        }
    }

    @ViewBuilder
    private var mainShelfContent: some View {
        if sourceStore.allSources.isEmpty {
            DSStateView(
                kind: .noSource,
                onPrimary: { AppRouter.shared.open(.sourceImport) },
                onSecondary: { AppRouter.shared.open(.sourceList) }
            )
        } else if libraryStore.allShelfBooks.isEmpty && libraryStore.continueBook == nil {
            DSStateView(
                kind: .empty,
                onPrimary: { AppRouter.shared.selectedTab = .discover },
                onSecondary: { AppRouter.shared.selectedTab = .search }
            )
        } else if libraryStore.allShelfBooks.isEmpty && libraryStore.continueBook != nil {
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
                onPrimary: { libraryStore.selectedFilter = .all },
                onSecondary: nil
            )
        } else {
            let models = libraryStore.shelfBooks.map {
                LibraryCardMapper.makeModel(from: $0, sourceStore: sourceStore, player: player)
            }
            VStack(alignment: .leading, spacing: Spacing.s3) {
                DSSectionHeader(title: "我的书架", subtitle: "\(models.count) 本")
                if settings.shelfLayout == .list {
                    ShelfList(
                        models: models,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { playByModel($0) },
                        onTogglePin: { togglePin($0.id) },
                        onRemove: { removeSingle($0.id) }
                    )
                } else {
                    ShelfGrid(
                        models: models,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { playByModel($0) },
                        onTogglePin: { togglePin($0.id) },
                        onMoveCategory: { _ in showNewCategoryAlert = true },
                        onDownloadUnread: { downloadUnread($0.id) },
                        onRemove: { removeSingle($0.id) }
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
        if let book = libraryStore.allShelfBooks.first(where: { $0.id == id })
            ?? (libraryStore.continueBook?.id == id ? libraryStore.continueBook : nil)
            ?? libraryStore.recentBooks.first(where: { $0.id == id }) {
            libraryStore.markUpdateRead(bookID: book.id)
            AppRouter.shared.open(.book(book.bookRef))
        }
    }

    private func playByModel(_ model: BookCardModel) {
        if let book = libraryStore.allShelfBooks.first(where: { $0.id == model.id }) {
            DSHapticPolicy.fire(.playPause)
            LibraryCardMapper.playBookImmediately(book, player: player)
        }
    }

    private func togglePin(_ id: String) {
        guard let book = libraryStore.allShelfBooks.first(where: { $0.id == id }) else { return }
        book.isPinned.toggle()
        try? modelContext.save()
        libraryStore.refreshNow()
    }

    private func downloadUnread(_ id: String) {
        guard let book = libraryStore.allShelfBooks.first(where: { $0.id == id }),
              let chapters = ChapterCacheStore.loadChapters(for: book.id) else { return }
        DownloadManager.shared.enqueueChapters(chapters, for: book.bookRef, kind: "manual")
        BannerCenter.shared.show("已加入下载 \(chapters.count) 章", kind: .success)
    }

    private func removeSingle(_ id: String) {
        guard let book = libraryStore.allShelfBooks.first(where: { $0.id == id }) else { return }
        DSHapticPolicy.fire(.warning)
        libraryStore.removeFromShelfDeferred([book])
    }

    private func batchDownloadSelected() {
        for book in libraryStore.allShelfBooks where selectedIDs.contains(book.id) {
            if let chs = ChapterCacheStore.loadChapters(for: book.id) {
                DownloadManager.shared.enqueueChapters(chs, for: book.bookRef, kind: "manual")
            }
        }
        isEditing = false
        selectedIDs.removeAll()
        BannerCenter.shared.show("已加入批量下载", kind: .success)
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
        let targets = libraryStore.allShelfBooks.filter { selectedIDs.contains($0.id) }
        isEditing = false
        selectedIDs.removeAll()
        DSHapticPolicy.fire(.warning)
        libraryStore.removeFromShelfDeferred(targets)
    }
}
