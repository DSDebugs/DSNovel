import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 隔离 2Hz 播放时钟订阅：仅在可见且播放态挂载，暂停或遮挡时卸载以停止高频重绘
private struct MiniPlayerLiveProgressRing: View {
    let clock: PlaybackClock
    let ringDiameter: CGFloat

    var body: some View {
        DSProgress(value: clock.progress, style: .ring(size: ringDiameter, lineWidth: 2.5))
    }
}

/// 46pt 圆形旋转封面 + 43.5pt 进度环 + 4 态覆盖层（1:1 复刻 v2.8 MiniPlayerProgressRing）
private struct MiniPlayerProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let clock: PlaybackClock
    let pipeline: CoverImagePipeline
    let coverURL: String
    let bookTitle: String
    let isPlaying: Bool
    let isBuffering: Bool
    let isFailed: Bool
    let hasActiveBook: Bool
    let size: CGFloat
    let isObscured: Bool

    @State private var baseAngleDegrees: Double = 0
    @State private var spinStartDate: Date?
    @State private var frozenProgressFraction: Double = 0

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    private var shouldLiveTrackClock: Bool { hasActiveBook && isPlaying && !isObscured && scenePhase == .active }
    private var shouldSpin: Bool { shouldLiveTrackClock && !reduceMotion }

    var body: some View {
        let coverSide = max(32, size - 6)
        let ringDiameter = max(36, size - 2.5)
        ZStack {
            if hasActiveBook {
                spinningCover(coverSide: coverSide)
                stateOverlay(coverSide: coverSide)
                if shouldLiveTrackClock {
                    MiniPlayerLiveProgressRing(clock: clock, ringDiameter: ringDiameter)
                } else {
                    DSProgress(value: frozenProgressFraction, style: .ring(size: ringDiameter, lineWidth: 2.5))
                }
            } else {
                Circle()
                    .fill(DSColors.surfaceGrouped)
                    .frame(width: size - 4, height: size - 4)
                    .overlay(Circle().strokeBorder(DSColors.separator.opacity(0.35), lineWidth: 1))
                Image(systemName: "play.fill")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.accent)
                    .offset(x: 1)
            }
        }
        .frame(width: size, height: size)
        .onAppear { syncProgressAndSpin() }
        .onChange(of: isPlaying) { _, _ in syncProgressAndSpin() }
        .onChange(of: isObscured) { _, _ in syncProgressAndSpin() }
        .onChange(of: scenePhase) { _, _ in syncProgressAndSpin() }
        .onChange(of: reduceMotion) { _, _ in syncSpinState() }
        .onChange(of: coverURL) { _, _ in
            baseAngleDegrees = 0
            spinStartDate = nil
            syncProgressAndSpin()
        }
        .onChange(of: hasActiveBook) { _, _ in
            baseAngleDegrees = 0
            spinStartDate = nil
            syncProgressAndSpin()
        }
    }

    @ViewBuilder
    private func stateOverlay(coverSide: CGFloat) -> some View {
        if isBuffering {
            Circle().fill(Color.black.opacity(0.35)).frame(width: coverSide, height: coverSide)
            ProgressView().tint(.white).controlSize(.small)
        } else if isFailed {
            Circle().fill(Color.black.opacity(0.45)).frame(width: coverSide, height: coverSide)
            Image(systemName: "arrow.clockwise").font(DSTypography.caption).foregroundStyle(.white)
        } else if !isPlaying {
            Circle().fill(Color.black.opacity(0.28)).frame(width: coverSide, height: coverSide)
            Image(systemName: "play.fill").font(DSTypography.caption).foregroundStyle(.white).offset(x: 1)
        }
    }

    @ViewBuilder
    private func spinningCover(coverSide: CGFloat) -> some View {
        let cover = DSCover(url: coverURL, title: bookTitle, pipeline: pipeline, side: coverSide)
            .clipShape(Circle())
        if shouldSpin, let start = spinStartDate {
            TimelineView(AnimationTimelineSchedule(minimumInterval: 1.0 / 20.0, paused: false)) { context in
                let angle = baseAngleDegrees + max(0, context.date.timeIntervalSince(start)) * 30.0
                cover.rotationEffect(.degrees(angle))
            }
        } else {
            cover.rotationEffect(.degrees(baseAngleDegrees))
        }
    }

    private func syncProgressAndSpin() {
        frozenProgressFraction = clock.progress
        syncSpinState()
    }

    private func syncSpinState() {
        if shouldSpin {
            if spinStartDate == nil { spinStartDate = .now }
        } else if let start = spinStartDate {
            let elapsed = max(0, Date.now.timeIntervalSince(start))
            baseAngleDegrees = (baseAngleDegrees + elapsed * 30.0).truncatingRemainder(dividingBy: 360.0)
            spinStartDate = nil
        }
    }
}

/// 底栏中央迷你播放器圆盘（1:1 复刻 v2.8 MiniPlayer：单击展开全屏播放器、长按快捷控制菜单）
private struct MiniPlayerDisc: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner

    let onOpenPlayer: () -> Void

    private var isBuffering: Bool {
        if case .buffering = playback.state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = playback.state { return true }
        return false
    }

    private var canPlayPrevious: Bool { playback.currentChapterIndex > 0 }
    private var canPlayNext: Bool { playback.currentChapterIndex + 1 < playback.chapters.count }

    private var accessibilityText: String {
        guard let book = playback.currentBook else { return "打开播放器" }
        let status = playback.state.isPlaying ? "正在播放" : "已暂停"
        if let ch = playback.currentChapter {
            return "\(status)：\(ch.title)，\(book.title)，点按打开播放器，长按可快捷控制"
        }
        return "\(status)《\(book.title)》，点按打开播放器，长按可快捷控制"
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                DSHaptics.selection()
                onOpenPlayer()
            } label: {
                MiniPlayerProgressRing(
                    clock: playback.clock,
                    pipeline: container.coverPipeline,
                    coverURL: playback.currentBook?.coverURL ?? "",
                    bookTitle: playback.currentBook?.title ?? "有声书",
                    isPlaying: playback.state.isPlaying,
                    isBuffering: isBuffering,
                    isFailed: isFailed,
                    hasActiveBook: playback.currentBook != nil,
                    size: 38,
                    isObscured: router.isPlayerPresented || banner.isSheetPresenting
                )
                .frame(minWidth: 42, minHeight: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.dsCard)
            .accessibilityIdentifier("miniplayer.root")
            .accessibilityLabel(accessibilityText)

            Button {
                DSHaptics.lightImpact()
                if playback.currentBook != nil {
                    playback.togglePlayPause()
                } else {
                    onOpenPlayer()
                }
            } label: {
                Group {
                    if isBuffering {
                        ProgressView()
                            .controlSize(.small)
                            .tint(DSColors.inkPrimary)
                    } else {
                        Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(DSTypography.callout.weight(.semibold))
                            .foregroundStyle(playback.currentBook != nil ? DSColors.inkPrimary : DSColors.inkSecondary)
                            .offset(x: playback.state.isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("miniplayer.togglePlay")
            .accessibilityLabel(playback.state.isPlaying ? "暂停播放" : "继续播放")
        }
        .contextMenu {
            if playback.currentBook != nil {
                Button {
                    DSHaptics.lightImpact()
                    playback.togglePlayPause()
                } label: {
                    Label(
                        playback.state.isPlaying ? "暂停播放" : "继续播放",
                        systemImage: playback.state.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                if canPlayPrevious {
                    Button {
                        DSHaptics.selection()
                        playback.previousChapter()
                    } label: {
                        Label("上一章", systemImage: "backward.end.fill")
                    }
                }
                if canPlayNext {
                    Button {
                        DSHaptics.selection()
                        playback.nextChapter()
                    } label: {
                        Label("下一章", systemImage: "forward.end.fill")
                    }
                }
                Button(action: onOpenPlayer) {
                    Label("展开播放器", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        .accessibilityAction(named: "播放或暂停") { playback.togglePlayPause() }
        .accessibilityAction(named: "上一章") { if canPlayPrevious { playback.previousChapter() } }
        .accessibilityAction(named: "下一章") { if canPlayNext { playback.nextChapter() } }
        .accessibilityAction(named: "展开播放器") { onOpenPlayer() }
    }
}

/// 纯竖屏主框架（ZStack 保活 3 Tab + 悬浮液态玻璃底栏与右侧播放球 + 单横幅协调 + 夜间降亮遮罩）
struct AppShell: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner

    private var isActiveTabAtRoot: Bool {
        switch router.selectedTab {
        case .discover: return router.discoverPath.isEmpty
        case .library: return router.libraryPath.isEmpty
        case .me: return router.mePath.isEmpty
        }
    }

    private var shouldShowBottomBar: Bool {
        !router.isBottomBarHidden && isActiveTabAtRoot
    }

    var body: some View {
        @Bindable var bindableRouter = router

        ZStack {
            tabStack(tab: .discover, path: $bindableRouter.discoverPath) { DiscoverRootView() }
            tabStack(tab: .library, path: $bindableRouter.libraryPath) { LibraryRootView() }
            tabStack(tab: .me, path: $bindableRouter.mePath) { MeRootView() }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if shouldShowBottomBar {
                    DSBottomBar(selectedTab: router.selectedTab, onSelectTab: { router.selectTab($0) }) {
                        MiniPlayerDisc { router.isPlayerPresented = true }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
            .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: shouldShowBottomBar)
        }
        .overlay(alignment: .top) {
            ZStack {
                if !banner.isSheetPresenting && !router.isPlayerPresented, let msg = banner.current {
                    DSBannerPill(message: msg)
                        .padding(.top, DSSpacing.xs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: banner.current != nil)
        }
        .overlay {
            let showNightDim = settings.nightDimEnabled && !router.isPlayerPresented
            ZStack {
                if showNightDim {
                    DSColors.nightDimOverlay
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(DSMotion.resolved(DSMotion.smooth, reduceMotion: reduceMotion), value: showNightDim)
        }
        .fullScreenCover(isPresented: $bindableRouter.isPlayerPresented) {
            PlayerScreen()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { container.performBackgroundMaintenance() }
        }
    }

    private func tabStack<Root: View>(
        tab: DSMainTab,
        path: Binding<[AppDestination]>,
        @ViewBuilder root: () -> Root
    ) -> some View {
        NavigationStack(path: path) {
            root().navigationDestination(for: AppDestination.self) { destinationView($0) }
        }
        .contentMargins(.bottom, shouldShowBottomBar ? 74 : 0, for: .scrollContent)
        .opacity(router.selectedTab == tab ? 1 : 0)
        .allowsHitTesting(router.selectedTab == tab)
        .accessibilityHidden(router.selectedTab != tab)
    }

    @ViewBuilder
    private func destinationView(_ destination: AppDestination) -> some View {
        switch destination {
        case .bookDetail(let book): BookDetailView(book: book)
        case .history: HistoryView()
        case .listeningStats: ListeningStatsView()
        case .downloads: DownloadsRootView()
        case .bookDownloadDetail(let bookID, let bookTitle):
            BookDownloadDetailView(bookID: bookID, bookTitle: bookTitle)
        case .sources: SourceListView()
        case .sourceDetail(let sourceID): SourceDetailView(sourceID: sourceID)
        case .builtinParser: BuiltinParserView()
        case .playbackPrefs: PlaybackPrefsView()
        case .storagePrefs: StoragePrefsView()
        case .about: AboutView()
        }
    }
}
