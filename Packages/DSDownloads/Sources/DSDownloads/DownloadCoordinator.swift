import DSCore
import DSPluginKit
import DSStorage
import Foundation
import Observation

/// 后台下载核心协调器（实现 OfflineAudioLocating；双池调度 + 状态机校验 + 退避 + 后台冷启 staging 认领）
@Observable
@MainActor
public final class DownloadCoordinator: OfflineAudioLocating {
    public private(set) var manualRecords: [DownloadRecordSnapshot] = []
    public internal(set) var totalDiskBytes: Int64 = 0
    public internal(set) var completedRevision: UInt64 = 0
    public var dynamicPrecacheCapBytes: Int64?
    public var onPrecacheCompleted: (@MainActor () async -> Void)?
    public var isWaitingForWiFi: Bool { wifiOnlyEnabled && !isCurrentlyOnWiFi }
    public let progressFeed = DownloadProgressFeed()

    let persistence: PersistenceEngine
    let audioResolver: any AudioResolving
    let transport: BackgroundTransferTransport
    let reconciler: StorageReconciler
    let downloadsRoot: URL
    let logger: DSDiagnosticLogStore
    public var minimumFreeDiskBytes: Int64
    let freeDiskBytesProvider: (@Sendable () -> Int64?)?

    var scheduler = DownloadScheduler(maxManualConcurrent: 3, maxPrecacheConcurrent: 1)
    var wifiOnlyEnabled: Bool = true
    var isCurrentlyOnWiFi: Bool = true
    public var allowUltraHighQuality: Bool = false
    var autoPausedForCellularIDs: Set<String> = []
    var policyTransitionTask: Task<Void, Never>?
    var allRecordsByID: [String: DownloadRecordSnapshot] = [:]
    var resolveTasks: [String: Task<Void, Never>] = [:]
    var retryTasks: [String: Task<Void, Never>] = [:]
    var inFlightFinalizingIDs: Set<String> = []
    var isBootstrapped: Bool = false
    var isBootstrapFinished: Bool = false
    var dirtyPersistenceIDs: Set<String> = []
    var dirtyRetryTask: Task<Void, Never>?
    var dirtyRetryAttemptCount: Int = 0
    private(set) var didLoadPersistenceSuccessfully: Bool = false
    var pendingTransferEvents: [BackgroundTransferEvent] = []
    var expectedExtByTaskID: [String: String] = [:]
    var resolvedQualityByTaskID: [String: AudioQualityTier] = [:]
    var progressSampleByTaskID: [String: (timestamp: Date, bytes: Int64)] = [:]
    var inFlightEventTasks: [UUID: Task<Void, Never>] = [:]
    var pendingBackgroundCompletions: [@Sendable () -> Void] = []
    var activePrecacheWindow: (bookID: String, chapterIndex: Int, keepAhead: Int)?

    public init(
        persistence: PersistenceEngine,
        audioResolver: any AudioResolving,
        downloadsRoot: URL? = nil,
        transport: BackgroundTransferTransport? = nil,
        logger: DSDiagnosticLogStore,
        minimumFreeDiskBytes: Int64 = 100 * 1024 * 1024,
        freeDiskBytesProvider: (@Sendable () -> Int64?)? = nil
    ) {
        let root = downloadsRoot
            ?? StorageContainerFactory.defaultStorageDirectory().appendingPathComponent("Downloads", isDirectory: true)
        self.downloadsRoot = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.persistence = persistence
        self.audioResolver = audioResolver
        self.transport = transport ?? BackgroundTransferTransport(baseDirectory: root)
        self.reconciler = StorageReconciler(downloadsRoot: root)
        self.logger = logger
        self.minimumFreeDiskBytes = max(0, minimumFreeDiskBytes)
        self.freeDiskBytesProvider = freeDiskBytesProvider

        self.transport.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleTransferEvent(event)
            }
        }
        self.transport.setBackgroundDrainHandler { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion()
                    return
                }
                self.enqueueBackgroundCompletion(completion)
            }
        }
    }

    public func bootstrapAndRecover() async {
        defer {
            if !isBootstrapped {
                isBootstrapped = true
                let buffered = pendingTransferEvents
                pendingTransferEvents.removeAll()
                for ev in buffered { handleTransferEvent(ev) }
            }
            isBootstrapFinished = true
            drainBackgroundCompletionsIfIdle()
        }
        do {
            let reattached = await transport.reattachActiveTasks()
            let loaded = try await persistence.fetchAllDownloadsPaginated(pageSize: 400)
            didLoadPersistenceSuccessfully = true
            allRecordsByID.removeAll()
            var recoveredBatch: [DownloadRecordSnapshot] = []
            for var rec in loaded {
                if reattached.contains(rec.id) {
                    rec.state = .downloading
                    scheduler.markStarted(id: rec.id, kind: rec.kind)
                } else if rec.state == .resolving || rec.state == .downloading {
                    rec.state = .queued
                    recoveredBatch.append(rec)
                }
                allRecordsByID[rec.id] = rec
            }
            if !recoveredBatch.isEmpty {
                await persistBatchWithLogging(recoveredBatch, context: "启动恢复")
            }
            isBootstrapped = true
            let buffered = pendingTransferEvents
            pendingTransferEvents.removeAll()
            for ev in buffered { handleTransferEvent(ev) }
            let dispatchedEventTasks = Array(inFlightEventTasks.values)
            for task in dispatchedEventTasks {
                await task.value
            }
            refreshManualRecords()
            recomputeTotalDiskBytes()
            await claimPendingStagingFiles()
            await reconcileDisk(force: false)
            scheduleNextIfPossible()
        } catch {
            await logger.record(category: .downloads, level: "ERROR", message: "加载下载记录失败：\(error.localizedDescription)")
        }
    }

    public func handleBackgroundURLSessionEvents(completionHandler: @escaping @Sendable () -> Void) {
        transport.handleBackgroundEvents(completionHandler: completionHandler)
    }

    public func enqueueManual(book: BookSummaryDTO, chapters: [ChapterDTO], quality: AudioQualityTier) async {
        await enqueue(book: book, chapters: chapters, kind: .manual, quality: quality)
    }

    public func enqueuePrecache(book: BookSummaryDTO, chapters: [ChapterDTO], quality: AudioQualityTier) async {
        await enqueue(book: book, chapters: chapters, kind: .precache, quality: quality)
    }

    public func pause(id: String) async {
        guard let initial = allRecordsByID[id], initial.state.canTransition(to: .paused) else { return }
        autoPausedForCellularIDs.remove(id)
        resolveTasks[id]?.cancel()
        resolveTasks.removeValue(forKey: id)
        retryTasks[id]?.cancel()
        retryTasks.removeValue(forKey: id)
        progressSampleByTaskID.removeValue(forKey: id)
        progressFeed.clearSpeed(for: id)
        await transport.pauseDownload(taskID: id)
        scheduler.markFinished(id: id)
        guard var latest = allRecordsByID[id], latest.state.canTransition(to: .paused) else {
            scheduleNextIfPossible()
            return
        }
        latest.state = .paused
        allRecordsByID[id] = latest
        await persistRecordWithDirtyRetry(latest)
        refreshManualRecords()
        scheduleNextIfPossible()
    }

    public func resume(id: String) async {
        guard var rec = allRecordsByID[id],
              rec.state == .paused || rec.state == .failed || rec.state == .cancelled,
              rec.state.canTransition(to: .queued) else { return }
        retryTasks[id]?.cancel()
        retryTasks.removeValue(forKey: id)
        rec.state = .queued
        rec.retryCount = 0
        rec.retryNotBefore = nil
        rec.errorMessage = nil
        allRecordsByID[id] = rec
        await persistRecordWithDirtyRetry(rec)
        refreshManualRecords()
        scheduleNextIfPossible()
    }

    public func cancelAndDelete(id: String) async {
        resolveTasks[id]?.cancel()
        resolveTasks.removeValue(forKey: id)
        retryTasks[id]?.cancel()
        retryTasks.removeValue(forKey: id)
        autoPausedForCellularIDs.remove(id)
        expectedExtByTaskID.removeValue(forKey: id)
        resolvedQualityByTaskID.removeValue(forKey: id)
        progressSampleByTaskID.removeValue(forKey: id)
        transport.cancelDownload(taskID: id)
        scheduler.markFinished(id: id)
        progressFeed.remove(id: id)

        if let existing = allRecordsByID.removeValue(forKey: id), let rel = existing.localRelPath {
            try? FileManager.default.removeItem(at: downloadsRoot.appendingPathComponent(rel))
        }
        try? await persistence.deleteDownload(id: id)
        recomputeTotalDiskBytes()
        completedRevision &+= 1
        refreshManualRecords()
        scheduleNextIfPossible()
    }

    public func clearAllPrecache() async {
        let targets = allRecordsByID.values.filter { $0.kind == .precache }.map(\.id)
        if !targets.isEmpty {
            for id in targets {
                resolveTasks[id]?.cancel()
                resolveTasks.removeValue(forKey: id)
                retryTasks[id]?.cancel()
                retryTasks.removeValue(forKey: id)
                autoPausedForCellularIDs.remove(id)
                expectedExtByTaskID.removeValue(forKey: id)
                resolvedQualityByTaskID.removeValue(forKey: id)
                progressSampleByTaskID.removeValue(forKey: id)
                transport.cancelDownload(taskID: id)
                scheduler.markFinished(id: id)
                progressFeed.remove(id: id)
                if let existing = allRecordsByID.removeValue(forKey: id), let rel = existing.localRelPath {
                    try? FileManager.default.removeItem(at: downloadsRoot.appendingPathComponent(rel))
                }
            }
            _ = try? await persistence.deleteDownloadsBatch(ids: targets)
            recomputeTotalDiskBytes()
            completedRevision &+= 1
            refreshManualRecords()
            scheduleNextIfPossible()
        }
        await reconcileDisk(force: true)
    }

    public func deleteBookDownloads(bookID: String) async {
        let targets = allRecordsByID.values.filter { $0.bookID == bookID }.map(\.id)
        guard !targets.isEmpty else { return }
        for id in targets {
            resolveTasks[id]?.cancel()
            resolveTasks.removeValue(forKey: id)
            retryTasks[id]?.cancel()
            retryTasks.removeValue(forKey: id)
            autoPausedForCellularIDs.remove(id)
            expectedExtByTaskID.removeValue(forKey: id)
            resolvedQualityByTaskID.removeValue(forKey: id)
            progressSampleByTaskID.removeValue(forKey: id)
            transport.cancelDownload(taskID: id)
            scheduler.markFinished(id: id)
            progressFeed.remove(id: id)
            if let existing = allRecordsByID.removeValue(forKey: id), let rel = existing.localRelPath {
                try? FileManager.default.removeItem(at: downloadsRoot.appendingPathComponent(rel))
            }
        }
        _ = try? await persistence.deleteDownloadsBatch(ids: targets)
        recomputeTotalDiskBytes()
        completedRevision &+= 1
        refreshManualRecords()
        scheduleNextIfPossible()
        await reconcileDisk(force: true)
    }

    // MARK: - OfflineAudioLocating

    public func localAudioURL(bookID: String, chapterID: String) async -> URL? {
        let id = Self.makeRecordID(bookID: bookID, chapterID: chapterID)
        guard let rec = allRecordsByID[id], rec.state == .completed, let rel = rec.localRelPath else {
            return nil
        }
        let full = downloadsRoot.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: full.path) ? full : nil
    }

    public func isDownloaded(bookID: String, chapterID: String) async -> Bool {
        await localAudioURL(bookID: bookID, chapterID: chapterID) != nil
    }

    func refreshManualRecords() {
        manualRecords = allRecordsByID.values
            .filter { $0.kind == .manual }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func recomputeTotalDiskBytes() {
        totalDiskBytes = allRecordsByID.values
            .filter { $0.state == .completed }
            .reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
    }

    public static func makeRecordID(bookID: String, chapterID: String) -> String {
        "\(DSCrypto.md5Hex(bookID))_\(DSCrypto.md5Hex(chapterID))"
    }
}
