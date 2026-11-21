import SwiftUI
import SwiftData

private struct SimulatedStoreFailureError: LocalizedError {
    var errorDescription: String? { "Simulated SwiftData store failure (-DSNOVEL_SIMULATE_STORE_FAILURE)" }
}

@MainActor
extension AppDependencies {
    /// M-P0-2：启动早期与主场景 `.task` 共享的幂等绑定入口，避免重复创建 PersistenceActor 或遗漏绑定
    func bindIfNeeded(modelContainer: ModelContainer) {
        if persistenceActor != nil,
           downloadManager.modelContext === modelContainer.mainContext,
           libraryStore.modelContext === modelContainer.mainContext,
           sourceStore.modelContext === modelContainer.mainContext,
           player.modelContext === modelContainer.mainContext {
            return
        }
        bind(modelContainer: modelContainer)
    }
}

@main
struct DSNovelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// M-P0-2：进程级共享 ModelContainer（供 AppDelegate 后台冷启与 DSNovelApp.init() 复用同一实例）
    @MainActor static var sharedModelContainer: ModelContainer?

    @State private var containerResult: Result<ModelContainer, Error>
    @State private var dependencies = AppDependencies.live
    @State private var settings = AppDependencies.live.settings
    @State private var player = AppDependencies.live.player
    @State private var downloadManager = AppDependencies.live.downloadManager
    @State private var repairErrorMessage: String?

    /// 仅在 XCTest 单元测试宿主进程中为 true（Release 正式包与 XCUITest 均为 false）
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !AppLaunchConfig.current.isUITestMode
    }

    init() {
        let config = AppLaunchConfig.current
        let unitTestMode = Self.isRunningUnitTests
        if !unitTestMode {
            CookieSync.bootstrap()
        }
        let inMemoryOnly = config.isUITestMode || unitTestMode
        let initialResult: Result<ModelContainer, Error>
        if !config.simulateStoreFailure, !inMemoryOnly,
           let existing = MainActor.assumeIsolated({ Self.sharedModelContainer }) {
            initialResult = .success(existing)
        } else {
            initialResult = Self.makeContainer(
                simulateFailure: config.simulateStoreFailure,
                inMemoryOnly: inMemoryOnly
            )
        }
        if case .success(let container) = initialResult, !unitTestMode {
            MainActor.assumeIsolated {
                if !inMemoryOnly {
                    Self.sharedModelContainer = container
                }
                AppDependencies.live.bindIfNeeded(modelContainer: container)
            }
        }
        _containerResult = State(initialValue: initialResult)
    }

    static var appSchema: Schema {
        Schema(versionedSchema: DSNovelSchemaV1.self)
    }

    @MainActor
    static func ensureSharedModelContainerForBackground() -> ModelContainer? {
        if let existing = sharedModelContainer {
            return existing
        }
        switch makeContainer(simulateFailure: false, inMemoryOnly: false) {
        case .success(let container):
            sharedModelContainer = container
            return container
        case .failure(let error):
            NSLog("[DSNovelApp] 后台冷启初始化 ModelContainer 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func makeContainer(simulateFailure: Bool = false, inMemoryOnly: Bool = false) -> Result<ModelContainer, Error> {
        if simulateFailure {
            return .failure(SimulatedStoreFailureError())
        }
        let config = ModelConfiguration(schema: appSchema, isStoredInMemoryOnly: inMemoryOnly)
        do {
            let container = try ModelContainer(
                for: appSchema,
                migrationPlan: DSNovelMigrationPlan.self,
                configurations: [config]
            )
            return .success(container)
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    private func performBackupAndRebuild() {
        do {
            _ = try StoreBackup.backupCurrentStore()
            try StoreBackup.removeStoreFiles()
            Self.sharedModelContainer = nil
            let result = Self.makeContainer(simulateFailure: false)
            if case .success(let container) = result {
                Self.sharedModelContainer = container
                dependencies.bindIfNeeded(modelContainer: container)
                repairErrorMessage = nil
            } else if case .failure(let err) = result {
                repairErrorMessage = "重建数据库失败：\(err.localizedDescription)"
            }
            containerResult = result
        } catch {
            repairErrorMessage = "备份或清理旧数据库文件失败：\(error.localizedDescription)"
            containerResult = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                // 单元测试阶段跳过宿主 AppShell 挂载与后台网络/Cookie/URLSession 初始化，
                // 避免与单测并发竞争全局单例或触发模拟器 nsurlsessiond XPC 意外退出。
                Color.clear
            } else {
            switch containerResult {
            case .success(let modelContainer):
                AppShell(dependencies: dependencies)
                    .environment(\.appDependencies, dependencies)
                    .preferredColorScheme(settings.appearanceMode.colorScheme)
                    .task {
                        let context = modelContainer.mainContext
                        let launch = AppLaunchConfig.current
                        dependencies.bindIfNeeded(modelContainer: modelContainer)
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
                            dependencies.libraryStore.refreshNow()
                            dependencies.sourceStore.refreshNow()
                            autoResumeIfNeeded(context: context, allowAutoPlay: true)
                            return
                        }
                        #endif

                        // S4：.restorePaused 保持首帧秒出；.autoPlay 与下载恢复延后到并行 reload 完成后触发
                        if settings.launchBehavior == .restorePaused {
                            autoResumeIfNeeded(context: context, allowAutoPlay: false)
                        }
                        // 将 WKWebView 全量 Cookie 同步延后至后台异步执行，避免阻塞冷启动
                        Task(priority: .utility) {
                            _ = await CookieSync.pullFromWebView()
                        }
                        await BundledSourceSeeder.seedIfNeeded(modelContext: context)
                        async let reloadPlugins: Void = PluginRuntime.shared.reloadInstalledPackages()
                        async let reloadBuiltinParsers = BuiltinParserRuntime.shared.reload()
                        let (_, installedParsers) = await (reloadPlugins, reloadBuiltinParsers)
                        BuiltinParserRegistrySync.syncRecords(context: context, diskParsers: installedParsers)
                        dependencies.libraryStore.refreshNow()
                        dependencies.sourceStore.refreshNow()
                        if settings.launchBehavior == .autoPlay {
                            autoResumeIfNeeded(context: context, allowAutoPlay: true)
                        }
                        downloadManager.recoverInterruptedItems()
                    }
                    .modelContainer(modelContainer)

            case .failure(let error):
                DataRepairView(
                    errorDescription: error.localizedDescription,
                    onRetry: {
                        let result = Self.makeContainer(simulateFailure: false)
                        if case .success(let container) = result {
                            Self.sharedModelContainer = container
                            dependencies.bindIfNeeded(modelContainer: container)
                            repairErrorMessage = nil
                        }
                        containerResult = result
                    },
                    onBackupAndRebuild: {
                        performBackupAndRebuild()
                    }
                )
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(Color.dsAccent)
                .dsSyncReduceMotion(override: settings.reduceMotionOverride)
                .alert(
                    "重建数据库失败",
                    isPresented: Binding(
                        get: { repairErrorMessage != nil },
                        set: { if !$0 { repairErrorMessage = nil } }
                    )
                ) {
                    Button("重试") {
                        repairErrorMessage = nil
                        performBackupAndRebuild()
                    }
                    Button("取消", role: .cancel) {
                        repairErrorMessage = nil
                    }
                } message: {
                    Text(repairErrorMessage ?? "")
                }
            }
            }
        }
    }

    @MainActor
    private func autoResumeIfNeeded(context: ModelContext, allowAutoPlay: Bool = true) {
        guard settings.launchBehavior != .doNothing, player.currentBook == nil else { return }
        if settings.launchBehavior == .autoPlay && !allowAutoPlay { return }
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
