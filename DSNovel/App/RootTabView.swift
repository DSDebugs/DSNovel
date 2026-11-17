import SwiftUI
import SwiftData
import UIKit

/// 主导航容器（方案一最佳架构：保留原生 TabView 独立 NavigationStack 状态 + 隐藏系统默认 TabBar + 顶层叠加三态悬浮灵动坞 AdaptiveBottomDock）
struct RootTabView: View {
    @State private var dock = BottomDockController.shared
    @State private var searchViewModel = SearchViewModel()
    @State private var discoverPath: [Route] = []
    @State private var searchPath: [Route] = []
    @State private var shelfPath: [Route] = []
    @State private var settingsPath: [Route] = []
    @State private var isShowingFullPlayer = false

    private var player = PlayerEngine.shared
    private var toast = ToastManager.shared
    private var settings = AppSettingsStore.shared
    private var router = AppRouter.shared

    init() {
        // 全局隐藏 UIKit 原生 UITabBar，避免系统底栏在页面切换或首次渲染时闪烁
        UITabBar.appearance().isHidden = true
    }

    private var currentActivePathCount: Int {
        switch dock.selectedTab {
        case .discover: return discoverPath.count
        case .search:   return searchPath.count
        case .shelf:    return shelfPath.count
        case .settings: return settingsPath.count
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $dock.selectedTab) {
                // 1. 发现
                NavigationStack(path: $discoverPath) {
                    DiscoverView(
                        onNavigateToImportPlugins: {
                            navigateToPluginManager()
                        },
                        onSwitchToSearch: {
                            dock.activateSearchInline(autoFocus: true)
                        },
                        onSwitchToSearchWithKeyword: { keyword in
                            searchViewModel.keyword = keyword
                            dock.activateSearchInline(autoFocus: false)
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(120))
                                dock.onSubmitInlineSearch?(keyword)
                            }
                        },
                        onSelectBook: { bookRef in
                            discoverPath.append(.book(bookRef))
                        }
                    )
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
                    .toolbar(.hidden, for: .tabBar)
                }
                .tag(AppTab.discover)
                .toolbar(.hidden, for: .tabBar)

                // 2. 搜索（由底部灵动坞右侧搜索球/内联搜索胶囊驱动）
                NavigationStack(path: $searchPath) {
                    SearchView(
                        viewModel: searchViewModel,
                        onSelectMergedItem: { merged in
                            searchPath.append(.book(merged.primary, alternatives: merged.alternatives))
                        },
                        onNavigateToPluginManager: {
                            navigateToPluginManager()
                        }
                    )
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
                    .toolbar(.hidden, for: .tabBar)
                }
                .tag(AppTab.search)
                .toolbar(.hidden, for: .tabBar)

                // 3. 书架
                NavigationStack(path: $shelfPath) {
                    ShelfView(
                        onSwitchToDiscover: {
                            dock.selectMainTab(.discover)
                        },
                        onSwitchToSearch: {
                            dock.activateSearchInline(autoFocus: true)
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
                    .toolbar(.hidden, for: .tabBar)
                }
                .tag(AppTab.shelf)
                .toolbar(.hidden, for: .tabBar)

                // 4. 设置
                NavigationStack(path: $settingsPath) {
                    SettingsView(path: $settingsPath)
                        .navigationDestination(for: Route.self) { route in
                            destinationView(for: route)
                        }
                        .toolbar(.hidden, for: .tabBar)
                }
                .tag(AppTab.settings)
                .toolbar(.hidden, for: .tabBar)
            }

            if !dock.isSuppressedByEditing {
                AdaptiveBottomDock(
                    dock: dock,
                    searchVM: searchViewModel,
                    onExpandFullPlayer: {
                        isShowingFullPlayer = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ToastOverlayView(message: toast.currentMessage)
        }
        .ignoresSafeArea(.keyboard, edges: dock.mode == .searchInline ? [] : .bottom)
        .onChange(of: dock.mode) { _, newMode in
            if newMode == .searchInline && !searchPath.isEmpty {
                searchPath.removeAll()
            }
        }
        .fullScreenCover(isPresented: $isShowingFullPlayer) {
            PlayerFullScreenView()
        }
        // 同步各 Tab 的二级页面导航深度：进入二级页时自动收起为紧凑三胶囊态，返回根页时自动恢复
        .onChange(of: currentActivePathCount) { _, newCount in
            dock.updateNavigationDepth(newCount)
        }
        // VIP 章节报错 → 跳到「设置 → 书源管理 → 该书源的内置解析分区」（全 App 唯一提示出口）
        .onChange(of: router.pendingParserSourceID) { _, newValue in
            guard newValue != nil else { return }
            isShowingFullPlayer = false
            dock.selectMainTab(.settings)
            if settingsPath.last != .pluginManager {
                settingsPath = [.pluginManager]
            }
        }
    }

    private func navigateToPluginManager() {
        dock.selectMainTab(.settings)
        settingsPath = [.pluginManager]
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
                    discoverPath.removeAll()
                    dock.selectMainTab(.discover)
                }
            )
            .toolbar(.hidden, for: .tabBar)
        case .pluginManager:
            PluginManagerView()
                .toolbar(.hidden, for: .tabBar)
        case .downloadManager:
            DownloadManageView()
                .toolbar(.hidden, for: .tabBar)
        case .skipSettings:
            DefaultSkipSettingsView()
                .toolbar(.hidden, for: .tabBar)
        }
    }
}
