import SwiftUI

@main
struct DSNovelApp: App {
    @State private var dualEngine = DualSourceEngine.shared
    @State private var playerEngine = AudioPlayerEngine.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var debugEngine = SourceDebugEngine.shared

    var body: some Scene {
        WindowGroup {
            RootWorkspaceView()
                .environment(dualEngine)
                .environment(playerEngine)
                .environment(libraryStore)
                .environment(debugEngine)
                .preferredColorScheme(.dark)
                .task {
                    if SourceDebugEngine.shared.isEnabled {
                        await SourceDebugEngine.shared.syncKeyDataFromURL()
                    }
                }
        }
    }
}
