import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case discover = "书城"
    case bookshelf = "书架"
    case settings = "我的"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .discover: return "sparkles.rectangle.stack.fill"
        case .bookshelf: return "books.vertical.fill"
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
                // 1. 书城在前（集成全网搜索与 12 大分类网格）
                DiscoverView(
                    onOpenFullPlayer: {
                        openPlayerDirectlyToChapters = false
                        isShowingFullPlayer = true
                    }
                )
                .tabItem {
                    Label(MainTab.discover.rawValue, systemImage: MainTab.discover.icon)
                }
                .tag(MainTab.discover)

                // 2. 书架（严格分离“我的书籍”与“最近收听”，支持章节时间记录与删除）
                BookshelfView(
                    onSwitchTab: { tab in selectedTab = tab },
                    onOpenFullPlayer: {
                        openPlayerDirectlyToChapters = false
                        isShowingFullPlayer = true
                    }
                )
                .tabItem {
                    Label(MainTab.bookshelf.rawValue, systemImage: MainTab.bookshelf.icon)
                }
                .tag(MainTab.bookshelf)

                // 3. 我的（代理介入、账号登录与音效偏好）
                SettingsView(
                    onOpenFullPlayer: {
                        openPlayerDirectlyToChapters = false
                        isShowingFullPlayer = true
                    }
                )
                .tabItem {
                    Label(MainTab.settings.rawValue, systemImage: MainTab.settings.icon)
                }
                .tag(MainTab.settings)
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
        .fullScreenCover(isPresented: $isShowingFullPlayer) {
            NowPlayingSheet(initialCenterMode: openPlayerDirectlyToChapters ? .chapters : .artwork)
        }
    }
}
