import SwiftUI
import SwiftData
import Observation

struct AppShell: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    private let dependencies: AppDependencies

    @State private var didSetInitialTab = false
    @State private var dismissedOnboarding = false

    private var router: AppRouter { dependencies.router }
    private var player: PlayerEngine { dependencies.player }
    private var libraryStore: LibraryStore { dependencies.libraryStore }
    private var sourceStore: SourceStore { dependencies.sourceStore }
    private var downloadManager: DownloadManager { dependencies.downloadManager }
    private var bannerCenter: BannerCenter { dependencies.bannerCenter }
    private var settings: AppSettingsStore { dependencies.settings }

    init(dependencies: AppDependencies = .live) {
        self.dependencies = dependencies
    }

    private func handleTabReselect(_ tab: ShellTab) {
        if !router.isAtRoot(for: tab) {
            router.popToRoot(for: tab)
        } else {
            ScrollToTopCenter.shared.requestScrollToTop(in: tab)
        }
    }

    var body: some View {
        @Bindable var router = dependencies.router
        let nightDim = settings.nightDimEnabled
        let shouldSuppressShellBanner = DSSheetBannerCoordinator.shared.isSheetPresented || router.isSourceImportPresented

        ZStack(alignment: .top) {
            if !sourceStore.hasEnabledSource && sourceStore.hasLoadedOnce && !dismissedOnboarding {
                OnboardingView(
                    hasSeededSource: !sourceStore.allSources.isEmpty,
                    onUseBuiltIn: {
                        for s in sourceStore.allSources { s.isEnabled = true }
                        try? modelContext.save()
                        sourceStore.refreshNow()
                        dismissedOnboarding = true
                        router.selectedTab = .discover
                    },
                    onImportOwn: {
                        dismissedOnboarding = true
                        router.open(.sourceImport)
                    }
                )
            } else {
                TabView(selection: $router.selectedTab) {
                    Tab(value: ShellTab.discover) {
                        NavigationStack(path: $router.discoverPath) {
                            DiscoverRootView()
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                        .toolbar(.hidden, for: .tabBar)
                    }

                    Tab(value: ShellTab.search) {
                        NavigationStack(path: $router.searchPath) {
                            SearchRootView()
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                        .toolbar(.hidden, for: .tabBar)
                    }

                    Tab(value: ShellTab.library) {
                        NavigationStack(path: $router.libraryPath) {
                            LibraryRootView()
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                        .toolbar(.hidden, for: .tabBar)
                    }

                    Tab(value: ShellTab.me) {
                        NavigationStack(path: $router.mePath) {
                            MeRootView()
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                        .toolbar(.hidden, for: .tabBar)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !router.isBottomBarHidden {
                        DSBottomBar(
                            selectedTab: $router.selectedTab,
                            libraryBadge: libraryStore.updatedCount,
                            meBadge: sourceStore.healthSummary.unavailableCount,
                            player: player,
                            continueBook: libraryStore.continueBook,
                            onReselectTab: handleTabReselect,
                            onOpenFullPlayer: { router.isPlayerPresented = true }
                        )
                    }
                }
            }

            if !shouldSuppressShellBanner, let banner = bannerCenter.currentBanner {
                DSBanner(
                    item: banner,
                    onUndo: { bannerCenter.triggerUndo() },
                    onDismiss: { bannerCenter.dismissCurrent() }
                )
                .padding(.top, Spacing.s2)
                .zIndex(10)
            }
        }
        .environment(\.appDependencies, dependencies)
        .environment(\.dsNightDimEnabled, nightDim)
        .environment(\.dsSettings, settings)
        .environment(\.dsBannerCenter, bannerCenter)
        .environment(\.dsRouter, router)
        .tint(Color.dsAccent)
        .sheet(isPresented: $router.isSourceImportPresented) {
            SourceImportFlow(onClose: { router.isSourceImportPresented = false })
        }
        .fullScreenCover(isPresented: $router.isPlayerPresented) {
            PlayerScreen()
        }
        .dsAuthPresenter(suppressWhenPlayerPresented: true)
        .dsSyncReduceMotion(override: settings.reduceMotionOverride)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                bannerCenter.handleDidEnterBackground()
            } else if newPhase == .active {
                downloadManager.pumpQueue()
            }
        }
        .onChange(of: libraryStore.hasLoadedOnce) { _, loaded in
            if loaded { resolveInitialTabIfNeeded() }
        }
        .onAppear {
            resolveInitialTabIfNeeded()
        }
    }

    private func resolveInitialTabIfNeeded() {
        guard !didSetInitialTab, libraryStore.hasLoadedOnce else { return }
        didSetInitialTab = true
        if !libraryStore.allShelfBooks.isEmpty || libraryStore.continueBook != nil {
            router.selectedTab = .library
        } else {
            router.selectedTab = .discover
        }
    }

    @ViewBuilder
    private func destinationView(for route: Route) -> some View {
        switch route {
        case .book(let ref, let preferDownloaded):
            BookDetailView(book: ref, preferDownloaded: preferDownloaded)
        case .history:
            HistoryView()
        case .downloads, .downloadManager:
            DownloadsRootView()
        case .sourceList, .pluginManager:
            SourceListView()
        case .sourceDetail(let id, let focus):
            SourceDetailView(sourceID: id, focus: focus)
        case .sourceImport:
            SourceImportFlow(onClose: {
                router.isSourceImportPresented = false
                router.popToRoot(for: router.selectedTab)
            })
        case .playbackMore:
            MorePlaybackPrefsView(settings: settings)
        case .about:
            AboutView(settings: settings)
        }
    }
}
