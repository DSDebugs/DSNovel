import SwiftUI
import SwiftData
import UIKit

struct BookDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var detailModel: BookDetailModel
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var player = PlayerEngine.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var settings = AppSettingsStore.shared

    @State private var isIntroExpanded = false
    @State private var showInlineSearch = false
    @State private var showRangeDownloadSheet = false
    @State private var pendingDeleteSnapshot: ChapterRowSnapshot?
    @State private var showClearAllDownloadsConfirm = false
    @State private var ambientColor: Color = .dsSurfaceBase
    /// 头部滚出屏幕后，导航栏才显示书名（避免与头部大标题重复）
    @State private var showNavTitle = false

    init(book: BookRef, preferDownloaded: Bool = false) {
        self._detailModel = State(
            initialValue: BookDetailModel(book: book, preferDownloaded: preferDownloaded)
        )
    }

    private var savedBook: Book? {
        libraryStore.book(for: detailModel.currentBookRef.id, fallbackContext: modelContext)
    }

    private var currentSource: PluginRecord? {
        sourceStore.source(for: detailModel.currentBookRef.sourceID)
    }

    private var isPlayingThisBook: Bool {
        player.currentBookID == detailModel.currentBookRef.id && player.currentChapter != nil
    }

    private var liveChapterIndex: Int {
        if isPlayingThisBook {
            if player.currentChapterOneBasedIndex > 0 {
                return player.currentChapterOneBasedIndex
            }
            if let curID = player.currentChapter?.id,
               let idx = detailModel.chapters.firstIndex(where: { $0.id == curID }) {
                return idx + 1
            }
        }
        return savedBook?.lastChapterIndex ?? 0
    }

    private var activeChapterTitle: String? {
        if isPlayingThisBook, let curTitle = player.currentChapter?.title, !curTitle.isEmpty {
            return curTitle
        }
        if let savedID = savedBook?.lastChapterID,
           let matched = detailModel.chapters.first(where: { $0.id == savedID }) {
            return matched.title
        }
        if let savedIdx = savedBook?.lastChapterIndex,
           savedIdx > 0,
           detailModel.chapters.indices.contains(savedIdx - 1) {
            return detailModel.chapters[savedIdx - 1].title
        }
        if let savedTitle = savedBook?.lastChapterTitle, !savedTitle.isEmpty {
            return savedTitle
        }
        return nil
    }

    private var bookDownloadSummary: DownloadSummary? {
        _ = downloadManager.stateVersion
        return downloadManager.summariesByBookID[detailModel.currentBookRef.id]
    }

    private var currentQualityTitle: String {
        let tier = settings.audioQualityTier.normalizedForSelection
        let label = DownloadsDataHelper.qualityTierLabel(for: tier.rawValue)
        return label.isEmpty ? tier.title : label
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let dlSummary = bookDownloadSummary
        let dlCount = dlSummary?.completedCount ?? 0
        let activeDLCount = dlSummary?.activeCount ?? 0
        let failedDLCount = dlSummary?.failedCount ?? 0
        let dlBytesText = formatBytes(dlSummary?.totalBytes ?? 0)
        let staleDLCount = downloadManager.staleCompletedCount(forBookID: detailModel.currentBookRef.id)
        let qualityTitle = currentQualityTitle
        let inShelfNow = libraryStore.isBookInShelf(detailModel.currentBookRef.id, fallbackContext: modelContext)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s5) {
                    if currentSource?.healthState == .unavailable {
                        unavailableBanner
                    }

                    BookHeader(
                        book: detailModel.currentBookRef,
                        sourceName: currentSource?.name ?? detailModel.currentBookRef.sourceID,
                        sourceHealth: DSSourceHealthKind(rawValue: currentSource?.lastCheckStatus ?? "") ?? .untested,
                        sourceLatencyMs: (currentSource?.lastLatencyMs ?? -1) > 0 ? currentSource?.lastLatencyMs : nil,
                        requiresLogin: currentSource?.requiresLogin ?? false,
                        isLoggedIn: currentSource?.loggedIn ?? true,
                        totalChapters: max(detailModel.chapters.count, detailModel.currentBookRef.chapterCount),
                        statusText: detailModel.statusText,
                        onTapLogin: {
                            AuthCoordinator.shared.presentLogin(forSourceID: detailModel.currentBookRef.sourceID)
                        },
                        onCoverLoaded: { img in
                            ambientColor = CoverAmbientColor.color(from: img, cacheKey: detailModel.currentBookRef.id)
                        }
                    )

                    PrimaryActions(
                        isLoadingChapters: detailModel.isLoadingChapters,
                        isPlayingThisBook: isPlayingThisBook,
                        isEnginePlaying: isPlayingThisBook && player.state == .playing,
                        hasProgress: isPlayingThisBook || (savedBook?.lastChapterIndex ?? 0) > 0,
                        activeChapterTitle: activeChapterTitle.map {
                            BookTitleFormatter.stripBookPrefix(from: $0, bookTitle: detailModel.currentBookRef.title)
                        },
                        downloadedCount: dlCount,
                        downloadedBytesText: dlCount > 0 ? dlBytesText : nil,
                        activeDownloadCount: activeDLCount,
                        inShelf: inShelfNow,
                        onPrimaryPlay: { startOrResumePlayback() },
                        onViewDownloadedChapters: {
                            DSHapticPolicy.fire(.selection)
                            detailModel.isShowingDownloadedOnly = true
                        },
                        onDownloadAll: { detailModel.enqueueRange(1, detailModel.chapters.count) },
                        onDownloadUnread: {
                            let s = max(1, liveChapterIndex)
                            detailModel.enqueueRange(s, detailModel.chapters.count)
                        },
                        onDownloadNext10: {
                            let s = max(1, liveChapterIndex)
                            detailModel.enqueueRange(s, min(detailModel.chapters.count, s + 9))
                        },
                        onDownloadNext30: {
                            let s = max(1, liveChapterIndex)
                            detailModel.enqueueRange(s, min(detailModel.chapters.count, s + 29))
                        },
                        onDownloadCustomRange: { showRangeDownloadSheet = true },
                        onClearBookDownloads: { showClearAllDownloadsConfirm = true },
                        onOpenDownloads: { AppRouter.shared.open(.downloads) },
                        onToggleShelf: {
                            detailModel.toggleShelfMembership(libraryStore: libraryStore, context: modelContext)
                        }
                    )

                    if staleDLCount > 0 {
                        staleQualityBanner(staleCount: staleDLCount, qualityTitle: qualityTitle)
                    }

                    introSection
                    chapterArea(
                        proxy: proxy,
                        downloadedCount: dlCount,
                        activeDownloadCount: activeDLCount,
                        failedDownloadCount: failedDLCount,
                        downloadedBytesText: dlBytesText,
                        qualityTitle: qualityTitle
                    )
                }
                .padding(.vertical, Spacing.s3)
                .background(alignment: .top) {
                    LinearGradient(
                        colors: [ambientColor.opacity(0.26), ambientColor.opacity(0.10), Color.dsSurfaceBase.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 420)
                    .ignoresSafeArea(edges: .top)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 140
            } action: { _, newValue in
                if showNavTitle != newValue {
                    withAnimation(Motion.quick) { showNavTitle = newValue }
                }
            }
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle(showNavTitle ? BookTitleFormatter.split(detailModel.currentBookRef.title).main : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar(downloadedCount: dlCount) }
        .sheet(isPresented: $showRangeDownloadSheet) {
            RangeDownloadSheet(
                totalChapters: detailModel.chapters.count,
                currentChapterIndex: max(1, liveChapterIndex),
                onConfirmRange: { s, e in detailModel.enqueueRange(s, e) },
                onClose: { showRangeDownloadSheet = false }
            )
        }
        .alert(
            pendingDeleteSnapshot.map { snap in
                let sizePart = snap.downloadedBytes > 0 ? "（\(formatBytes(snap.downloadedBytes))）" : ""
                return "确认删除「\(snap.chapter.title)」的离线音频文件\(sizePart)？"
            } ?? "确认删除该章节离线文件？",
            isPresented: Binding(
                get: { pendingDeleteSnapshot != nil },
                set: { if !$0 { pendingDeleteSnapshot = nil } }
            )
        ) {
            Button("删除离线文件", role: .destructive) {
                if let snap = pendingDeleteSnapshot {
                    detailModel.confirmDeleteChapterDownload(snap)
                }
                pendingDeleteSnapshot = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteSnapshot = nil
            }
        } message: {
            Text("删除后将释放本地存储空间，再次收听该章节需联网或重新下载。")
        }
        .alert(
            "确认清空《\(detailModel.currentBookRef.title)》全部 \(dlCount) 章已下载音频（\(dlBytesText)）？",
            isPresented: $showClearAllDownloadsConfirm
        ) {
            Button("清空全部已下载章节", role: .destructive) {
                detailModel.confirmClearAllBookDownloads()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后本书所有离线音频文件将被彻底移除。")
        }
        .task {
            downloadManager.modelContext = modelContext
            downloadManager.reconcileCompletedFiles()
            libraryStore.markUpdateRead(bookID: detailModel.currentBookRef.id)
            ChapterProgressCache.shared.loadBookIfNeeded(detailModel.currentBookRef.id)
            await detailModel.loadChaptersIfNeeded(forceRefresh: false)
            let summary = downloadManager.summariesByBookID[detailModel.currentBookRef.id]
            let activeID = isPlayingThisBook ? player.currentChapter?.id : nil
            detailModel.applyInitialPresentationIfNeeded(
                downloadedCount: summary?.completedCount ?? 0,
                activeDownloadCount: summary?.activeCount ?? 0,
                activeChapterID: activeID,
                savedChapterID: savedBook?.lastChapterID,
                savedChapterIndex: savedBook?.lastChapterIndex
            )
        }
        .onDisappear {
            detailModel.cancelPendingTasks()
        }
    }

    private var unavailableBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("当前书源响应异常，可优先收听已下载章节或刷新重试")
                .font(DSTypography.caption.weight(.medium))
                .foregroundStyle(.orange)
            Spacer()
            Button("刷新重试") {
                Task { await detailModel.loadChaptersIfNeeded(forceRefresh: true) }
            }
            .font(DSTypography.caption.weight(.semibold))
            .foregroundStyle(Color.dsAccent)
        }
        .padding(Spacing.s3)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.orange.opacity(0.14)))
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    private func staleQualityBanner(staleCount: Int, qualityTitle: String) -> some View {
        HStack(spacing: Spacing.s2) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("有 \(staleCount) 章离线音频为旧音质")
                .font(DSTypography.caption.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: Spacing.s2)
            Button("按「\(qualityTitle)」重下") {
                redownloadAllStaleChapters(qualityTitle: qualityTitle)
            }
            .font(DSTypography.caption.weight(.semibold))
            .foregroundStyle(Color.dsOnAccent)
            .padding(.horizontal, Spacing.s3)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.dsAccent))
            .buttonStyle(.plain)
        }
        .padding(Spacing.s3)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ToolbarContentBuilder
    private func detailToolbar(downloadedCount: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await detailModel.loadChaptersIfNeeded(forceRefresh: true) }
                } label: {
                    Label("刷新章节目录", systemImage: "arrow.clockwise")
                }
                Button {
                    detailModel.isShowingDownloadedOnly.toggle()
                } label: {
                    Label(
                        detailModel.isShowingDownloadedOnly ? "显示全部章节" : "查看已下载章节（\(downloadedCount)）",
                        systemImage: "checkmark.circle"
                    )
                }
                Button {
                    UIPasteboard.general.string = detailModel.currentBookRef.bookURL
                    BannerCenter.shared.show("已复制书籍链接", kind: .info)
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
                if currentSource?.requiresLogin == true {
                    Button {
                        AuthCoordinator.shared.presentLogin(forSourceID: detailModel.currentBookRef.sourceID)
                    } label: {
                        Label("书源网页登录", systemImage: "person.badge.key")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text(detailModel.cleanedIntro)
                .font(DSTypography.subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(isIntroExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.s2) {
                Button {
                    let expanding = !isIntroExpanded
                    withAnimation(Motion.snappy) {
                        isIntroExpanded = expanding
                    }
                    if expanding && !detailModel.hasFetchedFullIntro {
                        Task {
                            await detailModel.loadFullIntroIfNeeded()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isIntroExpanded ? "收起简介" : "展开简介")
                        Image(systemName: isIntroExpanded ? "chevron.up" : "chevron.down")
                            .font(DSTypography.caption2)
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
                }
                .buttonStyle(.plain)

                if detailModel.isLoadingIntro {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在加载完整简介…")
                        .font(DSTypography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ViewBuilder
    private func chapterArea(
        proxy: ScrollViewProxy,
        downloadedCount: Int,
        activeDownloadCount: Int,
        failedDownloadCount: Int,
        downloadedBytesText: String,
        qualityTitle: String
    ) -> some View {
        if detailModel.isLoadingChapters && detailModel.chapters.isEmpty {
            DSSkeleton(mode: .chapters(rows: 8))
        } else if let err = detailModel.chapterError, detailModel.chapters.isEmpty {
            let kind = UserFacingError.from(err, sourceName: currentSource?.name ?? "当前书源")
            DSStateView(
                kind: kind,
                messageOverride: UserFacingError.messageOverride(for: err),
                onPrimary: {
                    if case .needLogin = kind {
                        AuthCoordinator.shared.presentLogin(forSourceID: detailModel.currentBookRef.sourceID)
                    } else if case .needVerify = kind {
                        AuthCoordinator.shared.presentLogin(forSourceID: detailModel.currentBookRef.sourceID)
                    } else if case .vipChapter = kind {
                        AppRouter.shared.openBuiltinParser(sourceID: detailModel.currentBookRef.sourceID)
                    } else {
                        Task { await detailModel.loadChaptersIfNeeded(forceRefresh: true) }
                    }
                },
                onSecondary: {
                    AppRouter.shared.open(.sourceDetail(id: detailModel.currentBookRef.sourceID, focus: nil))
                }
            )
        } else {
            let currentPlayingID = isPlayingThisBook ? player.currentChapter?.id : nil
            let livePosMs: Int? = nil
            let snapshots = detailModel.visibleChapterSnapshots(
                currentPlayingChapterID: currentPlayingID,
                isEnginePlaying: player.state == .playing,
                currentPlayingPositionMs: livePosMs
            )
            let bookID = detailModel.currentBookRef.id
            let staleContext = ChapterStaleQualityContext(
                bookID: bookID,
                stateVersion: downloadManager.stateVersion,
                currentQualityTitle: qualityTitle,
                isChapterStale: { chapterID in
                    downloadManager.isChapterQualityStale(bookID: bookID, chapterID: chapterID)
                },
                onRedownloadStale: { chapterID in
                    redownloadStaleChapter(chapterID: chapterID, qualityTitle: qualityTitle)
                }
            )
            ChapterSection(
                totalCount: detailModel.chapters.count,
                downloadedCount: downloadedCount,
                activeDownloadCount: activeDownloadCount,
                failedDownloadCount: failedDownloadCount,
                downloadedBytesText: downloadedBytesText,
                segments: detailModel.segments,
                selectedSegmentIndex: $detailModel.selectedSegmentIndex,
                isShowingDownloadedOnly: $detailModel.isShowingDownloadedOnly,
                isAscending: $detailModel.isAscending,
                searchKeyword: $detailModel.chapterSearchKeyword,
                showInlineSearch: $showInlineSearch,
                snapshots: snapshots,
                onLocateCurrent: {
                    locateCurrentOrSavedChapter(proxy: proxy, currentPlayingID: currentPlayingID)
                },
                onSelectSnapshot: { snap in
                    DSHapticPolicy.fire(.chapterSwitch)
                    if player.currentBookID == detailModel.currentBookRef.id,
                       player.currentChapter?.id == snap.chapter.id {
                        player.togglePlayPause()
                    } else {
                        player.startPlayback(
                            book: detailModel.currentBookRef,
                            chapters: detailModel.chapters,
                            startChapter: snap.chapter,
                            initialPositionMs: snap.savedPositionMs
                        )
                    }
                },
                onDownloadAction: { snap in
                    handleChapterDownloadOrDeleteTap(snap)
                },
                onRetryAllFailed: {
                    downloadManager.retryFailedItems(forBookID: detailModel.currentBookRef.id)
                    BannerCenter.shared.show("已重试失败章节", kind: .info)
                },
                onClearAllDownloads: {
                    showClearAllDownloadsConfirm = true
                },
                onDownloadNext10: {
                    let s = max(1, liveChapterIndex)
                    detailModel.enqueueRange(s, min(detailModel.chapters.count, s + 9))
                },
                onToggleFinished: { snap in
                    detailModel.toggleFinished(chapterID: snap.id)
                },
                onCopyTitle: { snap in
                    UIPasteboard.general.string = snap.chapter.title
                    BannerCenter.shared.show("已复制章节标题", kind: .info)
                }
            )
            .environment(\.chapterStaleQualityContext, staleContext)
        }
    }

    private func redownloadStaleChapter(chapterID: String, qualityTitle: String) {
        let count = downloadManager.refreshStaleQualityItems(
            bookID: detailModel.currentBookRef.id,
            chapterIDs: [chapterID]
        )
        if count > 0 {
            DSHapticPolicy.fire(.success)
            BannerCenter.shared.show(
                "已按「\(qualityTitle)」重新下载 \(count) 章（旧文件将在成功后覆盖）",
                kind: .success,
                bypassDeduplication: true
            )
        } else {
            let bookID = detailModel.currentBookRef.id
            let isReDL = downloadManager.isReDownloading(bookID: bookID, chapterID: chapterID)
            let isStale = downloadManager.isChapterQualityStale(bookID: bookID, chapterID: chapterID)
            let text = BookDetailModel.chapterDownloadBannerCopy(added: 0, isReDownloading: isReDL, isStale: isStale)
            BannerCenter.shared.show(text, kind: .info)
        }
    }

    private func redownloadAllStaleChapters(qualityTitle: String) {
        let count = downloadManager.refreshStaleQualityItems(bookID: detailModel.currentBookRef.id)
        if count > 0 {
            DSHapticPolicy.fire(.success)
            BannerCenter.shared.show(
                "已按「\(qualityTitle)」重新下载 \(count) 章（旧文件将在成功后覆盖）",
                kind: .success,
                bypassDeduplication: true
            )
        } else {
            BannerCenter.shared.show("本书暂无需要重下的旧音质章节", kind: .info)
        }
    }

    private func handleChapterDownloadOrDeleteTap(_ snap: ChapterRowSnapshot) {
        let bookID = detailModel.currentBookRef.id
        if downloadManager.isReDownloading(bookID: bookID, chapterID: snap.chapter.id) {
            BannerCenter.shared.show("该章正在按新音质重下，旧离线文件仍可播放", kind: .info)
            return
        }
        let realState = downloadManager.downloadState(
            bookID: bookID,
            chapterID: snap.chapter.id
        )
        if realState == .completed {
            pendingDeleteSnapshot = snap
        } else {
            detailModel.startOrRetryChapterDownload(snap)
        }
    }

    private func locateCurrentOrSavedChapter(proxy: ScrollViewProxy, currentPlayingID: String?) {
        DSHapticPolicy.fire(.selection)
        if let located = detailModel.prepareToLocateChapter(
            currentPlayingChapterID: currentPlayingID,
            savedChapterID: savedBook?.lastChapterID,
            savedChapterIndex: savedBook?.lastChapterIndex
        ) {
            showInlineSearch = false
            if located.didSwitchContext {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(65))
                    withAnimation(Motion.snappy) {
                        proxy.scrollTo(located.targetID, anchor: .center)
                    }
                }
            } else {
                withAnimation(Motion.snappy) {
                    proxy.scrollTo(located.targetID, anchor: .center)
                }
            }
        } else if let firstID = detailModel.chapters.first?.id {
            detailModel.isShowingDownloadedOnly = false
            detailModel.selectedSegmentIndex = 0
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(Motion.snappy) {
                    proxy.scrollTo(firstID, anchor: .center)
                }
            }
            BannerCenter.shared.show("当前尚无收听进度，已定位至第 1 章", kind: .info)
        }
    }

    private func startOrResumePlayback() {
        guard !detailModel.chapters.isEmpty else { return }
        DSHapticPolicy.fire(.playPause)
        if isPlayingThisBook {
            player.togglePlayPause()
            return
        }
        let target: ChapterDTO
        let initialMs: Int
        if let savedID = savedBook?.lastChapterID,
           let matched = detailModel.chapters.first(where: { $0.id == savedID }) {
            target = matched
            initialMs = savedBook?.lastPositionMs ?? 0
        } else if let savedIdx = savedBook?.lastChapterIndex,
                  savedIdx > 0,
                  detailModel.chapters.indices.contains(savedIdx - 1) {
            target = detailModel.chapters[savedIdx - 1]
            initialMs = savedBook?.lastPositionMs ?? 0
        } else {
            target = detailModel.chapters[0]
            initialMs = ChapterProgressCache.shared.progress(
                bookID: detailModel.currentBookRef.id,
                chapterID: target.id
            )?.positionMs ?? 0
        }
        player.startPlayback(
            book: detailModel.currentBookRef,
            chapters: detailModel.chapters,
            startChapter: target,
            initialPositionMs: initialMs
        )
    }
}
