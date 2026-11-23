import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSStorage
import SwiftUI
import UIKit

/// 书籍详情页（1:1 复刻 v2.8：环境光渐变 + 滚动 >140pt 显示导航书名 + 4 层头部 + 52pt 主操作栏 + 2 行折叠简介 + 100 章分段目录）
struct BookDetailView: View {
    @Environment(\.accessibilityReduceMotion) var systemReduceMotion
    @Environment(\.dsReduceMotion) var appReduceMotion
    @Environment(AppContainer.self) var container
    @Environment(AppRouter.self) var router
    @Environment(AppSettingsStore.self) var settings
    @Environment(PlaybackCoordinator.self) var playback
    @Environment(DownloadCoordinator.self) var downloads
    @Environment(DSBannerCoordinator.self) var banner

    let initialBook: BookSummaryDTO
    @State var detail: BookDetailDTO?
    @State var cleanedIntro: String
    @State var isLoading = true
    @State var errorMessage: String?
    @State var inShelf = false
    @State var resumeChapterIndex: Int?
    @State var resumeChapterTitle: String?
    @State var loadGeneration: UInt64 = 0

    @State var segments: [ChapterSegmentItem] = []
    @State var selectedSegmentIndex = 0
    @State var isShowingDownloadedOnly = false
    @State var isAscending = true
    @State var searchKeyword = ""
    @State var showInlineSearch = false
    @State var finishedIndices: Set<Int> = []
    @State var didApplyInitialPresentation = false

    @State var isIntroExpanded = false
    @State var introCollapsedHeight: CGFloat = 0
    @State var introFullHeight: CGFloat = 0
    @State var ambientColor: Color = DSColors.surfaceBase
    @State var showNavTitle = false

    @State var showRangeDownload = false
    @State var pendingDeleteSnapshot: ChapterRowSnapshot?
    @State var showClearAllDownloadsConfirm = false

    init(book: BookSummaryDTO) {
        self.initialBook = book
        _cleanedIntro = State(initialValue: BookDetailHelper.cleanHTML(book.intro))
    }

    var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    var currentBook: BookSummaryDTO { detail?.summary ?? initialBook }
    var chapters: [ChapterDTO] { detail?.chapters ?? [] }

    var isPlayingThisBook: Bool {
        playback.currentBook?.id == currentBook.id && playback.currentChapter != nil
    }

    var activeChapterIndex: Int? {
        if isPlayingThisBook { return playback.currentChapterIndex }
        return resumeChapterIndex
    }

    var activeChapterTitle: String? {
        if isPlayingThisBook, let title = playback.currentChapter?.title, !title.isEmpty {
            return title
        }
        if let idx = resumeChapterIndex, chapters.indices.contains(idx) {
            return chapters[idx].title
        }
        return resumeChapterTitle
    }

    private var shouldShowIntroToggle: Bool {
        guard BookDetailHelper.hasIntroContent(cleanedIntro) else { return false }
        if isIntroExpanded { return true }
        return introCollapsedHeight > 0 && introFullHeight > introCollapsedHeight + 1
    }

    var body: some View {
        let dlOverview = BookDetailHelper.summarizeDownloads(
            bookID: currentBook.id,
            records: downloads.manualRecords
        )
        let snapshots = BookDetailHelper.buildSnapshots(
            bookTitle: currentBook.title,
            chapters: chapters,
            segments: segments,
            selectedSegmentIndex: selectedSegmentIndex,
            isShowingDownloadedOnly: isShowingDownloadedOnly,
            isAscending: isAscending,
            searchKeyword: searchKeyword,
            currentPlayingIndex: isPlayingThisBook ? playback.currentChapterIndex : nil,
            isEnginePlaying: playback.state.isPlaying,
            finishedIndices: finishedIndices,
            downloadOverview: dlOverview,
            isWaitingForWiFi: downloads.isWaitingForWiFi
        )
        let navTitle = BookTitleFormatter.split(BookTitleFormatter.cleanTitle(currentBook.title)).main

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.s5) {
                    BookHeader(
                        book: currentBook,
                        pipeline: container.coverPipeline,
                        sourceName: currentBook.sourceName.isEmpty ? currentBook.sourceID : currentBook.sourceName,
                        totalChapters: max(chapters.count, currentBook.totalChapters),
                        statusText: currentBook.statusText,
                        onTapNarrator: { name in router.searchByNarrator(name) },
                        onCoverLoaded: { img in
                            let next = CoverAmbientColor.color(from: img, cacheKey: currentBook.id)
                            if ambientColor != next { ambientColor = next }
                        }
                    )

                    PrimaryActions(
                        isLoadingChapters: isLoading && chapters.isEmpty,
                        hasChapters: !chapters.isEmpty,
                        isPlayingThisBook: isPlayingThisBook,
                        isEnginePlaying: isPlayingThisBook && playback.state.isPlaying,
                        hasProgress: isPlayingThisBook || resumeChapterIndex != nil,
                        activeChapterTitle: activeChapterTitle.map {
                            BookTitleFormatter.stripBookPrefix(from: $0, bookTitle: currentBook.title)
                        },
                        downloadedCount: dlOverview.completedCount,
                        activeDownloadCount: dlOverview.activeCount,
                        inShelf: inShelf,
                        onPrimaryPlay: { startOrResumePlayback() },
                        onViewDownloadedChapters: {
                            DSHaptics.selection()
                            isShowingDownloadedOnly = true
                        },
                        onDownloadAll: { enqueueRange(startZeroBased: 0, endZeroBased: max(0, chapters.count - 1)) },
                        onDownloadUnread: {
                            let s = max(0, activeChapterIndex ?? 0)
                            enqueueRange(startZeroBased: s, endZeroBased: max(0, chapters.count - 1))
                        },
                        onDownloadNext10: {
                            let s = max(0, activeChapterIndex ?? 0)
                            enqueueRange(startZeroBased: s, endZeroBased: min(max(0, chapters.count - 1), s + 9))
                        },
                        onDownloadNext30: {
                            let s = max(0, activeChapterIndex ?? 0)
                            enqueueRange(startZeroBased: s, endZeroBased: min(max(0, chapters.count - 1), s + 29))
                        },
                        onDownloadCustomRange: { showRangeDownload = true },
                        onClearBookDownloads: { showClearAllDownloadsConfirm = true },
                        onOpenDownloads: { router.push(.downloads) },
                        onToggleShelf: { Task { await toggleShelf(currentBook) } }
                    )

                    introSection
                    chapterArea(proxy: proxy, dlOverview: dlOverview, snapshots: snapshots)
                }
                .padding(.vertical, DSSpacing.sm)
                .background(alignment: .top) {
                    LinearGradient(
                        colors: [ambientColor.opacity(0.32), ambientColor.opacity(0.12), DSColors.surfaceBase.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 420)
                    .ignoresSafeArea(edges: .top)
                }
            }
            .contentMargins(.bottom, 96, for: .scrollContent)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 140
            } action: { _, newValue in
                if showNavTitle != newValue {
                    DSMotion.withResolved(DSMotion.quick, reduceMotion: reduceMotion) { showNavTitle = newValue }
                }
            }
        }
        .background(DSColors.surfaceBase)
        .navigationTitle(showNavTitle ? navTitle : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar(downloadedCount: dlOverview.completedCount) }
        .sheet(isPresented: $showRangeDownload) {
            RangeDownloadSheet(
                book: currentBook,
                chapters: chapters,
                currentChapterIndex: activeChapterIndex ?? 0
            ) { showRangeDownload = false }
        }
        .alert(
            pendingDeleteSnapshot.map { snap in
                let sizePart = snap.downloadedBytes > 0
                    ? "（\(ByteCountFormatter.string(fromByteCount: snap.downloadedBytes, countStyle: .file))）"
                    : ""
                return "确认删除「\(snap.chapter.title)」的离线音频文件\(sizePart)？"
            } ?? "确认删除该章节离线文件？",
            isPresented: Binding(
                get: { pendingDeleteSnapshot != nil },
                set: { if !$0 { pendingDeleteSnapshot = nil } }
            )
        ) {
            Button("删除离线文件", role: .destructive) {
                if let snap = pendingDeleteSnapshot, !snap.downloadRecordID.isEmpty {
                    Task {
                        await downloads.cancelAndDelete(id: snap.downloadRecordID)
                        banner.show("已删除第 \(snap.displayIndex) 章离线文件", tone: .info)
                    }
                }
                pendingDeleteSnapshot = nil
            }
            Button("取消", role: .cancel) { pendingDeleteSnapshot = nil }
        } message: {
            Text("删除后将释放本地存储空间，再次收听该章节需联网或重新下载。")
        }
        .alert(
            "确认清空《\(navTitle)》全部 \(dlOverview.completedCount) 章已下载音频？",
            isPresented: $showClearAllDownloadsConfirm
        ) {
            Button("清空全部已下载章节", role: .destructive) {
                Task {
                    await downloads.deleteBookDownloads(bookID: currentBook.id)
                    banner.show("已清空《\(navTitle)》全部离线章节", tone: .info)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后本书所有离线音频文件将被彻底移除。")
        }
        .task(id: initialBook.id) { await loadDetail(forceRemote: false) }
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await refreshShelfStatus() }
        }
    }

    @ToolbarContentBuilder
    private func detailToolbar(downloadedCount: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await loadDetail(forceRemote: true) }
                } label: {
                    Label("刷新章节目录", systemImage: "arrow.clockwise")
                }
                Button {
                    isShowingDownloadedOnly.toggle()
                } label: {
                    Label(
                        isShowingDownloadedOnly ? "显示全部章节" : "查看已下载章节（\(downloadedCount)）",
                        systemImage: "checkmark.circle"
                    )
                }
                Button {
                    UIPasteboard.general.string = currentBook.bookURL
                    banner.show("已复制书籍链接", tone: .info)
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(cleanedIntro)
                .font(DSTypography.subtitle)
                .foregroundStyle(DSColors.inkSecondary)
                .lineLimit(isIntroExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    if !isIntroExpanded && abs(introCollapsedHeight - newHeight) > 0.5 { introCollapsedHeight = newHeight }
                }
                .background {
                    Text(cleanedIntro)
                        .font(DSTypography.subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in if abs(introFullHeight - h) > 0.5 { introFullHeight = h } }
                }

            if shouldShowIntroToggle {
                HStack {
                    Spacer()
                    Button {
                        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                            isIntroExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(isIntroExpanded ? "收起" : "展开")
                            Image(systemName: isIntroExpanded ? "chevron.up" : "chevron.down")
                                .font(DSTypography.caption2)
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.6)
                )
        )
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    @ViewBuilder
    private func chapterArea(
        proxy: ScrollViewProxy,
        dlOverview: BookDownloadOverview,
        snapshots: [ChapterRowSnapshot]
    ) -> some View {
        if isLoading && chapters.isEmpty {
            DSSkeleton(mode: .chapters(rows: 8))
        } else if let err = errorMessage, chapters.isEmpty {
            DSStateView(
                kind: .error(detail: err),
                onPrimary: { Task { await loadDetail(forceRemote: true) } },
                onSecondary: { router.push(.sourceDetail(sourceID: currentBook.sourceID)) }
            )
        } else {
            ChapterSection(
                totalCount: chapters.count,
                downloadedCount: dlOverview.completedCount,
                activeDownloadCount: dlOverview.activeCount,
                failedDownloadCount: dlOverview.failedCount,
                segments: segments,
                selectedSegmentIndex: $selectedSegmentIndex,
                isShowingDownloadedOnly: $isShowingDownloadedOnly,
                isAscending: $isAscending,
                searchKeyword: $searchKeyword,
                showInlineSearch: $showInlineSearch,
                snapshots: snapshots,
                onLocateCurrent: { locateCurrentChapter(proxy: proxy) },
                onSelectSnapshot: { snap in handleChapterSelect(snap) },
                onDownloadAction: { snap in handleChapterDownloadTap(snap) },
                onRetryAllFailed: { Task { await retryFailedForBook(dlOverview) } },
                onClearAllDownloads: { showClearAllDownloadsConfirm = true },
                onDownloadNext10: {
                    let s = max(0, activeChapterIndex ?? 0)
                    enqueueRange(startZeroBased: s, endZeroBased: min(max(0, chapters.count - 1), s + 9))
                },
                onToggleFinished: { snap in
                    if finishedIndices.contains(snap.arrayIndex) {
                        finishedIndices.remove(snap.arrayIndex)
                    } else {
                        finishedIndices.insert(snap.arrayIndex)
                    }
                },
                onCopyTitle: { snap in
                    UIPasteboard.general.string = snap.chapter.title
                    banner.show("已复制章节标题", tone: .info)
                }
            )
        }
    }
}
