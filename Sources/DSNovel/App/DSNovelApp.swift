import SwiftUI

@main
struct DSNovelApp: App {
    @State private var dualEngine = DualSourceEngine.shared
    @State private var playerEngine = AudioPlayerEngine.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var interventionEngine = ProxyInterventionEngine.shared

    var body: some Scene {
        WindowGroup {
            RootWorkspaceView()
                .environment(dualEngine)
                .environment(playerEngine)
                .environment(libraryStore)
                .environment(interventionEngine)
                .preferredColorScheme(.dark)
                .task {
                    // 启动时若开启代理介入且本地尚未拉取在线脚本，后台自动同步一次
                    if ProxyInterventionEngine.shared.isEnabled {
                        await ProxyInterventionEngine.shared.updateFromOnlineURL()
                    }
                }
        }
    }
}
