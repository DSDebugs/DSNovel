import SwiftUI
import SwiftData
import UIKit

struct BookDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var detailModel: BookDetailModel
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var player = PlayerEngine.shared

    @State private var isIntroExpanded = false
    @State private var showInlineSearch = false
    @State private var showSourceSwitchSheet = false
    @State private var showRangeDownloadSheet = false
    @State private var ambientColor: Color = .dsSurfaceBase

    init(book: BookRef, alternatives: [BookRef] = []) {
        self._detailModel = State(initialValue: BookDetailModel(book: book, alternatives: alternatives))
    }

    private var savedBook: Book? {
        libraryStore.allShelfBooks.first(where: { $0.id == detailModel.currentBookRef.id })
            ?? (libraryStore.continueBook?.id == detailModel.currentBookRef.id ? libraryStore.continueBook : nil)
            ?? libraryStore.recentBooks.first(where: { $0.id == detailModel.currentBookRef.id })
    }

    private var currentSource: PluginRecord? {
        sourceStore.source(for: detailModel.currentBookRef.sourceID)
    }

    var body: some View {
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
                        alternativesCount: detailModel.alternatives.count,
                        totalChapters: max(detailModel.chapters.count, detailModel.currentBookRef.chapterCount),
                        statusText: detailModel.statusText,
                        onTapSwitchSource: { showSourceSwitchSheet = true },
                        onTapLogin: { AuthCoordinator.shared.presentLogin(forSourceID: detailModel.currentBookRef.sourceID) },
                        onCoverLoaded: { img in
                            ambientColor = CoverAmbientColor.color(from: img, cacheKey: detailModel.currentBookRef.id)
                        }
                    )

                    PrimaryActions(
                        isLoadingChapters: detailModel.isLoadingChapters,
                        hasProgress: (savedBook?.lastChapterIndex ?? 0) > 0,
                        lastChapterIndex: savedBook?.lastChapterIndex ?? 0,
                        lastPositionText: savedBook?.formattedPositionText ?? "00:00",
                        lastPlayedRelativeText: savedBook?.formattedLastPlayedAtText,
                        inShelf: savedBook?.inShelf ?? false,
                        onPrimaryPlay: { startOrResumePlayback() },
                        onDownloadAll: { detailModel.enqueueRange(1, detailModel.chapters.count) },
                        onDownloadUnread: { detailModel.enqueueRange(max(1, savedBook?.lastChapterIndex ?? 1), detailModel.chapters.count) },
                        onDownloadNext10: {
                            let s = max(1, savedBook?.lastChapterIndex ?? 1)
                            detailModel.enqueueRange(s, min(detailModel.chapters.count, s + 9))
                        },
                        onDownloadNext30: {
                            let s = max(1, savedBook?.lastChapterIndex ?? 1)
                            detailModel.enqueueRange(s, min(detailModel.chapters.count, s + 29))
                        },
                        onDownloadCustomRange: { showRangeDownloadSheet = true },
                        onOpenDownloads: { AppRouter.shared.open(.downloads) },
                        onToggleShelf: { detailModel.toggleShelfMembership(savedBook: savedBook, libraryStore: libraryStore, context: modelContext) }
                    )

                    introSection
                    chapterArea(proxy: proxy)
                }
                .padding(.vertical, Spacing.s3)
                .background(alignment: .top) {
                    LinearGradient(colors: [ambientColor.opacity(0.32), Color.dsSurfaceBase], startPoint: .top, endPoint: .bottom)
                        .frame(height: 320)
                }
            }
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle(detailModel.currentBookRef.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .sheet(isPresented: $showSourceSwitchSheet) {
            SourceSwitchSheet(
                currentRef: detailModel.currentBookRef,
                candidates: detailModel.alternatives,
                sourceStore: sourceStore,
                onSelectCandidate: { candidate in
                    showSourceSwitchSheet = false
                    Task {
                        let curIdx = max(0, (savedBook?.lastChapterIndex ?? 1) - 1)
                        _ = await detailModel.switchSource(to: candidate, currentChapterIndex: curIdx, currentChapterTitle: savedBook?.lastChapterTitle ?? "", in: modelContext)
                    }
                },
                onClose: { showSourceSwitchSheet = false }
            )
        }
        .sheet(isPresented: $showRangeDownloadSheet) {
            RangeDownloadSheet(
                totalChapters: detailModel.chapters.count,
                onConfirmRange: { s, e in detailModel.enqueueRange(s, e) },
                onClose: { showRangeDownloadSheet = false }
            )
        }
        .task {
            libraryStore.markUpdateRead(bookID: detailModel.currentBookRef.id)
            ChapterProgressCache.shared.loadBookIfNeeded(detailModel.currentBookRef.id)
            await detailModel.loadChaptersIfNeeded(forceRefresh: false)
        }
    }

    private var unavailableBanner: some View {
        HStack {
            Text("当前来源不可用").font(DSTypography.cardTitle).foregroundStyle(.orange)
            Spacer()
            Button("换源") { showSourceSwitchSheet = true }.font(DSTypography.cardTitle).foregroundStyle(Color.dsAccent)
        }
        .padding(Spacing.s3)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.orange.opacity(0.14)))
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { Task { await detailModel.loadChaptersIfNeeded(forceRefresh: true) } } label: {
                    Label("刷新章节", systemImage: "arrow.clockwise")
                }
                Button {
                    UIPasteboard.general.string = detailModel.currentBookRef.bookURL
                    BannerCenter.shared.show("已复制", kind: .info)
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
                if currentSource?.requiresLogin == true {
                    Button { AuthCoordinator.shared.presentLogin(forSourceID: detailModel.currentBookRef.sourceID) } label: {
                        Label("书源网页登录", systemImage: "person.badge.key")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            Text(detailModel.cleanedIntro).font(DSTypography.subtitle).foregroundStyle(.secondary).lineLimit(isIntroExpanded ? nil : 3)
            Button(isIntroExpanded ? "收起" : "展开") { isIntroExpanded.toggle() }
                .font(DSTypography.caption.weight(.medium)).foregroundStyle(Color.dsAccent).buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ViewBuilder
    private func chapterArea(proxy: ScrollViewProxy) -> some View {
        if detailModel.isLoadingChapters && detailModel.chapters.isEmpty {
            DSSkeleton(mode: .chapters(rows: 8))
        } else if let err = detailModel.chapterError, detailModel.chapters.isEmpty {
            let kind = UserFacingError.from(err, sourceName: currentSource?.name ?? "当前书源")
            DSStateView(
                kind: kind,
                onPrimary: {
                    if case .needLogin = kind { AuthCoordinator.shared.presentLogin(forSourceID: detailModel.currentBookRef.sourceID) }
                    else if case .vipChapter = kind { AppRouter.shared.openBuiltinParser(sourceID: detailModel.currentBookRef.sourceID) }
                    else { Task { await detailModel.loadChaptersIfNeeded(forceRefresh: true) } }
                },
                onSecondary: { showSourceSwitchSheet = true }
            )
        } else {
            let currentPlayingID = (player.currentBookID == detailModel.currentBookRef.id) ? player.currentChapter?.id : nil
            let snapshots = detailModel.visibleChapterSnapshots(currentPlayingChapterID: currentPlayingID, isEnginePlaying: player.state == .playing, downloadItems: detailModel.currentBookDownloadMap())
            ChapterSection(
                totalCount: detailModel.chapters.count,
                segments: detailModel.segments,
                selectedSegmentIndex: $detailModel.selectedSegmentIndex,
                isAscending: $detailModel.isAscending,
                searchKeyword: $detailModel.chapterSearchKeyword,
                showInlineSearch: $showInlineSearch,
                snapshots: snapshots,
                onLocateCurrent: {
                    if let targetID = currentPlayingID ?? savedBook?.lastChapterID { proxy.scrollTo(targetID, anchor: .center) }
                },
                onSelectSnapshot: { snap in
                    DSHapticPolicy.fire(.chapterSwitch)
                    if player.currentBookID == detailModel.currentBookRef.id, player.currentChapter?.id == snap.chapter.id {
                        player.togglePlayPause()
                    } else {
                        player.startPlayback(book: detailModel.currentBookRef, chapters: detailModel.chapters, startChapter: snap.chapter, initialPositionMs: snap.savedPositionMs)
                    }
                },
                onDownloadAction: { snap in detailModel.handleChapterDownloadTap(snap) },
                onToggleFinished: { snap in detailModel.toggleFinished(chapterID: snap.id) },
                onCopyTitle: { snap in
                    UIPasteboard.general.string = snap.chapter.title
                    BannerCenter.shared.show("已复制", kind: .info)
                }
            )
        }
    }

    private func startOrResumePlayback() {
        guard !detailModel.chapters.isEmpty else { return }
        DSHapticPolicy.fire(.playPause)
        let target = detailModel.chapters.first(where: { $0.id == savedBook?.lastChapterID }) ?? detailModel.chapters[0]
        player.startPlayback(book: detailModel.currentBookRef, chapters: detailModel.chapters, startChapter: target, initialPositionMs: savedBook?.lastPositionMs ?? 0)
    }
}
