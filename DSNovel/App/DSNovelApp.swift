import SwiftUI
import SwiftData

@main
struct DSNovelApp: App {
    let modelContainer: ModelContainer
    @State private var settings = AppSettingsStore.shared
    @State private var player = PlayerEngine.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var toastManager = ToastManager.shared

    init() {
        CookieSync.bootstrap()
        let schema = Schema([
            Book.self,
            ShelfCategory.self,
            DownloadItem.self,
            PluginRecord.self,
            PluginGroup.self,
            SearchHistory.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("无法初始化 SwiftData 容器: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .task {
                    let context = modelContainer.mainContext
                    player.modelContext = context
                    downloadManager.modelContext = context
                    downloadManager.recoverInterruptedItems()
                    _ = await CookieSync.pullFromWebView()
                    // 首次启动：把随 App 打包的听书书源种子安装到插件目录（幂等，不覆盖用户数据）
                    await BundledSourceSeeder.seedIfNeeded(modelContext: context)
                    await PluginRuntime.shared.reloadInstalledPackages()
                    autoResumeIfNeeded(context: context)
                }
        }
        .modelContainer(modelContainer)
    }

    @MainActor
    private func autoResumeIfNeeded(context: ModelContext) {
        guard settings.autoResumeOnLaunch, player.currentBook == nil else { return }
        var desc = FetchDescriptor<Book>(
            predicate: #Predicate<Book> { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\Book.lastPlayedAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let lastBook = try? context.fetch(desc).first,
              let lastChapID = lastBook.lastChapterID,
              let chapters = ChapterCacheStore.loadChapters(for: lastBook.id),
              let targetChapter = chapters.first(where: { $0.id == lastChapID }) else {
            return
        }
        player.startPlayback(
            book: lastBook.bookRef,
            chapters: chapters,
            startChapter: targetChapter,
            initialPositionMs: lastBook.lastPositionMs
        )
    }
}
