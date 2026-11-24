import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSStorage
import SwiftUI
import UIKit

/// 播放器弹窗统一路由枚举（全 8 弹窗：目录/定时/倍速/跳过/音效/音质/下载/更多）
enum PlayerSheetRoute: String, Identifiable {
    case chapters
    case sleep
    case speed
    case skip
    case effects
    case quality
    case download
    case more

    var id: String { rawValue }
}

/// 纯竖屏全屏播放器（1:1 复刻 v2.8：封面环境光渐变、下滑关闭、6 大子视图与 8 弹窗协调，保留 v3.0 音质作用域约束）
struct PlayerScreen: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Environment(AppContainer.self) var container
    @Environment(AppRouter.self) var router
    @Environment(AppSettingsStore.self) var settings
    @Environment(PlaybackCoordinator.self) var playback
    @Environment(DownloadCoordinator.self) var downloads
    @Environment(DSBannerCoordinator.self) var banner

    @State var activeSheet: PlayerSheetRoute?
    @State var pendingSheet: PlayerSheetRoute?
    @State var isInShelf = false
    @State var sourceName: String = ""
    @State var ambientColor: Color = DSColors.accent
    @State private var dragOffset: CGFloat = 0
    @State var heartBounceCount: Int = 0
    @State var downloadBounceCount: Int = 0

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    private var hasNoBook: Bool { playback.currentBook == nil }
    var supportsQualitySelection: Bool { container.isCurrentBookFromXimalaya }
    private var isFailedState: Bool {
        if case .failed = playback.state { return true }
        return false
    }
    private var failedMessage: String? {
        if case .failed(_, let message) = playback.state { return message }
        return nil
    }
    private var canPlayPrevious: Bool { !hasNoBook && playback.currentChapterIndex > 0 }
    private var canPlayNext: Bool { !hasNoBook && playback.currentChapterIndex + 1 < playback.chapters.count }

    private var currentChapterOneBased: Int {
        guard !playback.chapters.isEmpty else { return 0 }
        return min(max(1, playback.currentChapterIndex + 1), playback.chapters.count)
    }

    private var currentQualityBadge: String? {
        guard playback.currentBook != nil else { return nil }
        return playback.activeStream?.displayBitrateBadge ?? playback.preferredQuality.displayName
    }

    private var isEffectActive: Bool {
        playback.dsp.isCustomEQ
            || playback.dsp.preset != .flat
            || playback.dsp.volumeBoostDB > 0.05
            || playback.dsp.dynamicLevelingEnabled
    }

    private var effectShortLabel: String {
        if playback.dsp.isCustomEQ { return "自定义" }
        switch playback.dsp.preset {
        case .flat: return isEffectActive ? "已增强" : "音效"
        case .voiceBoost: return "人声"
        case .warm: return "醇厚"
        case .night: return "助眠"
        case .bright: return "通透"
        }
    }

    var currentChapterDownloadState: PlayerChapterDownloadState {
        guard let bookID = playback.currentBook?.id,
              let chapterID = playback.currentChapter?.id else { return .notDownloaded }
        let recordID = DownloadCoordinator.makeRecordID(bookID: bookID, chapterID: chapterID)
        guard let rec = downloads.manualRecords.first(where: { $0.id == recordID }) else { return .notDownloaded }
        switch rec.state {
        case .completed: return .completed
        case .queued, .resolving, .downloading, .paused:
            return .downloading(max(0.05, downloads.progressFeed.progress(for: recordID)))
        case .failed: return .failed
        case .cancelled: return .notDownloaded
        }
    }

    var body: some View {
        let isCoveredBySheet = (activeSheet != nil)

        ZStack(alignment: .top) {
            PlayerAmbientBackground(
                primaryColor: ambientColor,
                isPlaying: playback.state.isPlaying,
                isObscured: isCoveredBySheet
            )

            GeometryReader { outerGeo in
                portraitBody(availableHeight: outerGeo.size.height, isCoveredBySheet: isCoveredBySheet)
            }
            .offset(y: max(0, dragOffset))
            .animation(DSMotion.resolved(DSMotion.follow, reduceMotion: reduceMotion), value: dragOffset)

            if activeSheet == nil, let msg = banner.current {
                DSBannerPill(message: msg)
                    .padding(.top, DSSpacing.xs)
                    .zIndex(20)
            }

            if settings.nightDimEnabled {
                DSColors.nightDimOverlay
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(999)
            }
        }
        .preferredColorScheme(.dark)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) * 1.2 {
                        dragOffset = value.translation.height
                    } else if dragOffset > 0 {
                        dragOffset = 0
                    }
                }
                .onEnded { value in
                    let shouldDismiss = dragOffset > 0
                        && (value.translation.height > 120 || value.predictedEndTranslation.height > 320)
                    dragOffset = 0
                    if shouldDismiss { dismiss() }
                }
        )
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await refreshShelfStatus() }
        }
        .onChange(of: container.isCurrentBookFromXimalaya) { _, enabled in
            if !enabled && activeSheet == .quality {
                activeSheet = nil
            }
        }
        .task(id: playback.currentBook?.id) {
            await refreshBookContext()
        }
        .sheet(
            item: $activeSheet,
            onDismiss: {
                if let next = pendingSheet {
                    pendingSheet = nil
                    activeSheet = next
                }
            },
            content: sheetContent
        )
    }

    @ViewBuilder
    private func portraitBody(availableHeight: CGFloat, isCoveredBySheet: Bool) -> some View {
        let isCompact = availableHeight < 680 || isFailedState
        let coverMaxHeight: CGFloat = isFailedState
            ? min(168, max(108, availableHeight * 0.24))
            : (availableHeight < 680 ? min(212, max(124, availableHeight * 0.32)) : 296)

        VStack(spacing: 0) {
            PlayerHeader(
                sourceName: sourceName,
                qualityBadgeText: currentQualityBadge,
                sleepTimer: playback.sleepTimer,
                onDismiss: { dismiss() },
                onOpenQuality: {
                    if supportsQualitySelection {
                        activeSheet = .quality
                    } else if let badge = currentQualityBadge {
                        banner.show("当前书源为固定音源音质（\(badge)）", tone: .info)
                    }
                },
                onOpenSleepSheet: { activeSheet = .sleep },
                onOpenMoreSheet: { activeSheet = .more }
            )
            .layoutPriority(1)

            Spacer(minLength: isCompact ? DSSpacing.xxs : DSSpacing.xs)

            if hasNoBook {
                emptyBookState
            } else {
                PlayerCoverSection(
                    coverURL: playback.currentBook?.coverURL ?? "",
                    bookTitle: playback.currentBook.map { BookTitleFormatter.cleanTitle($0.title) } ?? "有声书",
                    pipeline: container.coverPipeline,
                    ambientColor: ambientColor,
                    playbackState: playback.state,
                    isObscured: isCoveredBySheet,
                    onDoubleTapPlayPause: {
                        DSHaptics.lightImpact()
                        playback.togglePlayPause()
                    },
                    onImageLoaded: { img in
                        ambientColor = CoverAmbientColor.color(from: img, cacheKey: playback.currentBook?.id)
                    }
                )
                .frame(maxHeight: coverMaxHeight)
            }

            Spacer(minLength: isCompact ? DSSpacing.xs : DSSpacing.sm)

            if let message = failedMessage {
                failedInlineBanner(message: message)
                    .padding(.horizontal, DSSpacing.pageHorizontal)
                    .padding(.bottom, DSSpacing.xs)
            }

            controlsStack(compact: isCompact)
                .padding(.bottom, isCompact ? DSSpacing.sm : DSSpacing.lg)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func controlsStack(compact: Bool) -> some View {
        VStack(spacing: compact ? DSSpacing.xs : DSSpacing.md) {
            PlayerTitleRow(
                chapterTitle: playback.currentChapter?.title ?? "未选择章节",
                bookTitle: playback.currentBook.map { BookTitleFormatter.cleanTitle($0.title) } ?? "未在播放",
                narrator: playback.currentBook?.narrator ?? "",
                downloadState: currentChapterDownloadState,
                inShelf: isInShelf,
                downloadBounceCount: downloadBounceCount,
                heartBounceCount: heartBounceCount,
                onTapChapterTitle: { if !hasNoBook { activeSheet = .chapters } },
                onTapBookTitle: {
                    guard let book = playback.currentBook else { return }
                    dismiss()
                    router.push(.bookDetail(book))
                },
                onTapNarrator: { narrator in
                    dismiss()
                    router.searchByNarrator(narrator)
                    banner.show("已复制演播「\(narrator)」，前往搜索", tone: .info)
                },
                onTapDownload: { handleCurrentChapterDownloadTap() },
                onTapShelf: {
                    if let book = playback.currentBook {
                        Task { await toggleCurrentBookShelf(book) }
                    }
                }
            )
            .disabled(hasNoBook)
            .opacity(hasNoBook ? 0.45 : 1)

            PlayerScrubberSection()
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .disabled(hasNoBook)
                .opacity(hasNoBook ? 0.45 : 1)

            PlayerControls(
                isPlaying: playback.state.isPlaying,
                isBuffering: playback.state.isBuffering,
                canPlayPrevious: canPlayPrevious,
                canPlayNext: canPlayNext,
                onPreviousChapter: {
                    DSHaptics.selection()
                    playback.previousChapter()
                },
                onSkipBackward: { playback.skipBy(-15) },
                onTogglePlay: {
                    DSHaptics.lightImpact()
                    playback.togglePlayPause()
                },
                onSkipForward: { playback.skipBy(30) },
                onNextChapter: {
                    DSHaptics.selection()
                    playback.nextChapter()
                }
            )
            .disabled(hasNoBook)
            .opacity(hasNoBook ? 0.45 : 1)

            PlayerSecondaryRow(
                speed: playback.playbackRate,
                effectLabel: effectShortLabel,
                effectIcon: "slider.horizontal.3",
                isEffectActive: isEffectActive,
                sleepTimer: playback.sleepTimer,
                currentChapterOneBased: currentChapterOneBased,
                totalChapters: playback.chapters.count,
                hasNoBook: hasNoBook,
                onOpenSpeed: { activeSheet = .speed },
                onOpenAudioEffects: { activeSheet = .effects },
                onOpenSleep: { activeSheet = .sleep },
                onOpenChapters: { activeSheet = .chapters }
            )
        }
    }
}

/// 独立订阅 PlaybackClock 的播放器进度条微视图（隔离 2Hz 刷新并传入 bufferedSeconds）
private struct PlayerScrubberSection: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(PlaybackClock.self) private var clock

    var body: some View {
        DSScrubber(
            currentSeconds: clock.currentSeconds,
            durationSeconds: clock.durationSeconds,
            bufferedSeconds: clock.bufferedSeconds
        ) { target in
            playback.seek(to: target)
        }
    }
}
