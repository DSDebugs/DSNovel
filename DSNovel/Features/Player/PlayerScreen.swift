import SwiftUI
import SwiftData
import UIKit

enum PlayerActiveSheet: String, Identifiable {
    case speed
    case audioEffects
    case sleep
    case chapters
    case downloads
    case skip
    case more

    var id: String { rawValue }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dsReduceMotion) private var reduceMotion

    @State private var player = PlayerEngine.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var activeSheet: PlayerActiveSheet?
    @State private var ambientColor: Color
    @State private var isBookFavorited: Bool = false
    @State private var heartBounceCount: Int = 0
    @State private var downloadBounceCount: Int = 0
    @GestureState private var dragOffset: CGFloat = 0

    init() {
        let currentBook = PlayerEngine.shared.currentBook
        let coverURL = currentBook?.cover ?? ""
        if !coverURL.isEmpty,
           let cachedImg = CoverImagePipeline.shared.cachedInMemory(for: coverURL, side: 280)
               ?? CoverImagePipeline.shared.cachedInMemory(for: coverURL, side: 96) {
            self._ambientColor = State(
                initialValue: CoverAmbientColor.color(from: cachedImg, cacheKey: currentBook?.id)
            )
        } else {
            self._ambientColor = State(initialValue: Color.dsAccent)
        }
        let initialFav = LibraryStore.shared.isBookInShelf(currentBook?.id)
        self._isBookFavorited = State(initialValue: initialFav)
    }

    private var currentSourceName: String {
        guard let sid = player.currentBook?.sourceID, !sid.isEmpty else { return "" }
        return sourceStore.sourceName(for: sid)
    }

    private var currentChapterDownloadState: ChapterDownloadState {
        guard let bid = player.currentBookID, let cid = player.currentChapter?.id else {
            return .notDownloaded
        }
        let state = downloadManager.downloadState(bookID: bid, chapterID: cid)
        if state != .notDownloaded {
            return state
        }
        if downloadManager.localFileURL(bookID: bid, chapterID: cid) != nil {
            return .completed
        }
        return .notDownloaded
    }

    private func syncFavoriteState() {
        isBookFavorited = libraryStore.isBookInShelf(player.currentBookID, fallbackContext: modelContext)
    }

    var body: some View {
        ZStack {
            PlayerAmbientBackground(
                primaryColor: ambientColor,
                isPlaying: player.state == .playing
            )

            VStack(spacing: 0) {
                PlayerHeader(
                    sourceName: currentSourceName,
                    streamBadgeText: player.streamStatusBadgeText,
                    sleepOption: player.sleepOption,
                    sleepRemainingSec: player.estimatedSleepRemainingSec,
                    onDismiss: { dismiss() },
                    onOpenAudioEffects: { activeSheet = .audioEffects },
                    onOpenSleepSheet: { activeSheet = .sleep },
                    onOpenMoreSheet: { activeSheet = .more }
                )

                Spacer(minLength: Spacing.s2)

                PlayerCoverSection(
                    coverURL: player.currentBook?.cover ?? "",
                    bookTitle: player.currentBook?.title ?? "有声书",
                    bookID: player.currentBookID,
                    ambientColor: ambientColor,
                    playbackState: player.state,
                    onDoubleTapPlayPause: {
                        DSHapticPolicy.fire(.playPause)
                        player.togglePlayPause()
                    },
                    onImageLoaded: { img in
                        ambientColor = CoverAmbientColor.color(from: img, cacheKey: player.currentBookID)
                    }
                )

                if let feedback = player.inlineFeedback {
                    inlineFeedbackPill(feedback)
                        .padding(.top, Spacing.s2)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }

                Spacer(minLength: Spacing.s3)

                if case .failed = player.state {
                    errorInlineCard
                        .padding(.horizontal, Spacing.pageHorizontal)
                        .padding(.bottom, Spacing.s3)
                }

                VStack(spacing: Spacing.s4) {
                    PlayerTitleRow(
                        chapterTitle: player.currentChapter?.title ?? "未选择章节",
                        bookTitle: player.currentBook?.title ?? "",
                        narrator: player.currentBook?.author ?? "",
                        downloadState: currentChapterDownloadState,
                        inShelf: isBookFavorited,
                        downloadBounceCount: downloadBounceCount,
                        heartBounceCount: heartBounceCount,
                        onTapChapterTitle: { activeSheet = .chapters },
                        onTapBookTitle: {
                            dismiss()
                            if let book = player.currentBook {
                                AppRouter.shared.open(.book(book))
                            }
                        },
                        onTapNarrator: { narrator in
                            dismiss()
                            AppRouter.shared.searchByNarrator(narrator)
                        },
                        onTapDownload: { handleCurrentChapterDownloadTap() },
                        onTapShelf: { toggleShelf() }
                    )

                    DSScrubber(
                        currentTimeSec: player.clock.currentTimeSec,
                        durationSec: player.clock.durationSec,
                        bufferedFraction: player.bufferedRange,
                        onSeek: { sec in player.seek(to: sec) }
                    )
                    .padding(.horizontal, Spacing.pageHorizontal)

                    PlayerControls(
                        isPlaying: player.state == .playing,
                        isBuffering: player.isBuffering,
                        canPlayPrevious: player.canPlayPreviousChapter,
                        canPlayNext: player.nextChapterAvailability != .none,
                        onPreviousChapter: {
                            DSHapticPolicy.fire(.chapterSwitch)
                            player.playPreviousChapter()
                        },
                        onSkipBackward: { player.skipBackward(15) },
                        onTogglePlay: {
                            DSHapticPolicy.fire(.playPause)
                            player.togglePlayPause()
                        },
                        onSkipForward: { player.skipForward(30) },
                        onNextChapter: {
                            DSHapticPolicy.fire(.chapterSwitch)
                            player.playNextChapter()
                        }
                    )

                    PlayerSecondaryRow(
                        speed: player.speed,
                        effectPreset: player.audioEffectPreset,
                        sleepOption: player.sleepOption,
                        sleepRemainingSec: player.estimatedSleepRemainingSec,
                        currentChapterIndex: player.currentChapterOneBasedIndex,
                        totalChapters: player.chapterQueue.count,
                        onOpenSpeed: { activeSheet = .speed },
                        onOpenAudioEffects: { activeSheet = .audioEffects },
                        onOpenSleep: { activeSheet = .sleep },
                        onOpenChapters: { activeSheet = .chapters }
                    )
                }
                .padding(.bottom, Spacing.s6)
            }
            .offset(y: max(0, dragOffset))
            .animation(Motion.resolve(Motion.follow, reduce: reduceMotion), value: dragOffset)
            .animation(Motion.resolve(Motion.snappy, reduce: reduceMotion), value: player.inlineFeedback?.id)
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
            syncFavoriteState()
            if let notice = PerBookSkipMigration.consumePendingNoticeIfNeeded() {
                player.showInlineToast(notice)
            }
        }
        .onChange(of: player.currentBookID) { _, _ in
            syncFavoriteState()
        }
        .onChange(of: libraryStore.shelfBookIDs) { _, _ in
            syncFavoriteState()
        }
        .onChange(of: player.inlineFeedback?.id) { _, _ in
            if let message = player.inlineFeedback?.message {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .updating($dragOffset) { value, state, _ in
                    if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) * 1.2 {
                        state = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                        dismiss()
                    }
                }
        )
        .sheet(item: $activeSheet, content: sheetContent)
    }

    private func inlineFeedbackPill(_ feedback: PlayerInlineFeedback) -> some View {
        HStack(spacing: Spacing.s2) {
            Image(systemName: feedback.canUndoIntroSkip ? "forward.frame.fill" : "info.circle.fill")
                .font(DSTypography.caption2)
                .foregroundStyle(Color.dsAccent)
            Text(feedback.message)
                .font(DSTypography.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            if feedback.canUndoIntroSkip {
                Button("撤销") {
                    DSHapticPolicy.fire(.selection)
                    player.undoIntroSkipForCurrentChapter()
                }
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(Color.dsAccent)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.68)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PlayerActiveSheet) -> some View {
        switch sheet {
        case .speed:
            SpeedSheet(player: player, onClose: { activeSheet = nil })
        case .audioEffects:
            AudioEffectsSheet(player: player, onClose: { activeSheet = nil })
        case .sleep:
            SleepSheet(player: player, onClose: { activeSheet = nil })
        case .chapters:
            ChapterListView(
                book: player.currentBook,
                chapters: player.chapterQueue,
                currentChapterID: player.currentChapter?.id,
                isPlaying: player.state == .playing,
                onSelectChapter: { ch in
                    if let book = player.currentBook {
                        let savedMs = ChapterProgressCache.shared.progress(bookID: book.id, chapterID: ch.id)?.positionMs ?? 0
                        player.startPlayback(book: book, chapters: player.chapterQueue, startChapter: ch, initialPositionMs: savedMs)
                    }
                },
                onOpenBatchDownload: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        activeSheet = .downloads
                    }
                },
                onClose: { activeSheet = nil }
            )
        case .downloads:
            PlayerDownloadSheet(
                player: player,
                onOpenGlobalDownloads: {
                    dismiss()
                    AppRouter.shared.open(.downloads)
                },
                onClose: { activeSheet = nil }
            )
        case .skip:
            SkipSheet(player: player, onClose: { activeSheet = nil })
        case .more:
            MoreSheet(
                player: player,
                onOpenSkip: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        activeSheet = .skip
                    }
                },
                onOpenAudioEffects: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        activeSheet = .audioEffects
                    }
                },
                onOpenDownloads: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        activeSheet = .downloads
                    }
                },
                onOpenBookDetail: {
                    dismiss()
                    if let book = player.currentBook {
                        AppRouter.shared.open(.book(book))
                    }
                },
                onClose: { activeSheet = nil }
            )
        }
    }

    private func handleCurrentChapterDownloadTap() {
        guard let book = player.currentBook, let ch = player.currentChapter else { return }
        switch currentChapterDownloadState {
        case .notDownloaded:
            do {
                _ = try downloadManager.enqueueChaptersWithCheck([ch], for: book, kind: "manual")
                downloadBounceCount &+= 1
                DSHapticPolicy.fire(.success)
                player.showInlineToast("已开始下载当前章节，再次点击可管理离线章节")
            } catch {
                DSHapticPolicy.fire(.error)
                player.showInlineToast(error.localizedDescription)
            }
        case .downloading, .completed, .failed:
            activeSheet = .downloads
        }
    }

    @ViewBuilder
    private var errorInlineCard: some View {
        let sourceID = player.currentBook?.sourceID ?? ""
        let sourceName = sourceStore.sourceName(for: sourceID)
        let kind: DSStateKind = {
            if let pErr = player.lastPluginError {
                return UserFacingError.from(pErr, sourceName: sourceName)
            }
            return .error(detail: nil)
        }()
        DSStateView(
            kind: kind,
            variant: .inline,
            onPrimary: {
                switch kind {
                case .needLogin, .needVerify:
                    AuthCoordinator.shared.presentLogin(forSourceID: sourceID)
                case .vipChapter:
                    dismiss()
                    AppRouter.shared.openBuiltinParser(sourceID: sourceID)
                case .offline:
                    if case .availableDownloaded(let nextCh) = player.nextChapterAvailability,
                       let book = player.currentBook {
                        player.startPlayback(book: book, chapters: player.chapterQueue, startChapter: nextCh)
                    } else {
                        player.retryCurrentChapter()
                    }
                default:
                    player.retryCurrentChapter()
                }
            },
            onSecondary: {
                dismiss()
                if let book = player.currentBook {
                    AppRouter.shared.open(.book(book))
                }
            }
        )
    }

    private func toggleShelf() {
        guard let bookRef = player.currentBook else { return }
        let nowInShelf = libraryStore.toggleShelfImmediate(
            for: bookRef,
            totalChapters: player.chapterQueue.count,
            context: modelContext
        )
        isBookFavorited = nowInShelf
        heartBounceCount &+= 1
        DSHapticPolicy.fire(nowInShelf ? .success : .selection)
        player.showInlineToast(nowInShelf ? "已加入书架" : "已从书架移除")
    }
}
