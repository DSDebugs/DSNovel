import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSPluginKit
import DSStorage
import Foundation
import Observation
import SwiftData
import UIKit

private final class BackgroundTaskToken: @unchecked Sendable {
    var taskID: UIBackgroundTaskIdentifier = .invalid
}

/// 依赖组合根（ARC-04：零强制解包、单实例 HeadlessWebViewService、冷启恢复内置解析器；UI-02/ARC-08：接入 NWPathMonitor 与 4 项设置联动）
@Observable
@MainActor
final class AppContainer {
    private static var bootstrappedInstance: AppContainer?

    let storageResult: StorageBootstrapResult
    let modelContainer: ModelContainer
    let persistence: PersistenceEngine
    let chapterCache: ChapterCacheStore
    let listeningStats: ListeningStatsStore
    let backupManager: StoreBackupManager
    let settings: AppSettingsStore
    let networkMonitor: NetworkReachabilityMonitor
    let logger: DSDiagnosticLogStore
    let cookieVault: CookieVault
    let httpClient: HostHTTPClient
    let webViewService: HeadlessWebViewService
    let builtinParser: BuiltinParserEngine
    let pluginRuntime: PluginRuntime
    let downloads: DownloadCoordinator
    let playback: PlaybackCoordinator
    let coverPipeline: CoverImagePipeline
    let banner: DSBannerCoordinator
    let router: AppRouter
    let sourceAuth = SourceAuthStateStore()

    /// 跨模块约定：书源/书架变更修订号，供 UI 层订阅刷新
    public var sourcesRevision: UInt64 = 0
    public var libraryRevision: UInt64 = 0
    public static let ximalayaSourceID = "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64"
    public var activeDiscoverSourceID: String = ""
    public var hasActiveBuiltinParser: Bool = false
    public private(set) var hasEnabledXimalayaSource: Bool = false
    var hasLoadedBuiltinParsers = false

    /// 只要存在已启用的音频解析脚本即开放超清音质（隐藏入口不影响后台解析与超清能力）
    public var canUseUltraHighQuality: Bool {
        hasActiveBuiltinParser
    }

    public func refreshBuiltinParserActiveState() async {
        let parsers = await builtinParser.listParsers()
        hasActiveBuiltinParser = parsers.contains(where: \.isEnabled)
        hasLoadedBuiltinParsers = true
        syncSettingsToEngines()
    }

    public var isDiscoverSourceXimalaya: Bool {
        activeDiscoverSourceID == Self.ximalayaSourceID
    }

    public func isMultiQualitySupported(sourceID: String, chapterURL: String) async -> Bool {
        if sourceID == Self.ximalayaSourceID { return true }
        return await builtinParser.supportsMultiQuality(sourceID: sourceID, chapterURL: chapterURL)
    }

    private var didStartAsyncServices = false
    private var didFinishSourcesRegistration = false
    private var sourcesReadyTask: Task<Void, Never>?
    private var didFinishDownloadsBootstrap = false
    private var downloadsBootstrapTask: Task<Void, Never>?
    private var activePruneTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activeMaintenanceTask: Task<Void, Never>?

    public func notifySourcesChanged(refreshXimalayaState: Bool = true) {
        sourcesRevision &+= 1
        if refreshXimalayaState {
            Task { @MainActor [weak self] in await self?.refreshEnabledXimalayaSourceState() }
        }
    }

    public func refreshEnabledXimalayaSourceState() async {
        guard let allSources = try? await persistence.fetchAllSources() else { return }
        updateHasEnabledXimalayaSource(from: allSources)
    }

    private func updateHasEnabledXimalayaSource(from sources: [(meta: SourceMetaDTO, scriptBody: String)]) {
        hasEnabledXimalayaSource = sources.contains { $0.meta.id == Self.ximalayaSourceID && $0.meta.isEnabled }
    }

    public func notifyLibraryChanged() { libraryRevision &+= 1 }

    static var existingInstance: AppContainer? { bootstrappedInstance }

    static func bootstrapIfNeeded() -> AppContainer? {
        if let existing = bootstrappedInstance { return existing }
        guard let created = try? AppContainer() else { return nil }
        bootstrappedInstance = created
        return created
    }

    init(inMemoryOnly: Bool = AppLaunchConfig.isUITesting) throws {
        let storageDir: URL
        if inMemoryOnly {
            let folder = AppLaunchConfig.shouldResetState ? "DSNovelV3-UITestReset" : "DSNovelV3-InMemory-\(UUID().uuidString)"
            storageDir = FileManager.default.temporaryDirectory.appendingPathComponent(folder, isDirectory: true)
            if AppLaunchConfig.shouldResetState { try? FileManager.default.removeItem(at: storageDir) }
            try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } else {
            storageDir = StorageContainerFactory.defaultStorageDirectory()
        }
        let result = try Self.bootstrapStorage(inMemoryOnly: inMemoryOnly, storageDir: storageDir)

        self.storageResult = result
        self.modelContainer = result.container
        self.persistence = PersistenceEngine.makeOffMain(modelContainer: result.container)
        Self.excludeCachesFromBackup(baseDir: storageDir)
        self.listeningStats = ListeningStatsStore(storageDirectory: inMemoryOnly ? nil : storageDir)
        self.chapterCache = ChapterCacheStore(baseDirectory: storageDir)
        self.backupManager = StoreBackupManager(storeURL: result.storeURL)

        let defaults: UserDefaults
        if AppLaunchConfig.shouldResetState {
            let suiteName = "com.dsnovel.v3.uitest.reset"
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else if inMemoryOnly {
            defaults = UserDefaults(suiteName: "com.dsnovel.v3.inmemory.\(UUID().uuidString)") ?? .standard
        } else {
            defaults = .standard
        }
        self.settings = AppSettingsStore(defaults: defaults)
        self.activeDiscoverSourceID = self.settings.lastDiscoverSourceID
        self.networkMonitor = NetworkReachabilityMonitor(startImmediately: !inMemoryOnly)
        self.logger = DSDiagnosticLogStore()
        self.cookieVault = CookieVault(inMemorySecretsOnly: inMemoryOnly)
        self.httpClient = HostHTTPClient(cookieVault: cookieVault)
        self.webViewService = HeadlessWebViewService()

        let prelude = Self.loadBundledResource(named: "prelude", ext: "js")
        let preludeParser = Self.loadBundledResource(named: "prelude_parser", ext: "js")

        self.builtinParser = BuiltinParserEngine(
            preludeParserScript: preludeParser,
            storageDir: storageDir.appendingPathComponent("BuiltinParsers", isDirectory: true),
            httpClient: httpClient,
            cookieVault: cookieVault,
            logger: logger,
            webViewService: webViewService
        )
        self.pluginRuntime = PluginRuntime(
            preludeScript: prelude,
            httpClient: httpClient,
            cookieVault: cookieVault,
            cacheRoot: storageDir.appendingPathComponent("PluginCache", isDirectory: true),
            logger: logger,
            builtinParser: builtinParser,
            webViewService: webViewService
        )
        let downloadsRoot = storageDir.appendingPathComponent("Downloads", isDirectory: true)
        let downloadTransport: BackgroundTransferTransport? = inMemoryOnly
            ? BackgroundTransferTransport(
                baseDirectory: downloadsRoot,
                sessionIdentifier: "com.dsnovel.v3.background.inmemory.\(UUID().uuidString)"
            )
            : nil
        self.downloads = DownloadCoordinator(
            persistence: persistence,
            audioResolver: pluginRuntime,
            downloadsRoot: downloadsRoot,
            transport: downloadTransport,
            logger: logger
        )
        self.playback = PlaybackCoordinator(
            audioResolver: pluginRuntime,
            offlineLocator: downloads,
            progressStore: persistence,
            logger: logger
        )
        self.coverPipeline = CoverImagePipeline()
        self.banner = DSBannerCoordinator()
        self.router = AppRouter()

        if result.isDegradedInMemory, let errDesc = result.startupErrorDescription {
            let logStore = self.logger
            Task { await logStore.record(category: .storage, level: "ERROR", message: errDesc) }
        }

        if !inMemoryOnly {
            playback.dsp.bindPersistence(defaults)
            playback.sleepTimer.bindPersistence(defaults)
        }
        syncSettingsToEngines()
        wireReactiveLinks(registerGlobalBackgroundSession: !inMemoryOnly && !result.isDegradedInMemory)
    }

    /// 同步用户偏好至播放与下载引擎（UI-02/AUD-55：彻底消除假开关，解析器加载前仅临时夹紧播放音质）
    func syncSettingsToEngines() {
        playback.playbackRate = settings.playbackRate
        let allowUltraHigh = hasLoadedBuiltinParsers && canUseUltraHighQuality
        if hasLoadedBuiltinParsers && !canUseUltraHighQuality && settings.preferredQuality == .high {
            settings.preferredQuality = .standard
        }
        if let activeBook = playback.currentBook {
            playback.preferredQuality = resolvedQuality(for: activeBook)
        } else {
            playback.preferredQuality = (!allowUltraHigh && settings.preferredQuality == .high) ? .standard : settings.preferredQuality
        }
        playback.allowUltraHighQuality = allowUltraHigh
        downloads.allowUltraHighQuality = allowUltraHigh
        playback.autoPlayNextChapter = settings.autoPlayNextChapter
        playback.isOnWiFi = networkMonitor.isOnWiFi
        downloads.updatePolicy(
            wifiOnly: settings.wifiOnlyDownload,
            maxManualConcurrent: settings.maxConcurrentDownloads,
            isOnWiFi: networkMonitor.isOnWiFi
        )
    }

    func ensureDownloadsBootstrappedIfNeeded() async {
        guard !storageResult.isDegradedInMemory else { return }
        if let existing = downloadsBootstrapTask {
            await existing.value
            return
        }
        let dl = downloads
        let task = Task { @MainActor in await dl.bootstrapAndRecover() }
        downloadsBootstrapTask = task
        await task.value
        didFinishDownloadsBootstrap = true
    }

    func ensureSourcesRegistered() async {
        guard !storageResult.isDegradedInMemory else { return }
        if didFinishSourcesRegistration { return }
        if let existing = sourcesReadyTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.builtinParser.loadPersistedParsers()
            await self.refreshBuiltinParserActiveState()
            await BundledSourceSeeder.seedIfNeeded(
                persistence: self.persistence,
                pluginRuntime: self.pluginRuntime,
                settings: self.settings,
                logger: self.logger
            )
            do {
                let allSources = try await self.persistence.fetchAllSources()
                await self.pluginRuntime.registerSources(allSources)
                self.updateHasEnabledXimalayaSource(from: allSources)
                self.didFinishSourcesRegistration = true
                self.notifySourcesChanged(refreshXimalayaState: false)
            } catch {
                self.didFinishSourcesRegistration = true
                await self.logger.record(category: .storage, level: "ERROR", message: "加载书源列表失败：\(error.localizedDescription)")
            }
        }
        sourcesReadyTask = task
        await task.value
    }

    func startAsyncServicesIfNeeded() async {
        guard !storageResult.isDegradedInMemory, !didStartAsyncServices else { return }
        didStartAsyncServices = true
        let needsRemoteChapters = await restoreLastPlaybackFromCache()
        await ensureSourcesRegistered()
        if needsRemoteChapters {
            await restoreLastPlaybackFromSourceIfNeeded()
        }
        await networkMonitor.waitForInitialPath(timeoutSeconds: 0.5)
        syncSettingsToEngines()
        await ensureDownloadsBootstrappedIfNeeded()
    }

    /// 退后台时使用 beginBackgroundTask 触发单批 fetchLimit=200 历史裁剪（P1-07/AUD-20：taskID 守卫防止旧任务清空新句柄）
    func performBackgroundMaintenance() {
        playback.flushProgressForBackground()
        listeningStats.flushToDisk()
        activeMaintenanceTask?.cancel()
        activeMaintenanceTask = nil
        if activePruneTaskID != .invalid { endBackgroundPruneTask(matching: activePruneTaskID) }

        let token = BackgroundTaskToken()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "DSNovelV3Prune") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activePruneTaskID == token.taskID else { return }
                self.activeMaintenanceTask?.cancel()
                self.endBackgroundPruneTask(matching: token.taskID)
            }
        }
        token.taskID = taskID
        activePruneTaskID = taskID
        guard taskID != .invalid else { return }

        let store = persistence
        let backup = backupManager
        activeMaintenanceTask = Task { [weak self] in
            if !Task.isCancelled { _ = try? await store.pruneOldChapterProgress(keepLatestPerBook: 500) }
            if !Task.isCancelled { _ = try? await backup.createBackupIfNeeded(minIntervalSeconds: 86_400) }
            await MainActor.run { [weak self] in self?.endBackgroundPruneTask(matching: taskID) }
        }
    }

    private func endBackgroundPruneTask(matching expectedID: UIBackgroundTaskIdentifier) {
        guard expectedID != .invalid, activePruneTaskID == expectedID else { return }
        activeMaintenanceTask = nil
        UIApplication.shared.endBackgroundTask(expectedID)
        activePruneTaskID = .invalid
    }

    private func wireReactiveLinks(registerGlobalBackgroundSession: Bool) {
        if registerGlobalBackgroundSession {
            BackgroundSessionCoordinator.shared.registerHandler { [weak self] completion in
                guard let self else { completion(); return }
                if self.didFinishDownloadsBootstrap {
                    self.downloads.handleBackgroundURLSessionEvents(completionHandler: completion)
                } else {
                    Task { @MainActor [weak self] in
                        guard let self else { completion(); return }
                        await self.ensureDownloadsBootstrappedIfNeeded()
                        self.downloads.handleBackgroundURLSessionEvents(completionHandler: completion)
                    }
                }
            }
        }

        networkMonitor.setOnInitialNetworkStateSynced { [weak self] isWiFi in
            guard let self else { return }
            self.playback.isOnWiFi = isWiFi
            self.downloads.updatePolicy(
                wifiOnly: self.settings.wifiOnlyDownload,
                maxManualConcurrent: self.settings.maxConcurrentDownloads,
                isOnWiFi: isWiFi
            )
        }

        networkMonitor.setOnNetworkTypeChanged { [weak self] isWiFi in
            guard let self else { return }
            self.playback.isOnWiFi = isWiFi
            self.downloads.invalidateResumeDataOnAuthOrNetworkChange()
            self.downloads.updatePolicy(
                wifiOnly: self.settings.wifiOnlyDownload,
                maxManualConcurrent: self.settings.maxConcurrentDownloads,
                isOnWiFi: isWiFi
            )
        }

        playback.onRecordListeningDelta = { [weak self] book, delta in
            self?.listeningStats.recordListening(book: book, deltaSeconds: delta)
        }

        playback.onResolveBookQuality = { [weak self] book in
            self?.resolvedQuality(for: book) ?? .auto
        }

        playback.onRequestPrecache = { [weak self] book, upcomingChapters in
            guard let self else { return }
            let count = self.settings.precacheNextCount
            guard count > 0, !upcomingChapters.isEmpty else { return }
            if self.settings.wifiOnlyDownload && !self.networkMonitor.isOnWiFi { return }
            let slice = Array(upcomingChapters.prefix(count))
            Task {
                await self.downloads.enqueuePrecache(book: book, chapters: slice, quality: self.resolvedQuality(for: book))
            }
        }
    }

}
