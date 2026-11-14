import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case bookshelf = "书架"
    case discover = "书城"
    case search = "搜索"
    case settings = "我的"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .bookshelf: return "books.vertical.fill"
        case .discover: return "sparkles.rectangle.stack.fill"
        case .search: return "magnifyingglass"
        case .settings: return "person.crop.circle.fill"
        }
    }
}

struct RootWorkspaceView: View {
    @Environment(AudioPlayerEngine.self) private var player
    @State private var selectedTab: MainTab = .discover
    @State private var isShowingFullPlayer: Bool = false
    @State private var openPlayerDirectlyToChapters: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                Tab(MainTab.bookshelf.rawValue, systemImage: MainTab.bookshelf.icon, value: MainTab.bookshelf) {
                    BookshelfView(
                        onSwitchTab: { tab in selectedTab = tab },
                        onOpenFullPlayer: {
                            openPlayerDirectlyToChapters = false
                            isShowingFullPlayer = true
                        },
                        onOpenPlayerChapters: {
                            openPlayerDirectlyToChapters = true
                            isShowingFullPlayer = true
                        }
                    )
                }

                Tab(MainTab.discover.rawValue, systemImage: MainTab.discover.icon, value: MainTab.discover) {
                    DiscoverView(
                        onSwitchToSearch: { selectedTab = .search },
                        onOpenFullPlayer: {
                            openPlayerDirectlyToChapters = false
                            isShowingFullPlayer = true
                        }
                    )
                }

                Tab(MainTab.search.rawValue, systemImage: MainTab.search.icon, value: MainTab.search) {
                    AggregateSearchView(
                        onOpenFullPlayer: {
                            openPlayerDirectlyToChapters = false
                            isShowingFullPlayer = true
                        }
                    )
                }

                Tab(MainTab.settings.rawValue, systemImage: MainTab.settings.icon, value: MainTab.settings) {
                    SettingsView(
                        onOpenFullPlayer: {
                            openPlayerDirectlyToChapters = false
                            isShowingFullPlayer = true
                        }
                    )
                }
            }
            .tint(.orange)

            if player.currentBook != nil {
                FloatingMiniPlayerBar(
                    onExpandPlayer: {
                        openPlayerDirectlyToChapters = false
                        isShowingFullPlayer = true
                    },
                    onOpenChapters: {
                        openPlayerDirectlyToChapters = true
                        isShowingFullPlayer = true
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 56)
            }
        }
        .sheet(isPresented: $isShowingFullPlayer) {
            NowPlayingSheet(initialCenterMode: openPlayerDirectlyToChapters ? .chapters : .artwork)
                .presentationDragIndicator(.visible)
        }
    }
}
