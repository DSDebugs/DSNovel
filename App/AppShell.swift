import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 仅订阅 PlaybackClock 的 48pt 进度弧微视图（AUD-93：隔离 2Hz 刷新，避免重复初始化 DSCoverImage）
private struct MiniPlayerProgressArc: View {
    @Environment(PlaybackClock.self) private var clock

    var body: some View {
        Circle()
            .trim(from: 0, to: min(1, max(0, clock.progress)))
            .stroke(DSColors.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 48, height: 48)
    }
}

/// 独立 48pt 中央进度环子视图（UI-01/AUD-93：彻底消除 AppShell 与 DSCoverImage 的 2Hz 重绘）
private struct MiniPlayerProgressRing: View {
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback

    let onOpenPlayer: () -> Void

    private var accessibilityText: String {
        let title = playback.currentBook?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if playback.state.isPlaying {
            return title.isEmpty ? "正在播放，点击打开播放器" : "正在播放《\(title)》，点击打开播放器"
        }
        return title.isEmpty ? "打开播放器" : "打开播放器，当前书籍《\(title)》"
    }

    var body: some View {
        Button(action: onOpenPlayer) {
            ZStack {
                Circle()
                    .stroke(DSColors.inkSecondary.opacity(0.2), lineWidth: 2.5)
                    .frame(width: 48, height: 48)
                MiniPlayerProgressArc()
                DSCoverImage(
                    urlString: playback.currentBook?.coverURL ?? "",
                    pipeline: container.coverPipeline,
                    cornerRadius: 21
                )
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                .overlay {
                    if !playback.state.isPlaying {
                        Image(systemName: "play.fill")
                            .font(DSTypography.caption)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }
}

/// 纯竖屏主框架（UI-01/AUD-22/AUD-23：零 PlaybackClock 顶层订阅 + ZStack 保活 4 Tab + safeAreaInset 底部栏 + 单横幅协调 + 夜间降亮遮罩）
struct AppShell: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner

    var body: some View {
        @Bindable var bindableRouter = router

        ZStack {
            NavigationStack(path: $bindableRouter.discoverPath) {
                DiscoverRootView()
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
            }
            .opacity(router.selectedTab == .discover ? 1 : 0)
            .allowsHitTesting(router.selectedTab == .discover)
            .accessibilityHidden(router.selectedTab != .discover)

            NavigationStack(path: $bindableRouter.searchPath) {
                SearchRootView()
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
            }
            .opacity(router.selectedTab == .search ? 1 : 0)
            .allowsHitTesting(router.selectedTab == .search)
            .accessibilityHidden(router.selectedTab != .search)

            NavigationStack(path: $bindableRouter.libraryPath) {
                LibraryRootView()
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
            }
            .opacity(router.selectedTab == .library ? 1 : 0)
            .allowsHitTesting(router.selectedTab == .library)
            .accessibilityHidden(router.selectedTab != .library)

            NavigationStack(path: $bindableRouter.mePath) {
                MeRootView()
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
            }
            .opacity(router.selectedTab == .me ? 1 : 0)
            .allowsHitTesting(router.selectedTab == .me)
            .accessibilityHidden(router.selectedTab != .me)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DSBottomBar(
                selectedTab: router.selectedTab,
                onSelectTab: { router.selectTab($0) }
            ) {
                MiniPlayerProgressRing {
                    router.isPlayerPresented = true
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .overlay(alignment: .top) {
            if !banner.isSheetPresenting && !router.isPlayerPresented, let msg = banner.current {
                DSBannerPill(message: msg)
                    .padding(.top, DSSpacing.xs)
            }
        }
        .overlay {
            // AUD-58：全屏播放器弹出期间由 PlayerScreen 独立承接 nightDimOverlay，避免转场双重叠加
            if settings.nightDimEnabled && !router.isPlayerPresented {
                DSColors.nightDimOverlay
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .fullScreenCover(isPresented: $bindableRouter.isPlayerPresented) {
            PlayerScreen()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                container.performBackgroundMaintenance()
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: AppDestination) -> some View {
        switch destination {
        case .bookDetail(let book):
            BookDetailView(book: book)
        case .history:
            HistoryView()
        case .downloads:
            DownloadsRootView()
        case .bookDownloadDetail(let bookID, let bookTitle):
            BookDownloadDetailView(bookID: bookID, bookTitle: bookTitle)
        case .sources:
            SourceListView()
        case .sourceDetail(let sourceID):
            SourceDetailView(sourceID: sourceID)
        case .builtinParser:
            BuiltinParserView()
        case .appearancePrefs:
            AppearancePrefsView()
        case .playbackPrefs:
            PlaybackPrefsView()
        case .storagePrefs:
            StoragePrefsView()
        case .about:
            AboutView()
        case .diagnostics:
            DiagnosticsView()
        }
    }
}
