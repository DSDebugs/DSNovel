import SwiftUI

@main
struct DSNovelApp: App {
    @State private var dualEngine = DualSourceEngine.shared
    @State private var playerEngine = AudioPlayerEngine.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var qxEngine = QuantumultXEngine.shared

    var body: some Scene {
        WindowGroup {
            RootWorkspaceView()
                .environment(dualEngine)
                .environment(playerEngine)
                .environment(libraryStore)
                .environment(qxEngine)
                .preferredColorScheme(.dark)
        }
    }
}
