import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 书架根视图（UI-05 平滑回顶 + UI-06 多选批量整理与搜索过滤 + 独立书架/历史移除 + 继续收听卡片）
struct LibraryRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    @Environment(PlaybackCoordinator.self) private var playback

    @State private var books: [BookSummaryDTO] = []
    @State private var displayedBooks: [BookSummaryDTO] = []
    @State private var searchKeyword = ""
    @State private var isLoading = false
    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var pendingRemoveBook: BookSummaryDTO?
    @State private var showBatchRemoveAlert = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: DSSpacing.sm),
        GridItem(.flexible(), spacing: DSSpacing.sm),
        GridItem(.flexible(), spacing: DSSpacing.sm)
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        Color.clear.frame(height: 1).id("library-top")

                        if !books.isEmpty {
                            DSClearableSearchField("筛选书架中的书名、作者或演播", text: $searchKeyword)
                                .padding(.horizontal, DSSpacing.md)
                        }

                        if let current = playback.currentBook {
                            ContinueListeningCard(
                                book: current,
                                chapterTitle: playback.currentChapter?.title ?? "继续收听",
                                isPlaying: playback.state.isPlaying,
                                pipeline: container.coverPipeline,
                                onOpenPlayer: { router.isPlayerPresented = true },
                                onTogglePlay: { playback.togglePlayPause() }
                            )
                            .padding(.horizontal, DSSpacing.md)
                        }

                        if displayedBooks.isEmpty && !isLoading {
                            DSStateView(
                                icon: "books.vertical",
                                title: books.isEmpty ? "书架还没有书籍" : "未找到匹配书籍",
                                message: books.isEmpty ? "前往「发现」或「搜索」添加有声书，已下载的离线内容也会始终保留入口。" : "请尝试其他关键词。",
                                actionTitle: books.isEmpty ? "去发现看看" : nil
                            ) {
                                router.selectTab(.discover)
                            }
                            .padding(.top, DSSpacing.xl)
                        } else if settings.shelfLayout == .grid {
                            LazyVGrid(columns: gridColumns, spacing: DSSpacing.md) {
                                ForEach(displayedBooks) { book in
                                    bookGridItem(book)
                                }
                            }
                            .padding(.horizontal, DSSpacing.md)
                        } else {
                            LazyVStack(spacing: DSSpacing.sm) {
                                ForEach(displayedBooks) { book in
                                    bookListItem(book)
                                }
                            }
                            .padding(.horizontal, DSSpacing.md)
                        }
                    }
                    .padding(.top, DSSpacing.xs)
                    .padding(.bottom, isSelectionMode ? 76 : DSSpacing.md)
                }
                .scrollDismissesKeyboard(.interactively)

                if isSelectionMode {
                    ShelfBatchSelectionBar(
                        selectedCount: selectedIDs.count,
                        onSelectAll: { selectAllDisplayed(displayedBooks) },
                        onRemoveSelected: {
                            if !selectedIDs.isEmpty {
                                showBatchRemoveAlert = true
                            }
                        },
                        onCancel: {
                            isSelectionMode = false
                            selectedIDs.removeAll()
                        }
                    )
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.bottom, DSSpacing.xs)
                }
            }
            .onChange(of: router.scrollToTopTrigger[.library] ?? 0) { _, _ in
                DSMotion.withResolved(.easeOut(duration: 0.25), reduceMotion: reduceMotion) {
                    proxy.scrollTo("library-top", anchor: .top)
                }
            }
        }
        .accessibilityIdentifier("library_root")
        .background(DSColors.surfaceBase)
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.push(.history)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("收听历史")
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    Button(isSelectionMode ? "取消" : "选择") {
                        isSelectionMode.toggle()
                        if !isSelectionMode { selectedIDs.removeAll() }
                    }
                    .frame(minHeight: 44)
                    .disabled(books.isEmpty)

                    Button {
                        settings.shelfLayout = (settings.shelfLayout == .grid) ? .list : .grid
                    } label: {
                        Image(systemName: settings.shelfLayout == .grid ? "list.bullet" : "square.grid.3x3")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("切换书架布局")
                }
            }
        }
        .alert("移出书架", isPresented: Binding(
            get: { pendingRemoveBook != nil },
            set: { if !$0 { pendingRemoveBook = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRemoveBook = nil }
            Button("移出书架", role: .destructive) {
                if let target = pendingRemoveBook {
                    Task { await removeFromShelf(target) }
                }
                pendingRemoveBook = nil
            }
        } message: {
            Text("移出书架不会清除收听历史或已下载的本地音频。")
        }
        .alert("批量移出书架", isPresented: $showBatchRemoveAlert) {
            Button("取消", role: .cancel) {}
            Button("确认移出", role: .destructive) {
                Task { await removeSelectedBooks() }
            }
        } message: {
            Text("确定将已选的 \(selectedIDs.count) 本书移出书架？此操作不会清除收听历史或本地离线音频。")
        }
        .onChange(of: searchKeyword) { _, _ in
            refreshDisplayedBooks()
        }
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await reloadShelf() }
        }
        .task { await reloadShelf() }
        .refreshable { await reloadShelf() }
    }

    private func bookGridItem(_ book: BookSummaryDTO) -> some View {
        let selected = selectedIDs.contains(book.id)
        return ZStack(alignment: .topTrailing) {
            DSBookCard(book: book, pipeline: container.coverPipeline) {
                handleTap(book)
            }
            if isSelectionMode {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(DSTypography.headline)
                    .foregroundStyle(selected ? DSColors.accent : .white)
                    .padding(6)
            }
        }
        .contextMenu {
            Button("置顶 / 取消置顶") { Task { await togglePin(book) } }
            Button("移出书架", role: .destructive) { pendingRemoveBook = book }
        }
    }

    private func bookListItem(_ book: BookSummaryDTO) -> some View {
        let selected = selectedIDs.contains(book.id)
        return HStack(spacing: DSSpacing.xs) {
            if isSelectionMode {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DSColors.accent : DSColors.inkSecondary)
            }
            DSBookRow(book: book, pipeline: container.coverPipeline) {
                handleTap(book)
            }
        }
        .padding(DSSpacing.sm)
        .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.md))
        .contextMenu {
            Button("置顶 / 取消置顶") { Task { await togglePin(book) } }
            Button("移出书架", role: .destructive) { pendingRemoveBook = book }
        }
    }

    private func refreshDisplayedBooks() {
        let filtered = LibraryOrganizerHelper.filterBooks(books, keyword: searchKeyword)
        displayedBooks = filtered
        if isSelectionMode {
            let visibleIDs = Set(filtered.map(\.id))
            selectedIDs = selectedIDs.intersection(visibleIDs)
        }
    }

    private func selectAllDisplayed(_ displayed: [BookSummaryDTO]) {
        selectedIDs = Set(displayed.map(\.id))
    }

    private func handleTap(_ book: BookSummaryDTO) {
        if isSelectionMode {
            if selectedIDs.contains(book.id) { selectedIDs.remove(book.id) }
            else { selectedIDs.insert(book.id) }
        } else {
            router.push(.bookDetail(book))
        }
    }

    private func reloadShelf() async {
        isLoading = true
        defer { isLoading = false }
        if let loaded = try? await container.persistence.fetchShelfBooks() {
            books = loaded
            refreshDisplayedBooks()
        }
    }

    private func togglePin(_ book: BookSummaryDTO) async {
        do {
            try await container.persistence.togglePin(bookID: book.id)
            container.notifyLibraryChanged()
            banner.show("已更新置顶状态", tone: .success)
        } catch {
            banner.show("更新置顶状态失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func removeFromShelf(_ book: BookSummaryDTO) async {
        do {
            try await container.persistence.setInShelf(bookID: book.id, inShelf: false)
            container.notifyLibraryChanged()
            banner.show("已将《\(book.title)》移出书架", tone: .info)
        } catch {
            banner.show("移出书架失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func removeSelectedBooks() async {
        let targets = Array(selectedIDs)
        guard !targets.isEmpty else { return }
        do {
            try await container.persistence.setInShelfBatch(bookIDs: targets, inShelf: false)
            selectedIDs.removeAll()
            isSelectionMode = false
            container.notifyLibraryChanged()
            banner.show("已移出 \(targets.count) 本书", tone: .info)
        } catch {
            banner.show("批量移出书架失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
