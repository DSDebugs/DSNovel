import SwiftUI
import SwiftData

struct AppShell: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var router = AppRouter.shared
    @State private var player = PlayerEngine.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var discoverStore = DiscoverStore.shared
    @State private var searchStore = SearchStore.shared
    @State private var bannerCenter = BannerCenter.shared
    @State private var settings = AppSettingsStore.shared

    @State private var didSetInitialTab = false
    @State private var dismissedOnboarding = false

    init() {}

    private func handleTabReselect(_ tab: ShellTab) {
        if !router.isAtRoot(for: tab) {
            router.popToRoot(for: tab)
        } else {
            ScrollToTopCenter.shared.requestScrollToTop(in: tab)
        }
    }

    var body: some View {
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

            if let banner = bannerCenter.currentBanner {
                DSBanner(
                    item: banner,
                    onUndo: { bannerCenter.triggerUndo() },
                    onDismiss: { bannerCenter.dismissCurrent() }
                )
                .padding(.top, Spacing.s2)
                .zIndex(10)
            }
        }
        .fullScreenCover(isPresented: $router.isPlayerPresented) {
            PlayerScreen()
        }
        .dsAuthPresenter()
        .dsSyncReduceMotion(override: settings.reduceMotionOverride)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                bannerCenter.handleDidEnterBackground()
            } else if newPhase == .active {
                DownloadManager.shared.pumpQueue()
            }
        }
        .onChange(of: libraryStore.hasLoadedOnce) { _, loaded in
            if loaded { resolveInitialTabIfNeeded() }
        }
        .onAppear {
            libraryStore.modelContext = modelContext
            sourceStore.modelContext = modelContext
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
            SourceImportFlow(onClose: { router.popToRoot(for: router.selectedTab) })
        case .skipSettings:
            SkipSettingsDetailView(settings: settings)
        }
    }
}
