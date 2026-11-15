import SwiftUI
import SwiftData

/// 主导航容器（第 3 节）：固定四个底部标签（发现 · 书架 · 搜索 · 设置），含迷你播放条与全屏播放器过渡
struct RootTabView: View {
    @State private var selectedTab: AppTab = .discover
    @State private var discoverPath: [Route] = []
    @State private var shelfPath: [Route] = []
    @State private var searchPath: [Route] = []
    @State private var settingsPath: [Route] = []
    @State private var isShowingFullPlayer = false

    private var player = PlayerEngine.shared
    private var toast = ToastManager.shared
    private var settings = AppSettingsStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack(path: $discoverPath) {
                    DiscoverView(
                        onNavigateToImportPlugins: {
                            selectedTab = .settings
                            settingsPath = [.pluginManager]
                        },
                        onSelectBook: { bookRef in
                            discoverPath.append(.book(bookRef))
                        }
                    )
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
                }
                .tabItem {
                    Label(AppTab.discover.title, systemImage: AppTab.discover.icon)
                }
                .tag(AppTab.discover)

                NavigationStack(path: $shelfPath) {
                    ShelfView(
                        onSwitchToDiscover: {
                            selectedTab = .discover
                        },
                        onSelectBook: { bookRef in
                            shelfPath.append(.book(bookRef))
                        },
                        onOpenDownloads: {
                            shelfPath.append(.downloadManager)
                        }
                    )
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
                }
                .tabItem {
                    Label(AppTab.shelf.title, systemImage: AppTab.shelf.icon)
                }
                .tag(AppTab.shelf)

                // 搜索标签不使用 role: .search，确保固定排在设置标签之前（第 3 节）
                NavigationStack(path: $searchPath) {
                    SearchView { merged in
                        searchPath.append(.book(merged.primary, alternatives: merged.alternatives))
                    }
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
                }
                .tabItem {
                    Label(AppTab.search.title, systemImage: AppTab.search.icon)
                }
                .tag(AppTab.search)

                NavigationStack(path: $settingsPath) {
                    SettingsView(path: $settingsPath)
                        .navigationDestination(for: Route.self) { route in
                            destinationView(for: route)
                        }
                }
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.icon)
                }
                .tag(AppTab.settings)
            }

            if player.isMiniPlayerVisible {
                MiniPlayerBar {
                    isShowingFullPlayer = true
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ToastOverlayView(message: toast.currentMessage)
        }
        .fullScreenCover(isPresented: $isShowingFullPlayer) {
            PlayerFullScreenView()
        }
    }

    @ViewBuilder
    private func destinationView(for route: Route) -> some View {
        switch route {
        case .book(let bookRef, let alternatives):
            BookDetailView(
                bookRef: bookRef,
                alternatives: alternatives,
                onJumpToDiscoverSource: { sourceID in
                    settings.currentDiscoverSourceID = sourceID
                    selectedTab = .discover
                    discoverPath.removeAll()
                }
            )
        case .pluginManager:
            PluginManagerView()
        case .downloadManager:
            DownloadManageView()
        case .skipSettings:
            DefaultSkipSettingsView()
        }
    }
}
