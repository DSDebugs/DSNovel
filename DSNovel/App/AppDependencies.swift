import SwiftUI
import SwiftData

/// 应用级依赖组合根（P12 / S9）：
/// 统一托管核心 Store 与服务实例并通过 SwiftUI Environment 注入，
/// 默认绑定各自 `.shared` 单例以保持与现有代码及单元测试 100% 兼容。
@MainActor
final class AppDependencies {
    static let live: AppDependencies = {
        let instance = AppDependencies()
        AppDependenciesFallbackBox.shared.storeIfNil(instance)
        return instance
    }()

    let settings: AppSettingsStore
    let router: AppRouter
    let player: PlayerEngine
    let libraryStore: LibraryStore
    let sourceStore: SourceStore
    let discoverStore: DiscoverStore
    let searchStore: SearchStore
    let downloadManager: DownloadManager
    let bannerCenter: BannerCenter
    let networkMonitor: NetworkReachabilityMonitor
    private(set) var persistenceActor: PersistenceActor?

    init(
        settings: AppSettingsStore = .shared,
        router: AppRouter = .shared,
        player: PlayerEngine = .shared,
        libraryStore: LibraryStore = .shared,
        sourceStore: SourceStore = .shared,
        discoverStore: DiscoverStore = .shared,
        searchStore: SearchStore = .shared,
        downloadManager: DownloadManager = .shared,
        bannerCenter: BannerCenter = .shared,
        networkMonitor: NetworkReachabilityMonitor = .shared,
        persistenceActor: PersistenceActor? = nil
    ) {
        self.settings = settings
        self.router = router
        self.player = player
        self.libraryStore = libraryStore
        self.sourceStore = sourceStore
        self.discoverStore = discoverStore
        self.searchStore = searchStore
        self.downloadManager = downloadManager
        self.bannerCenter = bannerCenter
        self.networkMonitor = networkMonitor
        self.persistenceActor = persistenceActor
        DSEnvironmentFallbackStore.prime(settings: settings, bannerCenter: bannerCenter, router: router)
    }

    func bind(modelContext: ModelContext) {
        player.modelContext = modelContext
        downloadManager.modelContext = modelContext
        libraryStore.modelContext = modelContext
        sourceStore.modelContext = modelContext
    }

    func bind(modelContainer: ModelContainer) {
        let actor = PersistenceActor(modelContainer: modelContainer)
        persistenceActor = actor
        downloadManager.persistenceActor = actor
        ChapterProgressCache.shared.persistenceActor = actor
        player.persistenceActor = actor
        bind(modelContext: modelContainer.mainContext)
    }
}

private final class AppDependenciesFallbackBox: @unchecked Sendable {
    static let shared = AppDependenciesFallbackBox()
    private let lock = NSLock()
    private var cached: AppDependencies?

    func load() -> AppDependencies? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func store(_ value: AppDependencies) {
        lock.lock()
        cached = value
        lock.unlock()
    }

    func storeIfNil(_ value: AppDependencies) {
        lock.lock()
        if cached == nil {
            cached = value
        }
        lock.unlock()
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies {
        get {
            if let existing = self[AppDependenciesKey.self] {
                return existing
            }
            if Thread.isMainThread {
                let live = MainActor.assumeIsolated { AppDependencies.live }
                AppDependenciesFallbackBox.shared.storeIfNil(live)
                return live
            }
            if let cached = AppDependenciesFallbackBox.shared.load() {
                return cached
            }
            // M9：冷缓存且首次读取发生在非主线程时安全回退至主队列获取共享实例，避免 preconditionFailure 崩溃
            let live: AppDependencies = DispatchQueue.main.sync {
                MainActor.assumeIsolated { AppDependencies.live }
            }
            AppDependenciesFallbackBox.shared.storeIfNil(live)
            return live
        }
        set {
            self[AppDependenciesKey.self] = newValue
            AppDependenciesFallbackBox.shared.store(newValue)
        }
    }
}
