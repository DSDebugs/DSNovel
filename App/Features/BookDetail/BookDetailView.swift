import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSStorage
import SwiftUI

/// 书籍详情视图（UI-03：动态续播定位 + 正/倒序切换 + 定位当前章 + 离线已下载徽标 + BookTitleFormatter 标题清洗）
struct BookDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(AppSettingsStore.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner

    private let initialBook: BookSummaryDTO
    @State private var detail: BookDetailDTO?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var inShelf = false
    @State private var isDescending = false
    @State private var resumeChapterIndex: Int?
    @State private var downloadedChapterIDs: Set<String> = []
    @State private var loadGeneration: UInt64 = 0
    @State private var showRangeDownload = false
    @State private var reversedChapters: [ChapterDTO] = []
    @State private var chapterIndexByID: [String: Int] = [:]

    init(book: BookSummaryDTO) { self.initialBook = book }

    private var activeChapterIndex: Int? {
        let bookID = detail?.summary.id ?? initialBook.id
        return (playback.currentBook?.id == bookID) ? playback.currentChapterIndex : resumeChapterIndex
    }

    var body: some View {
        let currentBook = detail?.summary ?? initialBook
        let chapters = detail?.chapters ?? []
        let displayedChapters = isDescending ? reversedChapters : chapters
        let cleanTitle = BookTitleFormatter.cleanTitle(currentBook.title)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    headerCard(currentBook, cleanTitle: cleanTitle)
                    actionButtons(book: currentBook, chapters: chapters)

                    if !currentBook.intro.isEmpty {
                        Text(currentBook.intro)
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                            .padding(.horizontal, DSSpacing.md)
                    }

                    Divider().padding(.horizontal, DSSpacing.md)

                    if isLoading && chapters.isEmpty {
                        ProgressView("正在加载目录...")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DSSpacing.lg)
                    } else if let err = errorMessage, chapters.isEmpty {
                        DSStateView(
                            icon: "exclamationmark.triangle",
                            title: "目录加载失败",
                            message: err,
                            actionTitle: "重新加载"
                        ) {
                            Task { await loadDetail(forceRemote: true) }
                        }
                    } else if chapters.isEmpty {
                        DSStateView(
                            icon: "list.bullet.rectangle",
                            title: "暂无可播放章节",
                            message: "该书源未返回有效章节列表，可尝试刷新或切换其他书源。",
                            actionTitle: "刷新目录"
                        ) {
                            Task { await loadDetail(forceRemote: true) }
                        }
                    } else {
                        chapterListSection(
                            book: currentBook,
                            allChapters: chapters,
                            displayedChapters: displayedChapters,
                            scrollProxy: proxy
                        )
                    }
                }
                .padding(.vertical, DSSpacing.md)
            }
        }
        .background(DSColors.surfaceBase)
        .navigationTitle(cleanTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRangeDownload) {
            RangeDownloadSheet(book: currentBook, chapters: chapters) {
                showRangeDownload = false
            }
        }
        .task(id: initialBook.id) { await loadDetail(forceRemote: false) }
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await refreshShelfStatus() }
        }
        .onChange(of: downloads.completedRevision) { _, _ in
            refreshDownloadedChapterIDs()
        }
    }

    private func headerCard(_ book: BookSummaryDTO, cleanTitle: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            DSCoverImage(urlString: book.coverURL, pipeline: container.coverPipeline, cornerRadius: DSRadius.md)
                .frame(width: 96, height: 128)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(cleanTitle)
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(3)
                let meta = BookTitleFormatter.narratorDisplay(author: book.author, narrator: book.narrator)
                if !meta.isEmpty {
                    Text(meta)
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                }
                if !book.sourceName.isEmpty {
                    HStack(spacing: DSSpacing.xs) {
                        DSSourceAvatar(name: book.sourceName)
                        Text(book.sourceName)
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.md)
    }

    private func actionButtons(book: BookSummaryDTO, chapters: [ChapterDTO]) -> some View {
        let activeIdx = activeChapterIndex
        let startIdx = min(max(0, activeIdx ?? 0), max(0, chapters.count - 1))
        let playLabel = activeIdx != nil ? "继续收听 · 第 \(startIdx + 1) 章" : "从第 1 章开始"

        return HStack(spacing: DSSpacing.sm) {
            Button {
                guard !chapters.isEmpty else { return }
                playback.play(book: book, chapters: chapters, startIndex: startIdx, autoPlay: true)
                router.isPlayerPresented = true
            } label: {
                Label(playLabel, systemImage: "play.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(chapters.isEmpty)

            Button {
                Task { await toggleShelf(book) }
            } label: {
                Label(inShelf ? "已在书架" : "加入书架", systemImage: inShelf ? "checkmark" : "plus")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)

            Button {
                showRangeDownload = true
            } label: {
                Image(systemName: "arrow.down.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(chapters.isEmpty)
            .accessibilityLabel("批量下载章节")
        }
        .padding(.horizontal, DSSpacing.md)
    }

    private func chapterListSection(
        book: BookSummaryDTO,
        allChapters: [ChapterDTO],
        displayedChapters: [ChapterDTO],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let activeIdx = activeChapterIndex
        return LazyVStack(spacing: 0) {
            HStack(spacing: DSSpacing.xs) {
                Text("共 \(allChapters.count) 章")
                    .font(DSTypography.headline)
                Spacer()
                if let idx = activeIdx, allChapters.indices.contains(idx) {
                    Button("定位当前") {
                        let targetID = allChapters[idx].id
                        DSMotion.withResolved(.easeOut(duration: 0.25), reduceMotion: reduceMotion) {
                            scrollProxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                    .font(DSTypography.caption)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 36)
                }
                Button(isDescending ? "倒序" : "正序") {
                    isDescending.toggle()
                }
                .font(DSTypography.caption)
                .buttonStyle(.bordered)
                .frame(minHeight: 36)
                Button {
                    Task { await loadDetail(forceRemote: true) }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 32, minHeight: 36)
                    } else {
                        Text("刷新")
                            .font(DSTypography.caption)
                            .frame(minHeight: 36)
                    }
                }
                .disabled(isLoading)
            }
            .padding(.horizontal, DSSpacing.md)
            .padding(.bottom, DSSpacing.xs)

            ForEach(displayedChapters) { chapter in
                let physicalIdx = chapterIndexByID[chapter.id]
                let isCurrent = (physicalIdx != nil && activeIdx == physicalIdx)
                Button {
                    if let idx = physicalIdx {
                        playback.play(book: book, chapters: allChapters, startIndex: idx, autoPlay: true)
                        router.isPlayerPresented = true
                    }
                } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Text(chapter.title)
                            .font(DSTypography.subheadline)
                            .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkPrimary)
                            .lineLimit(1)
                        Spacer()
                        if downloadedChapterIDs.contains(chapter.id) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.success)
                        }
                        if chapter.isVIP {
                            Text("VIP")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.warning)
                        }
                    }
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .id(chapter.id)
                Divider().padding(.leading, DSSpacing.md)
            }
        }
    }

    private func applyDetail(_ newDetail: BookDetailDTO) {
        detail = newDetail
        reversedChapters = Array(newDetail.chapters.reversed())
        var map: [String: Int] = [:]
        map.reserveCapacity(newDetail.chapters.count)
        for (idx, ch) in newDetail.chapters.enumerated() { map[ch.id] = idx }
        chapterIndexByID = map
    }

    private func refreshShelfStatus() async {
        if let shelfBooks = try? await container.persistence.fetchShelfBooks() {
            inShelf = shelfBooks.contains(where: { $0.id == initialBook.id })
        }
    }

    private func refreshDownloadedChapterIDs() {
        let completed = DownloadsDataHelper.completedChapters(for: initialBook.id, from: downloads.manualRecords)
        downloadedChapterIDs = Set(completed.map(\.chapterID))
    }

    private func loadDetail(forceRemote: Bool) async {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        errorMessage = nil

        await refreshShelfStatus()
        if let last = await container.persistence.fetchBookLastPlayback(bookID: initialBook.id) {
            resumeChapterIndex = last.chapterIndex
        }
        refreshDownloadedChapterIDs()

        if !forceRemote, let cached = await container.chapterCache.loadChapters(bookID: initialBook.id) {
            guard gen == loadGeneration else { return }
            applyDetail(BookDetailDTO(summary: initialBook, chapters: cached))
            isLoading = false
        }

        do {
            let remote = try await container.pluginRuntime.bookDetail(sourceID: initialBook.sourceID, book: initialBook)
            guard gen == loadGeneration else { return }
            applyDetail(remote)
            isLoading = false
            if !remote.chapters.isEmpty {
                try? await container.chapterCache.saveChapters(remote.chapters, bookID: remote.summary.id)
            }
        } catch {
            guard gen == loadGeneration else { return }
            isLoading = false
            if detail == nil || (detail?.chapters.isEmpty ?? true) {
                errorMessage = error.localizedDescription
            } else if forceRemote {
                banner.show("刷新目录失败：\(error.localizedDescription)", tone: .error)
            }
        }
    }

    private func toggleShelf(_ book: BookSummaryDTO) async {
        let next = !inShelf
        do {
            try await container.persistence.upsertBook(book, addToShelf: next)
            inShelf = next
            container.notifyLibraryChanged()
            banner.show(next ? "已加入书架" : "已移出书架", tone: .success)
        } catch {
            banner.show("更新书架失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
