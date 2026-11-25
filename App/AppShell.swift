import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI


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
        let activeAccentTheme = settings.accentTheme
        let _ = DSColors.setAccentTheme(activeAccentTheme)

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
        .tint(DSColors.accent(for: activeAccentTheme))
        .environment(\.dsAccentTheme, activeAccentTheme)
        .fullScreenCover(isPresented: $bindableRouter.isPlayerPresented) {
            PlayerScreen()
                .tint(DSColors.accent(for: activeAccentTheme))
                .environment(\.dsAccentTheme, activeAccentTheme)
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
