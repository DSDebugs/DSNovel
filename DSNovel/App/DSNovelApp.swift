import SwiftUI
import SwiftData

private struct SimulatedStoreFailureError: LocalizedError {
    var errorDescription: String? { "Simulated SwiftData store failure (-DSNOVEL_SIMULATE_STORE_FAILURE)" }
}

@main
struct DSNovelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var containerResult: Result<ModelContainer, Error>
    @State private var settings = AppSettingsStore.shared
    @State private var player = PlayerEngine.shared
    @State private var downloadManager = DownloadManager.shared

    init() {
        CookieSync.bootstrap()
        let config = AppLaunchConfig.current
        _containerResult = State(
            initialValue: Self.makeContainer(
                simulateFailure: config.simulateStoreFailure,
                inMemoryOnly: config.isUITestMode
            )
        )
    }

    static var appSchema: Schema {
        Schema([
            Book.self,
            ChapterProgress.self,
            ShelfCategory.self,
            DownloadItem.self,
            PluginRecord.self,
            PluginGroup.self,
            SearchHistory.self,
            BuiltinParserRecord.self
        ])
    }

    private static func makeContainer(simulateFailure: Bool = false, inMemoryOnly: Bool = false) -> Result<ModelContainer, Error> {
        if simulateFailure {
            return .failure(SimulatedStoreFailureError())
        }
        let config = ModelConfiguration(schema: appSchema, isStoredInMemoryOnly: inMemoryOnly)
        do {
            let container = try ModelContainer(for: appSchema, configurations: [config])
            return .success(container)
        } catch {
            return .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch containerResult {
            case .success(let modelContainer):
                AppShell()
                    .preferredColorScheme(settings.appearanceMode.colorScheme)
                    .task {
                        let context = modelContainer.mainContext
                        let launch = AppLaunchConfig.current
                        player.modelContext = context
                        downloadManager.modelContext = context
                        LibraryStore.shared.modelContext = context
                        SourceStore.shared.modelContext = context
                        ChapterProgressCache.shared.migrateLegacyIfNeeded(context: context)
                        PerBookSkipMigration.runIfNeeded(context: context)

                        #if DEBUG
                        if launch.isUITestMode {
                            player.useFakeBackend = true
                            FixtureData.populate(
                                in: context,
                                emptyAll: launch.isEmptyLibraryAndSources,
                                noSourceOnly: launch.isNoSourceOnly
                            )
                            LibraryStore.shared.refreshNow()
                            SourceStore.shared.refreshNow()
                            autoResumeIfNeeded(context: context)
                            return
                        }
                        #endif

                        // 提前恢复上次播放状态，缩短冷启动首帧到可播态的等待时间
                        autoResumeIfNeeded(context: context)
                        downloadManager.recoverInterruptedItems()
                        // 将 WKWebView 全量 Cookie 同步延后至后台异步执行，避免阻塞冷启动
                        Task(priority: .utility) {
                            _ = await CookieSync.pullFromWebView()
                        }
                        await BundledSourceSeeder.seedIfNeeded(modelContext: context)
                        await PluginRuntime.shared.reloadInstalledPackages()
                        await BuiltinParserRuntime.shared.reload()
                        BuiltinParserRegistrySync.syncRecords(context: context)
                        LibraryStore.shared.refreshNow()
                        SourceStore.shared.refreshNow()
                    }
                    .modelContainer(modelContainer)

            case .failure(let error):
                DataRepairView(
                    errorDescription: error.localizedDescription,
                    onRetry: {
                        containerResult = Self.makeContainer(simulateFailure: false)
                    },
                    onBackupAndRebuild: {
                        _ = try? StoreBackup.backupCurrentStore()
                        try? StoreBackup.removeStoreFiles()
                        containerResult = Self.makeContainer(simulateFailure: false)
                    }
                )
            }
        }
    }

    @MainActor
    private func autoResumeIfNeeded(context: ModelContext) {
        guard settings.launchBehavior != .doNothing, player.currentBook == nil else { return }
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
        switch settings.launchBehavior {
        case .restorePaused:
            player.prepare(
                book: lastBook.bookRef,
                chapters: chapters,
                chapter: targetChapter,
                positionMs: lastBook.lastPositionMs
            )
        case .autoPlay:
            player.startPlayback(
                book: lastBook.bookRef,
                chapters: chapters,
                startChapter: targetChapter,
                initialPositionMs: lastBook.lastPositionMs
            )
        case .doNothing:
            break
        }
    }
}
