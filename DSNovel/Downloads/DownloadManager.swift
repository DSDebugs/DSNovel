import Foundation
import AVFoundation
import CryptoKit
import Observation
import SwiftData
import UIKit

struct DownloadItemSnapshot: Identifiable, Equatable, Hashable, Sendable {
    var id: String // bookID + "::" + chapterID
    var bookID: String
    var bookTitle: String
    var chapterID: String
    var chapterTitle: String
    var sourceID: String
    var kind: String
    var state: String
    var localPath: String
    var bytes: Int64
    var retryCount: Int
    var createdAt: Date
    var isFileVerified: Bool
    var qualityTierSnapshot: String = ""
    var qualityIsStale: Bool = false
    var lastErrorMessage: String = ""

    func isStale(against currentTierRaw: String) -> Bool {
        guard QualityPolicy.sourceHasMultipleBitrates(sourceID: sourceID) else { return false }
        guard state == "completed" || (!localPath.isEmpty && state != "failed") else { return false }
        if qualityIsStale { return true }
        guard !qualityTierSnapshot.isEmpty else { return false }
        return qualityTierSnapshot != currentTierRaw
    }
}

struct DownloadSummary: Equatable, Hashable, Sendable {
    var bookID: String
    var bookTitle: String
    var sourceID: String
    var completedCount: Int
    var totalCount: Int
    var totalBytes: Int64
    var failedCount: Int
    var activeCount: Int = 0
}

enum DownloadError: LocalizedError, Equatable, Sendable {
    case insufficientDisk
    case unsupportedStream

    var errorDescription: String? {
        switch self {
        case .insufficientDisk:
            return "设备存储空间不足，无法添加新的下载任务"
        case .unsupportedStream:
            return "该章节为实时流媒体格式，不支持离线下载"
        }
    }
}

/// 后台串行音频文件校验与落盘处理器（魔数嗅探 + 完整性校验 + 移盘 + staging 孤儿 .tmp 清理）
actor DownloadFileProcessor {
    static let shared = DownloadFileProcessor()

    enum ProcessOutcome: Sendable {
        case success(relPath: String, fileSize: Int64)
        case invalidPayload
        case incompleteLength
        case moveFailed
    }

    func validateAndMove(
        tempFileURL: URL,
        bookID: String,
        chapterID: String,
        downloadsRoot: URL,
        mimeType: String?,
        originalURL: URL?,
        suggestedFilename: String?,
        expectedContentLength: Int64?
    ) -> ProcessOutcome {
        let fm = FileManager.default
        let mime = mimeType?.lowercased() ?? ""
        let fileSize = (try? fm.attributesOfItem(atPath: tempFileURL.path)[.size] as? Int64) ?? 0

        if mime.hasPrefix("text/") || mime.contains("mpegurl") || mime.contains("json") || mime.contains("html") || fileSize < 1024 {
            try? fm.removeItem(at: tempFileURL)
            return .invalidPayload
        }

        if let expected = expectedContentLength, expected > 0, fileSize < expected {
            try? fm.removeItem(at: tempFileURL)
            return .incompleteLength
        }

        let headerBytes = Self.readHeaderBytes(from: tempFileURL, maxCount: 32)
        if Self.isNonAudioTextPayload(headerBytes) {
            try? fm.removeItem(at: tempFileURL)
            return .invalidPayload
        }

        let ext = Self.inferAudioExtension(
            headerBytes: headerBytes,
            suggestedFilename: suggestedFilename,
            originalURL: originalURL,
            tempFileURL: tempFileURL,
            mimeType: mimeType
        )
        // 契约锁死：落盘相对路径必须严格遵循 "md5(bookID)/md5(chapterID).<ext>"，
        // sweepOrphanFiles() 的白名单 key（dir/stem）依赖此命名约定，切勿擅自改为服务端原始文件名。
        let safeBookDir = JsHostBridge.md5Hex(bookID)
        let safeChapFile = "\(JsHostBridge.md5Hex(chapterID)).\(ext)"
        let relPath = "\(safeBookDir)/\(safeChapFile)"
        let destDir = downloadsRoot.appendingPathComponent(safeBookDir, isDirectory: true)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = downloadsRoot.appendingPathComponent(relPath)
        // P2-1：不直接 unlink 正在播放的旧文件，改为重命名让位到 .prev（保留旧 inode 可读，
        // 若新文件 move 失败则立刻还原，避免旧离线文件丢失）。
        let prevFile = destFile.appendingPathExtension("prev")
        var movedOldToPrev = false
        if fm.fileExists(atPath: destFile.path) {
            try? fm.removeItem(at: prevFile)
            if (try? fm.moveItem(at: destFile, to: prevFile)) != nil {
                // §4：rename 继承旧文件 mtime，刷新为当前时间以确保 .prev 享有完整的 600s 保护窗口
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: prevFile.path)
                movedOldToPrev = true
            }
        }
        do {
            try fm.moveItem(at: tempFileURL, to: destFile)
            return .success(relPath: relPath, fileSize: fileSize)
        } catch {
            try? fm.removeItem(at: tempFileURL)
            if movedOldToPrev && !fm.fileExists(atPath: destFile.path) {
                try? fm.moveItem(at: prevFile, to: destFile)
            }
            return .moveFailed
        }
    }

    func cleanupOrphanedStagingFiles(in stagingDir: URL, olderThan maxAgeSeconds: TimeInterval = 1800) {
        DownloadStorageReconciler.cleanupOrphanedStagingFilesOnDisk(in: stagingDir, olderThan: maxAgeSeconds)
    }

    func cleanupOrphanFiles(root: URL, whitelistKeys: Set<String>, minAgeSeconds: TimeInterval = 600) -> Int {
        DownloadStorageReconciler.cleanupOrphanFilesOnDisk(root: root, whitelistKeys: whitelistKeys, minAgeSeconds: minAgeSeconds)
    }

    private static func readHeaderBytes(from url: URL, maxCount: Int) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxCount)) ?? Data()
        return Array(data)
    }

    private static func isNonAudioTextPayload(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        var start = 0
        // 跳过 UTF-8 BOM 与前导空白
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            start = 3
        }
        while start < bytes.count && (bytes[start] == 0x20 || bytes[start] == 0x09 || bytes[start] == 0x0A || bytes[start] == 0x0D) {
            start += 1
        }
        guard start < bytes.count else { return true }
        let slice = Array(bytes[start..<min(bytes.count, start + 16)])
        if let prefix = String(bytes: slice, encoding: .utf8)?.lowercased() {
            if prefix.hasPrefix("<!doc") || prefix.hasPrefix("<html") || prefix.hasPrefix("<?xml")
                || prefix.hasPrefix("#extm3u") || prefix.hasPrefix("{\"") || prefix.hasPrefix("[{") {
                return true
            }
        }
        return false
    }

    private static func sniffAudioExtension(from bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        // ID3v2 tag (MP3)
        if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 {
            return "mp3"
        }
        // FLAC ("fLaC")
        if bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43 {
            return "flac"
        }
        // Ogg ("OggS")
        if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
            return "ogg"
        }
        // RIFF / WAV ("RIFF")
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "wav"
        }
        // ISO BMFF / MP4 / M4A ("ftyp" at offset 4)
        if bytes.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            return "m4a"
        }
        // ADTS AAC frame sync (0xFF 0xF1 or 0xFF 0xF9)
        if bytes[0] == 0xFF && (bytes[1] == 0xF1 || bytes[1] == 0xF9) {
            return "aac"
        }
        // MPEG Audio frame sync (0xFF + top 3 bits set)
        if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
            return "mp3"
        }
        return nil
    }

    private static func inferAudioExtension(
        headerBytes: [UInt8],
        suggestedFilename: String?,
        originalURL: URL?,
        tempFileURL: URL,
        mimeType: String?
    ) -> String {
        if let sniffed = sniffAudioExtension(from: headerBytes) {
            return sniffed
        }
        let validExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "mp4"]
        if let suggested = suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if validExts.contains(ext) { return ext }
        }
        if let origExt = originalURL?.pathExtension.lowercased(), validExts.contains(origExt) {
            return origExt
        }
        let tmpExt = tempFileURL.pathExtension.lowercased()
        if validExts.contains(tmpExt) {
            return tmpExt
        }
        if let mime = mimeType?.lowercased() {
            if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
            if mime.contains("mp4") || mime.contains("m4a") { return "m4a" }
            if mime.contains("aac") { return "aac" }
            if mime.contains("wav") { return "wav" }
            if mime.contains("flac") { return "flac" }
            if mime.contains("ogg") { return "ogg" }
        }
        return "mp3"
    }

    /// 探测音频文件真实时长与净码率（优先读取音频轨 estimatedDataRate，剥离内嵌封面/容器头；不可用时退回体积/时长估算）
    func probeAudioMetrics(at url: URL, fileSize: Int64) async -> (durationSec: Double, bitrateKbps: Int) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var durationSec: Double = 0
        if let cmDuration = try? await asset.load(.duration) {
            let sec = CMTimeGetSeconds(cmDuration)
            if sec.isFinite && sec > 0 {
                durationSec = sec
            }
        }
        var bitrateKbps: Int = 0
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           let track = audioTracks.first,
           let rate = try? await track.load(.estimatedDataRate),
           rate.isFinite && rate > 0 {
            bitrateKbps = Int((Double(rate) / 1000.0).rounded())
        }
        if bitrateKbps <= 0 && durationSec > 1 && fileSize > 0 {
            bitrateKbps = AudioQualityTier.computedBitrateKbps(bytes: fileSize, durationSec: durationSec) ?? 0
        }
        return (durationSec: durationSec, bitrateKbps: bitrateKbps)
    }
}

@MainActor
final class PendingRemoval {
    let bookID: String
    private var isCancelled = false
    private var isCommitted = false
    private var task: Task<Void, Never>?
    private let onCancel: () -> Void
    private let onCommit: () -> Void

    init(
        bookID: String,
        delaySeconds: TimeInterval = 5.0,
        scheduleTimer: Bool = true,
        onCancel: @escaping () -> Void,
        onCommit: @escaping () -> Void
    ) {
        self.bookID = bookID
        self.onCancel = onCancel
        self.onCommit = onCommit
        if scheduleTimer {
            self.task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.commitNow()
                }
            }
        }
    }

    func cancel() {
        guard !isCommitted, !isCancelled else { return }
        isCancelled = true
        task?.cancel()
        onCancel()
    }

    func commitNow() {
        guard !isCommitted, !isCancelled else { return }
        isCommitted = true
        task?.cancel()
        onCommit()
    }
}

/// 下载与预缓存调度器（全局单源增量状态同步 + 真实文件魔数核验 + Set 并发控制 + 后台接力）
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    var modelContext: ModelContext? {
        didSet {
            if modelContext != nil {
                rebuildSummariesFromContext()
                let waiters = contextWaiters
                contextWaiters.removeAll()
                for task in contextTimeoutTasks.values {
                    task.cancel()
                }
                contextTimeoutTasks.removeAll()
                for waiter in waiters.values {
                    waiter.resume()
                }
            }
        }
    }

    /// R3-4：后台持久化执行器，优先用于非关键异步写库（如音频指标补探测回写）
    @ObservationIgnored var persistenceActor: PersistenceActor?
    /// M2：失败重试退避窗口（避免瞬时打满 2 次重试触发源站限流）
    @ObservationIgnored private var retryNotBeforeByItemID: [String: Date] = [:]
    @ObservationIgnored private var retryWakeupTask: Task<Void, Never>?
    /// 测试可覆写退避基准（生产默认 1.0 -> 2s / 6s）
    @ObservationIgnored var retryBackoffScale: TimeInterval = 1.0

    private(set) var stateVersion: Int = 0
    /// 缓存的存储占用与磁盘余量统计（避免在 SwiftUI body 中直接执行 SwiftData fetch 或同步文件系统查询）
    private(set) var cachedManualDownloadedBytes: Int64 = 0
    private(set) var cachedTemporaryCacheBytes: Int64? = nil
    private(set) var cachedPrecacheBytes: Int64 = 0
    private(set) var cachedAvailableDiskBytes: Int64? = nil
    private(set) var summariesByBookID: [String: DownloadSummary] = [:]
    private(set) var snapshotsByBookID: [String: [String: DownloadItemSnapshot]] = [:]
    /// P1：向后兼容的 @ObservationIgnored 镜像，真实响应式进度与码率由 DownloadProgressStore.shared 托管
    @ObservationIgnored private(set) var itemProgress: [String: Double] = [:]
    @ObservationIgnored private(set) var inProgressBitrateKbpsByItemID: [String: Int] = [:]
    private(set) var deletingItemIDs: Set<String> = []
    private(set) var hiddenPendingRemovalBookIDs: Set<String> = []
    private(set) var isDiskInsufficient: Bool = false

    private let maxConcurrent = 3
    private let maxConcurrentPrecache = 1
    /// 集合式并发追踪（替代整数计数，彻底杜绝取消/暂停/删除/失败竞态导致的负值或死锁）
    @ObservationIgnored private var activeManualIDs: Set<String> = []
    @ObservationIgnored private var activePrecacheIDs: Set<String> = []
    /// 记录按新音质重下前的旧档位快照，失败回滚旧文件时同步还原
    @ObservationIgnored private var rollbackTierByItemID: [String: String] = [:]
    /// 解析流返回的已知章节时长缓存（用于下载中基于 expectedContentLength 独立核算码率）
    @ObservationIgnored private var resolvedDurationSecByItemID: [String: Double] = [:]
    private struct AudioMetricsProbeRequest: Sendable {
        let itemID: String
        let fileURL: URL
        let fileSize: Int64
        let expectedDurationSec: Double
        let overwriteExisting: Bool
    }
    /// 正在后台按需回填音频指标的条目 ID（防重入）
    @ObservationIgnored private var backfillingItemIDs: Set<String> = []
    /// R3-5：补探测单并发排队器，避免打开下载列表时并发 AVURLAsset 探测风暴
    @ObservationIgnored private var backfillQueue: [AudioMetricsProbeRequest] = []
    @ObservationIgnored private var backfillWorkerTask: Task<Void, Never>?
    /// P11：孤儿文件清理、磁盘统计与对账协调器
    @ObservationIgnored private let storageReconciler = DownloadStorageReconciler()
    /// S8：按批次持有后台接力任务句柄，避免并发完成互相提前终止后台任务
    @ObservationIgnored private var activeRelayBackgroundTasks: Set<UIBackgroundTaskIdentifier> = []
    /// S4：低优先级异步磁盘对账任务句柄
    @ObservationIgnored private var diskReconcileTask: Task<Void, Never>?
    /// S5：持有在途音频流解析任务句柄，暂停/删除时立即取消
    @ObservationIgnored private var resolvingTasksByItemID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolvingTaskTokens: [String: UUID] = [:]

    private struct ResumeRequestFingerprint: Equatable, Sendable {
        let allowsCellular: Bool
        let authDigest: String
        let urlHost: String
    }

    /// 7-3：记录每个条目当前活跃请求与已保存断点对应的鉴权/网络策略指纹，防止复用过期 resumeData
    @ObservationIgnored private var activeRequestFingerprintByItemID: [String: ResumeRequestFingerprint] = [:]
    @ObservationIgnored private var resumeFingerprintByItemID: [String: ResumeRequestFingerprint] = [:]

    var isOnWiFi = true {
        didSet {
            NetworkReachabilityMonitor.shared.updateIsOnWiFi(isOnWiFi)
            guard oldValue != isOnWiFi else { return }
            handleNetworkWiFiStateChanged(wasWiFi: oldValue, isWiFi: isOnWiFi)
        }
    }
    var minimumFreeDiskBytes: Int64 = 50 * 1024 * 1024 // 50 MB
    var availableDiskBytesProvider: @Sendable () -> Int64 = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? (10 * 1024 * 1024 * 1024)
    }

    /// 7-5：复用全局 `NetworkReachabilityMonitor.shared`，消除重复 `NWPathMonitor` 实例
    @ObservationIgnored private var networkSyncTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserverToken: NSObjectProtocol?
    private var transport: DownloadTransport
    private var contextWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var contextTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cachedDownloadsRootDirectory: URL
    @ObservationIgnored private var cachedResumeDataDirectory: URL

    var customDownloadsRootDirectory: URL? {
        didSet {
            if let custom = customDownloadsRootDirectory {
                try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
                cachedDownloadsRootDirectory = custom
            } else {
                let defaultDir = Self.makeDefaultDownloadsRootDirectory()
                try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
                cachedDownloadsRootDirectory = defaultDir
            }
        }
    }

    private static func makeDefaultDownloadsRootDirectory() -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func makeDefaultResumeDataDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("DownloadResumeData", isDirectory: true)
    }

    var downloadsRootDirectory: URL {
        cachedDownloadsRootDirectory
    }

    private var resumeDataDirectory: URL {
        cachedResumeDataDirectory
    }

    init(transport: DownloadTransport? = nil) {
        let defaultRoot = Self.makeDefaultDownloadsRootDirectory()
        try? FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        self.cachedDownloadsRootDirectory = defaultRoot

        let defaultResume = Self.makeDefaultResumeDataDirectory()
        try? FileManager.default.createDirectory(at: defaultResume, withIntermediateDirectories: true)
        self.cachedResumeDataDirectory = defaultResume

        let chosenTransport = transport ?? BackgroundDownloadSession.shared
        self.transport = chosenTransport
        chosenTransport.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                defer {
                    (chosenTransport as? BackgroundDownloadSession)?.notifyEventCompleted()
                }
                await self?.handleTransportEvent(event)
            }
        }
        // 7-5：初始化同步全局 NetworkReachabilityMonitor 状态，并监听前台切换与周期轮询，不再重复创建 NWPathMonitor
        self.isOnWiFi = NetworkReachabilityMonitor.shared.isOnWiFi
        foregroundObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncWiFiStateFromSharedMonitor()
            }
        }
        networkSyncTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.syncWiFiStateFromSharedMonitor()
                }
            }
        }
        // 7-5：启动时低优先级预热可用磁盘余量，避免下载管理页首帧 0B 闪烁
        let diskProvider = availableDiskBytesProvider
        Task.detached(priority: .utility) { [weak self] in
            let freeBytes = diskProvider()
            await MainActor.run { [weak self] in
                guard let self, self.cachedAvailableDiskBytes == nil else { return }
                self.cachedAvailableDiskBytes = freeBytes
            }
        }
    }

    deinit {
        networkSyncTask?.cancel()
        if let token = foregroundObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func syncWiFiStateFromSharedMonitor() {
        let latestWiFi = NetworkReachabilityMonitor.shared.isOnWiFi
        if isOnWiFi != latestWiFi {
            isOnWiFi = latestWiFi
        }
    }

    /// 7-5：Wi-Fi 切蜂窝且开启「仅 Wi-Fi 下载」时将活跃任务安全转入 `waitingWiFi`；恢复 Wi-Fi 时自动拉起等待队列
    private func handleNetworkWiFiStateChanged(wasWiFi: Bool, isWiFi: Bool) {
        if !wasWiFi && isWiFi {
            promoteWaitingWiFiItems()
            pumpQueue()
        } else if wasWiFi && !isWiFi && AppSettingsStore.shared.wifiOnlyDownload {
            Task { @MainActor [weak self] in
                await self?.transitionActiveTasksToWaitingWiFi()
            }
        }
    }

    /// 7-5：Wi-Fi 切蜂窝且开启仅 Wi-Fi 时，取消活跃下载并作废旧 resumeData，将 downloading / queued 条目转入 waitingWiFi
    func transitionActiveTasksToWaitingWiFi() async {
        guard AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi else { return }
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.state == "downloading" || $0.state == "queued" }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return }
        for item in items {
            let itemID = item.id
            cancelResolvingTask(for: itemID)
            if item.state == "downloading" {
                transport.cancel(itemID: itemID)
            }
            releaseActiveSlot(itemID: itemID)
            clearProgress(forItemID: itemID)
            clearInProgressMetrics(forItemID: itemID)
            removeResumeData(for: itemID)
            item.state = "waitingWiFi"
            if item.kind == "manual" {
                upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
            }
        }
        try? ctx.save()
        notifySummaryChanged()
    }

    func setTransportForTesting(_ newTransport: DownloadTransport) {
        self.transport = newTransport
        newTransport.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                defer {
                    (newTransport as? BackgroundDownloadSession)?.notifyEventCompleted()
                }
                await self?.handleTransportEvent(event)
            }
        }
    }

    internal func rollbackTierForTesting(itemID: String) -> String? {
        rollbackTierByItemID[itemID]
    }

    internal var rollbackTierCountForTesting: Int {
        rollbackTierByItemID.count
    }

    internal func hasResolvingTaskForTesting(itemID: String) -> Bool {
        resolvingTasksByItemID[itemID] != nil
    }

    internal var resolvingTaskCountForTesting: Int {
        resolvingTasksByItemID.count
    }

    private func cancelResolvingTask(for itemID: String) {
        resolvingTaskTokens.removeValue(forKey: itemID)
        if let task = resolvingTasksByItemID.removeValue(forKey: itemID) {
            task.cancel()
        }
    }

    private func cancelAllResolvingTasks() {
        resolvingTaskTokens.removeAll()
        let tasks = resolvingTasksByItemID
        resolvingTasksByItemID.removeAll()
        for task in tasks.values {
            task.cancel()
        }
    }

    /// M-P0-2：等待 `modelContext` 绑定就绪，内置 5 秒超时保护与安全兜底，防止后台冷启回调永久挂死
    func contextReady(timeoutSeconds: TimeInterval = 5.0) async {
        if modelContext != nil { return }
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if modelContext != nil {
                continuation.resume()
                return
            }
            contextWaiters[waiterID] = continuation
            contextTimeoutTasks[waiterID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled, let self else { return }
                self.contextTimeoutTasks.removeValue(forKey: waiterID)
                if let pending = self.contextWaiters.removeValue(forKey: waiterID) {
                    NSLog("[Downloads] contextReady 等待超时(\(timeoutSeconds)s)，触发安全兜底放行")
                    pending.resume()
                }
            }
        }
    }

    func verifyFileExists(localPath: String) -> Bool {
        if localPath.isEmpty {
            return false
        }
        if localPath.hasPrefix("fixture/") {
            return true
        }
        let url = downloadsRootDirectory.appendingPathComponent(localPath)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 增量内存字典维护（避免每次事件全表 SwiftData fetch + 重复 fileExists）

    private func upsertSnapshot(for item: DownloadItem, isFileVerified: Bool? = nil, recomputeSummary shouldRecompute: Bool = true) {
        guard item.kind == "manual", !hiddenPendingRemovalBookIDs.contains(item.bookID) else {
            return
        }
        let verified = isFileVerified ?? (item.state == "completed" && !item.localPath.isEmpty)
        let snap = DownloadItemSnapshot(
            id: item.id,
            bookID: item.bookID,
            bookTitle: item.bookTitle,
            chapterID: item.chapterID,
            chapterTitle: item.chapterTitle,
            sourceID: item.sourceID,
            kind: item.kind,
            state: item.state,
            localPath: item.localPath,
            bytes: item.bytes,
            retryCount: item.retryCount,
            createdAt: item.createdAt,
            isFileVerified: verified,
            qualityTierSnapshot: item.qualityTierSnapshot,
            qualityIsStale: item.qualityIsStale,
            lastErrorMessage: item.lastErrorMessage
        )
        snapshotsByBookID[item.bookID, default: [:]][item.id] = snap
        if shouldRecompute {
            recomputeSummary(for: item.bookID)
        }
    }

    private func removeSnapshot(bookID: String, itemID: String) {
        guard var bookMap = snapshotsByBookID[bookID] else { return }
        bookMap.removeValue(forKey: itemID)
        if bookMap.isEmpty {
            snapshotsByBookID.removeValue(forKey: bookID)
            summariesByBookID.removeValue(forKey: bookID)
        } else {
            snapshotsByBookID[bookID] = bookMap
            recomputeSummary(for: bookID)
        }
    }

    private func removeBookSnapshots(bookID: String) {
        snapshotsByBookID.removeValue(forKey: bookID)
        summariesByBookID.removeValue(forKey: bookID)
    }

    private func recomputeSummary(for bookID: String) {
        guard !hiddenPendingRemovalBookIDs.contains(bookID),
              let snaps = snapshotsByBookID[bookID],
              !snaps.isEmpty,
              let sample = snaps.values.first else {
            summariesByBookID.removeValue(forKey: bookID)
            return
        }
        var entry = DownloadSummary(
            bookID: bookID,
            bookTitle: sample.bookTitle,
            sourceID: sample.sourceID,
            completedCount: 0,
            totalCount: 0,
            totalBytes: 0,
            failedCount: 0,
            activeCount: 0
        )
        for snap in snaps.values {
            entry.totalCount += 1
            let playable = snap.isFileVerified && (snap.state == "completed" || !snap.localPath.isEmpty)
            // 离线占用（字节）：文件在磁盘上即计入（重下期间不下跌）
            if playable { entry.totalBytes += snap.bytes }
            // 已下载章数：与列表分区口径严格一致，仅计 completed；重下中归属 activeCount
            if snap.state == "completed" && snap.isFileVerified { entry.completedCount += 1 }
            if snap.state == "failed" {
                entry.failedCount += 1
            } else if snap.state == "downloading" || snap.state == "queued" || snap.state == "waitingWiFi" || snap.state == "paused" {
                entry.activeCount += 1
            }
        }
        summariesByBookID[bookID] = entry
    }

    private func notifySummaryChanged() {
        cachedManualDownloadedBytes = summariesByBookID.values.reduce(0) { $0 + $1.totalBytes }
        stateVersion &+= 1
        if self === DownloadManager.shared {
            LibraryStore.shared.recomputeDerived()
        }
    }

    /// 全量重建内存摘要（S4：首帧仅按 DB 字段构建内存快照，避免主线程同步逐条 fileExists，随后触发低优先级异步磁盘对账）
    func rebuildSummariesFromContext(scheduleDiskReconcile: Bool = true) {
        guard let ctx = modelContext else { return }
        let allItems = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        var map: [String: DownloadSummary] = [:]
        var snapMap: [String: [String: DownloadItemSnapshot]] = [:]
        var precacheBytes: Int64 = 0
        var removedStaleCompleted = false
        var liveIDs: Set<String> = []
        var pathsToVerify: [(itemID: String, localPath: String)] = []

        for item in allItems {
            let isCompleted = (item.state == "completed")
            let hasPath = !item.localPath.isEmpty
            if isCompleted && !hasPath {
                ctx.delete(item)
                removedStaleCompleted = true
                continue
            }
            let verified = hasPath
            if hasPath && !item.localPath.hasPrefix("fixture/") {
                pathsToVerify.append((itemID: item.id, localPath: item.localPath))
            }
            liveIDs.insert(item.id)
            if item.kind == "precache" {
                if isCompleted {
                    precacheBytes += item.bytes
                }
                continue
            }
            guard item.kind == "manual", !hiddenPendingRemovalBookIDs.contains(item.bookID) else {
                continue
            }
            let snap = DownloadItemSnapshot(
                id: item.id,
                bookID: item.bookID,
                bookTitle: item.bookTitle,
                chapterID: item.chapterID,
                chapterTitle: item.chapterTitle,
                sourceID: item.sourceID,
                kind: item.kind,
                state: item.state,
                localPath: item.localPath,
                bytes: item.bytes,
                retryCount: item.retryCount,
                createdAt: item.createdAt,
                isFileVerified: verified,
                qualityTierSnapshot: item.qualityTierSnapshot,
                qualityIsStale: item.qualityIsStale,
                lastErrorMessage: item.lastErrorMessage
            )
            snapMap[item.bookID, default: [:]][item.id] = snap

            var entry = map[item.bookID] ?? DownloadSummary(
                bookID: item.bookID,
                bookTitle: item.bookTitle,
                sourceID: item.sourceID,
                completedCount: 0,
                totalCount: 0,
                totalBytes: 0,
                failedCount: 0,
                activeCount: 0
            )
            entry.totalCount += 1
            let playable = verified && (isCompleted || !item.localPath.isEmpty)
            if playable { entry.totalBytes += item.bytes }
            if isCompleted && verified { entry.completedCount += 1 }
            if item.state == "failed" {
                entry.failedCount += 1
            } else if item.state == "downloading" || item.state == "queued" || item.state == "waitingWiFi" || item.state == "paused" {
                entry.activeCount += 1
            }
            map[item.bookID] = entry
        }

        if removedStaleCompleted {
            try? ctx.save()
        }
        summariesByBookID = map
        snapshotsByBookID = snapMap
        cachedPrecacheBytes = precacheBytes
        rollbackTierByItemID = rollbackTierByItemID.filter { liveIDs.contains($0.key) }
        notifySummaryChanged()

        if scheduleDiskReconcile && !pathsToVerify.isEmpty {
            scheduleAsyncDiskReconcile(entries: pathsToVerify)
        }
    }

    private func scheduleAsyncDiskReconcile(entries: [(itemID: String, localPath: String)]) {
        diskReconcileTask?.cancel()
        let rootDir = downloadsRootDirectory
        diskReconcileTask = Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var missingIDs: [String] = []
            for entry in entries {
                if Task.isCancelled { return }
                let fullPath = rootDir.appendingPathComponent(entry.localPath).path
                if !fm.fileExists(atPath: fullPath) {
                    missingIDs.append(entry.itemID)
                }
            }
            guard !missingIDs.isEmpty, !Task.isCancelled else { return }
            let missingSet = Set(missingIDs)
            await MainActor.run { [weak self] in
                guard let self, let ctx = self.modelContext else { return }
                let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "completed" })
                guard let completed = try? ctx.fetch(desc) else { return }
                var changed = false
                for item in completed where missingSet.contains(item.id) {
                    if !self.verifyFileExists(localPath: item.localPath) {
                        self.rollbackTierByItemID.removeValue(forKey: item.id)
                        ctx.delete(item)
                        changed = true
                    }
                }
                if changed {
                    try? ctx.save()
                    self.rebuildSummariesFromContext(scheduleDiskReconcile: false)
                }
            }
        }
    }

    func bookSnapshots(for bookID: String) -> [String: DownloadItemSnapshot] {
        _ = stateVersion
        guard !hiddenPendingRemovalBookIDs.contains(bookID) else { return [:] }
        return snapshotsByBookID[bookID] ?? [:]
    }

    func downloadState(bookID: String, chapterID: String) -> ChapterDownloadState {
        _ = stateVersion
        guard !hiddenPendingRemovalBookIDs.contains(bookID),
              let snap = snapshotsByBookID[bookID]?["\(bookID)::\(chapterID)"] else {
            return .notDownloaded
        }
        switch snap.state {
        case "completed":
            return snap.isFileVerified ? .completed : .notDownloaded
        case "downloading", "queued", "waitingWiFi", "paused":
            let p = itemProgress[snap.id] ?? (snap.state == "downloading" ? 0.2 : 0.08)
            return .downloading(p)
        case "failed":
            return .failed
        default:
            return .notDownloaded
        }
    }

    func isReDownloading(bookID: String, chapterID: String) -> Bool {
        _ = stateVersion
        guard !hiddenPendingRemovalBookIDs.contains(bookID),
              let snap = snapshotsByBookID[bookID]?["\(bookID)::\(chapterID)"] else {
            return false
        }
        let active = ["downloading", "queued", "waitingWiFi", "paused"].contains(snap.state)
        return active && !snap.localPath.isEmpty && verifyFileExists(localPath: snap.localPath)
    }

    func localFileURL(bookID: String, chapterID: String) -> URL? {
        localFileInfo(bookID: bookID, chapterID: chapterID)?.url
    }

    /// 计算指定书籍当前生效的音质档位（P9：优先查 LibraryStore 内存缓存，未命中再回落 SQLite）
    func effectiveQualityTier(forBookID bookID: String) -> AudioQualityTier {
        let overrideRaw: String
        if let cachedBook = LibraryStore.shared.allKnownBooksByID[bookID] {
            overrideRaw = cachedBook.preferredAudioQualityRaw
        } else if let ctx = modelContext {
            let targetID = bookID
            let desc = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == targetID })
            overrideRaw = (try? ctx.fetch(desc).first?.preferredAudioQualityRaw) ?? ""
        } else {
            overrideRaw = ""
        }
        return QualityPolicy.effectiveTier(
            bookOverrideRaw: overrideRaw,
            globalDefault: AppSettingsStore.shared.audioQualityTier
        )
    }

    /// 下载中独立核算码率（R11 ②：仅依据响应头 expectedContentLength 与已知章节时长计算，绝不使用网速）
    func updateInProgressBitrate(
        forItemID itemID: String,
        expectedContentLength: Int64,
        durationSec: Double? = nil
    ) {
        guard expectedContentLength > 0 else { return }
        var dur: Double = 0
        if let d = durationSec, d > 1 {
            dur = d
        } else if let cached = resolvedDurationSecByItemID[itemID], cached > 1 {
            dur = cached
        } else if let ctx = modelContext {
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            if let item = try? ctx.fetch(desc).first {
                if item.expectedDurationSec > 1 {
                    dur = item.expectedDurationSec
                } else if let progressMs = ChapterProgressCache.shared.progress(bookID: item.bookID, chapterID: item.chapterID)?.durationMs,
                          progressMs > 1000 {
                    dur = Double(progressMs) / 1000.0
                }
            }
        }
        guard dur > 1,
              let kbps = AudioQualityTier.computedBitrateKbps(bytes: expectedContentLength, durationSec: dur),
              kbps > 0 else {
            return
        }
        if inProgressBitrateKbpsByItemID[itemID] != kbps {
            inProgressBitrateKbpsByItemID[itemID] = kbps
            DownloadProgressStore.shared.updateBitrate(kbps, for: itemID)
        }
    }

    private func clearProgress(forItemID itemID: String) {
        itemProgress.removeValue(forKey: itemID)
        DownloadProgressStore.shared.removeProgress(for: itemID)
    }

    private func clearInProgressMetrics(forItemID itemID: String) {
        inProgressBitrateKbpsByItemID.removeValue(forKey: itemID)
        DownloadProgressStore.shared.removeBitrate(for: itemID)
        resolvedDurationSecByItemID.removeValue(forKey: itemID)
    }

    /// 对老版本升级上来的已完成本地文件按需异步探测一次真实时长与净码率并回写持久化（R3-5 单并发排队）
    func backfillAudioMetricsIfNeeded(for item: DownloadItem) {
        guard item.state == "completed",
              item.actualBitrateKbps <= 0,
              !item.localPath.isEmpty,
              !backfillingItemIDs.contains(item.id) else {
            return
        }
        let itemID = item.id
        let localPath = item.localPath
        let fileSize = item.bytes
        let expectedDur = item.expectedDurationSec
        if localPath.hasPrefix("fixture/") {
            if expectedDur > 1,
               let computed = AudioQualityTier.computedBitrateKbps(bytes: fileSize, durationSec: expectedDur),
               computed > 0 {
                item.actualDurationSec = expectedDur
                item.actualBitrateKbps = computed
                try? modelContext?.save()
                stateVersion &+= 1
            }
            return
        }
        let fileURL = downloadsRootDirectory.appendingPathComponent(localPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        enqueueAudioMetricsProbe(
            itemID: itemID,
            fileURL: fileURL,
            fileSize: fileSize,
            expectedDurationSec: expectedDur,
            overwriteExisting: false
        )
    }

    /// R3-5：将音频指标探测任务加入单并发低优先级队列，防止并发探测风暴
    private func enqueueAudioMetricsProbe(
        itemID: String,
        fileURL: URL,
        fileSize: Int64,
        expectedDurationSec: Double,
        overwriteExisting: Bool
    ) {
        if overwriteExisting {
            backfillQueue.removeAll { $0.itemID == itemID }
        } else if backfillingItemIDs.contains(itemID) {
            return
        }
        backfillingItemIDs.insert(itemID)
        backfillQueue.append(
            AudioMetricsProbeRequest(
                itemID: itemID,
                fileURL: fileURL,
                fileSize: fileSize,
                expectedDurationSec: expectedDurationSec,
                overwriteExisting: overwriteExisting
            )
        )
        startBackfillWorkerIfNeeded()
    }

    private func startBackfillWorkerIfNeeded() {
        guard backfillWorkerTask == nil else { return }
        backfillWorkerTask = Task(priority: .utility) { @MainActor [weak self] in
            while let self, !self.backfillQueue.isEmpty {
                let req = self.backfillQueue.removeFirst()
                let probed = await DownloadFileProcessor.shared.probeAudioMetrics(
                    at: req.fileURL,
                    fileSize: req.fileSize
                )
                if !self.backfillQueue.contains(where: { $0.itemID == req.itemID }) {
                    self.backfillingItemIDs.remove(req.itemID)
                }

                let effectiveDur = probed.durationSec > 1
                    ? probed.durationSec
                    : (req.expectedDurationSec > 1 ? req.expectedDurationSec : 0)
                let kbps: Int
                if probed.bitrateKbps > 0 {
                    kbps = probed.bitrateKbps
                } else if effectiveDur > 1 {
                    kbps = AudioQualityTier.computedBitrateKbps(bytes: req.fileSize, durationSec: effectiveDur) ?? 0
                } else {
                    kbps = 0
                }
                guard kbps > 0 || effectiveDur > 1 else { continue }

                // M-P0-5：优先交由后台 PersistenceActor 落盘，彻底解除 `if let ctx = modelContext` 永久遮蔽问题
                if let actor = self.persistenceActor {
                    let patch = PersistenceActor.DownloadItemStatePatch(
                        itemID: req.itemID,
                        actualDurationSec: effectiveDur > 1 ? effectiveDur : nil,
                        actualBitrateKbps: kbps > 0 ? kbps : nil,
                        onlyIfActualBitrateUnset: !req.overwriteExisting
                    )
                    let updated = (try? await actor.updateDownloadItems([patch])) ?? 0
                    if updated > 0 {
                        self.stateVersion &+= 1
                    }
                } else if let ctx = self.modelContext {
                    let targetID = req.itemID
                    let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == targetID })
                    guard let freshItem = try? ctx.fetch(desc).first else { continue }
                    guard req.overwriteExisting || freshItem.actualBitrateKbps <= 0 else { continue }
                    if effectiveDur > 1 {
                        freshItem.actualDurationSec = effectiveDur
                    }
                    if kbps > 0 {
                        freshItem.actualBitrateKbps = kbps
                    }
                    try? ctx.save()
                    self.stateVersion &+= 1
                }
            }
            self?.backfillWorkerTask = nil
        }
    }

    func localFileInfo(bookID: String, chapterID: String) -> (url: URL, tierRaw: String, isStale: Bool)? {
        guard let ctx = modelContext else { return nil }
        let itemID = "\(bookID)::\(chapterID)"
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first,
              !item.localPath.isEmpty else {
            return nil
        }
        let url = downloadsRootDirectory.appendingPathComponent(item.localPath)
        let exists = item.localPath.hasPrefix("fixture/") || FileManager.default.fileExists(atPath: url.path)
        if exists {
            let tierRaw = rollbackTierByItemID[itemID] ?? item.qualityTierSnapshot
            let isStale: Bool
            if QualityPolicy.sourceHasMultipleBitrates(sourceID: item.sourceID) {
                let currentTierRaw = effectiveQualityTier(forBookID: bookID).rawValue
                let normalizedTierRaw = AudioQualityTier(rawValue: tierRaw)?.rawValue ?? tierRaw
                isStale = item.qualityIsStale || (!tierRaw.isEmpty && normalizedTierRaw != currentTierRaw)
            } else {
                isStale = false
            }
            return (url: url, tierRaw: tierRaw, isStale: isStale)
        } else {
            guard item.state == "completed" else { return nil }
            let wasPrecache = (item.kind == "precache")
            let removedBytes = item.bytes
            rollbackTierByItemID.removeValue(forKey: itemID)
            clearInProgressMetrics(forItemID: itemID)
            ctx.delete(item)
            try? ctx.save()
            if wasPrecache {
                cachedPrecacheBytes = max(0, cachedPrecacheBytes - removedBytes)
            } else {
                removeSnapshot(bookID: bookID, itemID: itemID)
                notifySummaryChanged()
            }
            return nil
        }
    }

    func staleCompletedCount(forBookID bookID: String? = nil) -> Int {
        _ = stateVersion
        if let bookID {
            guard !hiddenPendingRemovalBookIDs.contains(bookID),
                  let snaps = snapshotsByBookID[bookID] else {
                return 0
            }
            let currentTierRaw = effectiveQualityTier(forBookID: bookID).rawValue
            return snaps.values.reduce(0) { count, snap in
                count + (snap.isFileVerified && snap.isStale(against: currentTierRaw) ? 1 : 0)
            }
        }
        var total = 0
        for (bid, snaps) in snapshotsByBookID where !hiddenPendingRemovalBookIDs.contains(bid) {
            let currentTierRaw = effectiveQualityTier(forBookID: bid).rawValue
            for snap in snaps.values where snap.isFileVerified && snap.isStale(against: currentTierRaw) {
                total += 1
            }
        }
        return total
    }

    func isChapterQualityStale(bookID: String, chapterID: String) -> Bool {
        _ = stateVersion
        guard !hiddenPendingRemovalBookIDs.contains(bookID),
              let snap = snapshotsByBookID[bookID]?["\(bookID)::\(chapterID)"] else {
            return false
        }
        guard QualityPolicy.sourceHasMultipleBitrates(sourceID: snap.sourceID) else {
            return false
        }
        let currentTierRaw = effectiveQualityTier(forBookID: bookID).rawValue
        return snap.isFileVerified && snap.isStale(against: currentTierRaw)
    }

    /// 把"档位过期"的已完成条目重置为待下载（仅对多码率书源生效；保留原 localPath 不清空，失败时可回滚保底）
    @discardableResult
    func refreshStaleQualityItems(bookID: String? = nil, chapterIDs: [String]? = nil) -> Int {
        guard let ctx = modelContext else { return 0 }
        let desc: FetchDescriptor<DownloadItem>
        if let bookID {
            desc = FetchDescriptor<DownloadItem>(
                predicate: #Predicate<DownloadItem> { $0.state == "completed" && $0.bookID == bookID }
            )
        } else {
            desc = FetchDescriptor<DownloadItem>(
                predicate: #Predicate<DownloadItem> { $0.state == "completed" }
            )
        }
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return 0 }

        let chapterFilter = chapterIDs.map(Set.init)
        let initialState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        var refreshed = 0

        for item in items {
            if let chapterFilter, !chapterFilter.contains(item.chapterID) {
                continue
            }
            if item.kind != "manual" {
                continue
            }
            guard QualityPolicy.sourceHasMultipleBitrates(sourceID: item.sourceID) else {
                continue
            }
            let currentTier = effectiveQualityTier(forBookID: item.bookID).rawValue
            let normalizedSnap = AudioQualityTier(rawValue: item.qualityTierSnapshot)?.rawValue ?? item.qualityTierSnapshot
            let isStale = item.qualityIsStale || (!item.qualityTierSnapshot.isEmpty && normalizedSnap != currentTier)
            guard isStale else { continue }
            if !item.localPath.isEmpty {
                rollbackTierByItemID[item.id] = item.qualityTierSnapshot
            }
            item.state = initialState
            item.retryCount = 0
            item.qualityTierSnapshot = currentTier
            item.qualityIsStale = !item.localPath.isEmpty
            removeResumeData(for: item.id)
            upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
            refreshed += 1
        }
        if refreshed > 0 {
            try? ctx.save()
            notifySummaryChanged()
            pumpQueue()
        }
        return refreshed
    }

    @discardableResult
    func enqueueChaptersWithCheck(_ chapters: [ChapterDTO], for book: BookRef, kind: String = "manual") throws -> Int {
        guard let ctx = modelContext else { return 0 }
        let freeBytes = availableDiskBytesProvider()
        cachedAvailableDiskBytes = freeBytes
        if freeBytes < minimumFreeDiskBytes {
            isDiskInsufficient = true
            throw DownloadError.insufficientDisk
        }
        isDiskInsufficient = false

        let initialState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        let supportsMultiBitrate = QualityPolicy.sourceHasMultipleBitrates(sourceID: book.sourceID)
        let tierSnapshot = supportsMultiBitrate ? effectiveQualityTier(forBookID: book.id).rawValue : ""
        // P5：循环前按 bookID 一次性拉取该书全部已有记录建成字典，消除 N+1 SQLite 查询与循环内 O(N²) 摘要重算
        let targetBookID = book.id
        let bookDesc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.bookID == targetBookID })
        let existingItems = (try? ctx.fetch(bookDesc)) ?? []
        var existingByID: [String: DownloadItem] = [:]
        existingByID.reserveCapacity(existingItems.count + chapters.count)
        for item in existingItems {
            existingByID[item.id] = item
        }

        var added = 0
        var anyMutated = false
        for ch in chapters {
            let itemID = "\(book.id)::\(ch.id)"
            let expectedDuration = max(0, ch.hintDurationSec)
            if let existing = existingByID[itemID] {
                var mutated = false
                var snapshotUpdated = false
                var counted = false
                let normalizedExistingSnap = AudioQualityTier(rawValue: existing.qualityTierSnapshot)?.rawValue ?? existing.qualityTierSnapshot
                if expectedDuration > 0 && existing.expectedDurationSec != expectedDuration {
                    existing.expectedDurationSec = expectedDuration
                    mutated = true
                }
                if kind == "manual" && existing.kind == "precache" {
                    if existing.state == "completed" {
                        cachedPrecacheBytes = max(0, cachedPrecacheBytes - existing.bytes)
                        if supportsMultiBitrate && !existing.qualityTierSnapshot.isEmpty && normalizedExistingSnap != tierSnapshot {
                            existing.qualityIsStale = true
                        }
                    }
                    existing.kind = "manual"
                    counted = true
                    mutated = true
                }
                if existing.state == "failed" || existing.state == "paused" {
                    requeue(existing, targetState: initialState, recomputeSummary: false)
                    counted = true
                    mutated = true
                    snapshotUpdated = true
                } else if existing.state == "completed" && !verifyFileExists(localPath: existing.localPath) {
                    existing.localPath = ""
                    existing.bytes = 0
                    rollbackTierByItemID.removeValue(forKey: existing.id)
                    removeResumeData(for: existing.id)
                    requeue(existing, targetState: initialState, recomputeSummary: false)
                    counted = true
                    mutated = true
                    snapshotUpdated = true
                } else if supportsMultiBitrate,
                          existing.state == "completed",
                          verifyFileExists(localPath: existing.localPath),
                          !existing.qualityTierSnapshot.isEmpty,
                          normalizedExistingSnap != tierSnapshot {
                    if !existing.qualityIsStale {
                        existing.qualityIsStale = true
                        mutated = true
                    }
                }
                if counted {
                    added += 1
                }
                if mutated {
                    anyMutated = true
                    if !snapshotUpdated {
                        upsertSnapshot(
                            for: existing,
                            isFileVerified: verifyFileExists(localPath: existing.localPath),
                            recomputeSummary: false
                        )
                    }
                }
                continue
            }
            let record = DownloadItem(
                id: itemID,
                bookID: book.id,
                bookTitle: book.title,
                chapterID: ch.id,
                chapterTitle: ch.title,
                sourceID: book.sourceID,
                kind: kind,
                state: initialState,
                qualityTierSnapshot: tierSnapshot,
                qualityIsStale: false,
                expectedDurationSec: expectedDuration
            )
            ctx.insert(record)
            existingByID[itemID] = record
            upsertSnapshot(for: record, isFileVerified: false, recomputeSummary: false)
            added += 1
            anyMutated = true
        }
        if added > 0 || anyMutated {
            recomputeSummary(for: book.id)
            try? ctx.save()
            notifySummaryChanged()
        }
        pumpQueue()
        return added
    }

    func enqueueChapters(_ chapters: [ChapterDTO], for book: BookRef, kind: String = "manual") {
        _ = try? enqueueChaptersWithCheck(chapters, for: book, kind: kind)
    }

    private func promoteWaitingWiFiItems() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "waitingWiFi" })
        guard let waiting = try? ctx.fetch(desc), !waiting.isEmpty else { return }
        for item in waiting {
            item.state = "queued"
            upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
        }
        try? ctx.save()
        notifySummaryChanged()
    }

    func handleWiFiOnlySettingChanged(_ wifiOnly: Bool) async {
        let cancelledIDs = await transport.cancelTasksDisallowingMismatch(allowsCellular: !wifiOnly)
        for itemID in cancelledIDs {
            // R3-2 / 7-3：网络策略变更后，被取消任务关联的旧 resumeData 内嵌旧 allowsCellularAccess，必须立即作废
            removeResumeData(for: itemID)
        }
        guard let ctx = modelContext else { return }
        for itemID in cancelledIDs {
            cancelResolvingTask(for: itemID)
            releaseActiveSlot(itemID: itemID)
            clearProgress(forItemID: itemID)
            clearInProgressMetrics(forItemID: itemID)
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            if let item = try? ctx.fetch(desc).first {
                item.state = (wifiOnly && !isOnWiFi) ? "waitingWiFi" : "queued"
                if item.kind == "manual" {
                    upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
                }
            }
        }
        // 7-3：仅 Wi-Fi 策略切换后，所有尚未完成条目历史保存的 .resume 文件均内嵌旧 allowsCellularAccess，统一作废以最新策略重建
        let allItems = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        for item in allItems where item.state != "completed" {
            removeResumeData(for: item.id)
        }
        resumeFingerprintByItemID.removeAll()
        storageReconciler.cleanupExpiredResumeFilesAsync(
            in: resumeDataDirectory,
            whitelistItemIDs: [],
            maxAge: 0
        )
        if !wifiOnly || isOnWiFi {
            promoteWaitingWiFiItems()
        } else {
            await transitionActiveTasksToWaitingWiFi()
        }
        try? ctx.save()
        notifySummaryChanged()
        pumpQueue()
    }

    /// 7-3：鉴权/Cookie 刷新后清除相关过期 `resumeData`，取消旧在途任务并用最新 URLRequest 与网络策略重建下载
    func handleAuthOrCookieRefreshed(forSourceID sourceID: String? = nil) async {
        let cancelledIDs: [String]
        if let bgSession = transport as? BackgroundDownloadSession {
            cancelledIDs = await bgSession.cancelTasksMatching { desc in
                guard let sourceID, !sourceID.isEmpty else { return true }
                return desc.bookID.hasPrefix("\(sourceID)::")
            }
        } else {
            cancelledIDs = []
        }

        for itemID in cancelledIDs {
            cancelResolvingTask(for: itemID)
            releaseActiveSlot(itemID: itemID)
            clearProgress(forItemID: itemID)
            clearInProgressMetrics(forItemID: itemID)
            removeResumeData(for: itemID)
        }

        guard let ctx = modelContext else { return }
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        let allItems = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        var mutated = false
        for item in allItems where item.state != "completed" {
            if let sourceID, !sourceID.isEmpty, item.sourceID != sourceID {
                continue
            }
            removeResumeData(for: item.id)
            if item.state == "downloading" || cancelledIDs.contains(item.id) {
                cancelResolvingTask(for: item.id)
                transport.cancel(itemID: item.id)
                releaseActiveSlot(itemID: item.id)
                clearProgress(forItemID: item.id)
                clearInProgressMetrics(forItemID: item.id)
                item.state = targetState
                if item.kind == "manual" {
                    upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
                }
                mutated = true
            }
        }
        if mutated {
            try? ctx.save()
            notifySummaryChanged()
        }
        pumpQueue()
    }

    /// 节流版已完成文件对账入口：距上次对账不足 `minInterval` 秒时直接跳过
    func reconcileCompletedFilesIfNeeded(minInterval: TimeInterval = 60) {
        storageReconciler.reconcileCompletedFilesIfNeeded(
            minInterval: minInterval,
            context: modelContext,
            downloadsRoot: downloadsRootDirectory,
            verifyFileExists: { [weak self] path in self?.verifyFileExists(localPath: path) ?? false },
            onRemoveRecord: { [weak self] itemID in self?.rollbackTierByItemID.removeValue(forKey: itemID) },
            onRebuildSummaries: { [weak self] in self?.rebuildSummariesFromContext(scheduleDiskReconcile: false) }
        )
    }

    func reconcileCompletedFiles() {
        storageReconciler.reconcileCompletedFiles(
            context: modelContext,
            downloadsRoot: downloadsRootDirectory,
            verifyFileExists: { [weak self] path in self?.verifyFileExists(localPath: path) ?? false },
            onRemoveRecord: { [weak self] itemID in self?.rollbackTierByItemID.removeValue(forKey: itemID) },
            onRebuildSummaries: { [weak self] in self?.rebuildSummariesFromContext(scheduleDiskReconcile: false) }
        )
    }

    func recoverInterruptedItems() {
        Task { @MainActor in
            let activeIDs = await transport.activeTaskItemIDs()
            // 后台清理 staging 目录中遗留的孤儿 .tmp 文件
            storageReconciler.cleanupStagingFilesAsync(in: BackgroundDownloadSession.stagingDirectory)
            guard let ctx = modelContext else { return }
            // R3-2：顺带清理过期（> 24h）及孤儿 .resume 文件
            let allItems = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
            let resumeWhitelist = Set(
                allItems
                    .filter { $0.state != "completed" && $0.state != "failed" }
                    .map(\.id)
            )
            storageReconciler.cleanupExpiredResumeFilesAsync(
                in: resumeDataDirectory,
                whitelistItemIDs: resumeWhitelist
            )
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "downloading" })
            if let items = try? ctx.fetch(desc), !items.isEmpty {
                for item in items {
                    let isAlreadyTracked = activeManualIDs.contains(item.id) || activePrecacheIDs.contains(item.id)
                    if activeIDs.contains(item.id) || isAlreadyTracked {
                        markActive(itemID: item.id, isPrecache: item.kind == "precache")
                    } else if item.kind == "precache" {
                        rollbackTierByItemID.removeValue(forKey: item.id)
                        ctx.delete(item)
                    } else {
                        item.state = "queued"
                        upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
                    }
                }
                try? ctx.save()
                notifySummaryChanged()
            }
            pumpQueue()
        }
    }

    func dropQueuedPrecache() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.kind == "precache" && $0.state == "queued" }
        )
        guard let items = try? ctx.fetch(desc), !items.isEmpty else { return }
        for item in items {
            cancelResolvingTask(for: item.id)
            releaseActiveSlot(itemID: item.id)
            rollbackTierByItemID.removeValue(forKey: item.id)
            ctx.delete(item)
        }
        try? ctx.save()
    }

    @discardableResult
    func invalidateLocalFile(bookID: String, chapterID: String) -> Bool {
        guard let ctx = modelContext else { return false }
        let itemID = "\(bookID)::\(chapterID)"
        rollbackTierByItemID.removeValue(forKey: itemID)
        deletingItemIDs.insert(itemID)
        defer {
            deletingItemIDs.remove(itemID)
        }
        cancelResolvingTask(for: itemID)
        transport.cancel(itemID: itemID)
        releaseActiveSlot(itemID: itemID)
        clearProgress(forItemID: itemID)
        clearInProgressMetrics(forItemID: itemID)
        removeResumeData(for: itemID)

        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first else {
            removeSnapshot(bookID: bookID, itemID: itemID)
            notifySummaryChanged()
            return false
        }
        let wasPrecache = (item.kind == "precache")
        let removedBytes = item.bytes
        if !item.localPath.isEmpty {
            try? FileManager.default.removeItem(at: downloadsRootDirectory.appendingPathComponent(item.localPath))
        }
        ctx.delete(item)
        try? ctx.save()
        if wasPrecache {
            cachedPrecacheBytes = max(0, cachedPrecacheBytes - removedBytes)
        } else {
            removeSnapshot(bookID: bookID, itemID: itemID)
            notifySummaryChanged()
        }
        if self === DownloadManager.shared {
            PlayerEngine.shared.handleLocalFileDeleted(bookID: bookID, chapterID: chapterID)
        }
        pumpQueue()
        return true
    }

    @discardableResult
    func retryFailedChapter(bookID: String, chapterID: String) -> Bool {
        guard let ctx = modelContext else { return false }
        let itemID = "\(bookID)::\(chapterID)"
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first else { return false }
        retryFailedItem(item)
        return true
    }

    /// 把条目重置为可下载状态，并按需刷新档位快照与断点数据
    private func requeue(_ item: DownloadItem, targetState: String, refreshTier: Bool = true, recomputeSummary shouldRecompute: Bool = true) {
        let supportsMultiBitrate = QualityPolicy.sourceHasMultipleBitrates(sourceID: item.sourceID)
        let currentTier = supportsMultiBitrate ? effectiveQualityTier(forBookID: item.bookID).rawValue : ""
        let normalizedSnap = AudioQualityTier(rawValue: item.qualityTierSnapshot)?.rawValue ?? item.qualityTierSnapshot
        let tierChanged = supportsMultiBitrate && (normalizedSnap != currentTier)
        let hasExistingFile = !item.localPath.isEmpty && verifyFileExists(localPath: item.localPath)
        item.state = targetState
        item.retryCount = 0
        item.lastErrorMessage = ""
        if refreshTier {
            item.qualityTierSnapshot = currentTier
            item.qualityIsStale = supportsMultiBitrate && hasExistingFile
        }
        if tierChanged {
            removeResumeData(for: item.id)
        }
        upsertSnapshot(for: item, isFileVerified: hasExistingFile, recomputeSummary: shouldRecompute)
    }

    func retryFailedItems(forBookID bookID: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.bookID == bookID && $0.kind == "manual" && $0.state == "failed" }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return }
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        for item in items {
            requeue(item, targetState: targetState)
        }
        try? ctx.save()
        notifySummaryChanged()
        pumpQueue()
    }

    func pauseItem(_ item: DownloadItem) async {
        cancelResolvingTask(for: item.id)
        let data = await transport.pause(itemID: item.id)
        if let data, !data.isEmpty {
            saveResumeData(data, for: item.id)
            if let fp = activeRequestFingerprintByItemID[item.id] {
                resumeFingerprintByItemID[item.id] = fp
            }
        }
        item.state = "paused"
        releaseActiveSlot(itemID: item.id)
        clearInProgressMetrics(forItemID: item.id)
        let fileExists = verifyFileExists(localPath: item.localPath)
        if !item.localPath.isEmpty && !fileExists {
            rollbackTierByItemID.removeValue(forKey: item.id)
        }
        try? modelContext?.save()
        upsertSnapshot(for: item, isFileVerified: fileExists)
        notifySummaryChanged()
        pumpQueue()
    }

    func resumeItem(_ item: DownloadItem) {
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        requeue(item, targetState: targetState)
        try? modelContext?.save()
        notifySummaryChanged()
        pumpQueue()
    }

    /// 7-2：按 bookID 范围暂停该书所有手动下载项（严格过滤 `kind == "manual"`，避免永久暂停预缓存项）
    func pauseItems(forBookID bookID: String) async {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> {
                $0.bookID == bookID && $0.kind == "manual" && ($0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi")
            }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return }
        for item in items {
            cancelResolvingTask(for: item.id)
            if item.state == "downloading" {
                let data = await transport.pause(itemID: item.id)
                if let data, !data.isEmpty {
                    saveResumeData(data, for: item.id)
                    if let fp = activeRequestFingerprintByItemID[item.id] {
                        resumeFingerprintByItemID[item.id] = fp
                    }
                }
            }
            releaseActiveSlot(itemID: item.id)
            clearInProgressMetrics(forItemID: item.id)
            item.state = "paused"
            let fileExists = verifyFileExists(localPath: item.localPath)
            if !item.localPath.isEmpty && !fileExists {
                rollbackTierByItemID.removeValue(forKey: item.id)
            }
            upsertSnapshot(for: item, isFileVerified: fileExists)
        }
        try? ctx.save()
        notifySummaryChanged()
        pumpQueue()
    }

    /// 7-2：按 bookID 范围恢复该书所有已暂停的手动下载项
    func resumePausedItems(forBookID bookID: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.bookID == bookID && $0.kind == "manual" && $0.state == "paused" }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return }
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        for item in items {
            requeue(item, targetState: targetState)
        }
        try? ctx.save()
        notifySummaryChanged()
        pumpQueue()
    }

    /// 7-2：批量暂停全部手动下载任务（严格过滤 `kind == "manual"`，绝不波及或永久暂停 `precache` 预缓存任务）
    func pauseAllActive() async {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> {
                $0.kind == "manual" && ($0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi")
            }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        for item in items {
            cancelResolvingTask(for: item.id)
            if item.state == "downloading" {
                let data = await transport.pause(itemID: item.id)
                if let data, !data.isEmpty {
                    saveResumeData(data, for: item.id)
                    if let fp = activeRequestFingerprintByItemID[item.id] {
                        resumeFingerprintByItemID[item.id] = fp
                    }
                }
            }
            releaseActiveSlot(itemID: item.id)
            clearInProgressMetrics(forItemID: item.id)
            item.state = "paused"
            let fileExists = verifyFileExists(localPath: item.localPath)
            if !item.localPath.isEmpty && !fileExists {
                rollbackTierByItemID.removeValue(forKey: item.id)
            }
            upsertSnapshot(for: item, isFileVerified: fileExists)
        }
        for manualID in activeManualIDs {
            cancelResolvingTask(for: manualID)
        }
        activeManualIDs.removeAll()
        try? ctx.save()
        notifySummaryChanged()
    }

    func resumeAllPaused() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.kind == "manual" && $0.state == "paused" }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        for item in items {
            requeue(item, targetState: targetState)
        }
        try? ctx.save()
        notifySummaryChanged()
        pumpQueue()
    }

    func retryFailedItem(_ item: DownloadItem) {
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        requeue(item, targetState: targetState)
        try? modelContext?.save()
        notifySummaryChanged()
        pumpQueue()
    }

    func retryAllFailed() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.kind == "manual" && $0.state == "failed" }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        for item in items {
            requeue(item, targetState: targetState)
        }
        try? ctx.save()
        notifySummaryChanged()
        pumpQueue()
    }

    func cleanupPrecacheIfNeeded(bookID: String, chapterID: String) {
        guard let ctx = modelContext else { return }
        let itemID = "\(bookID)::\(chapterID)"
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first, item.kind == "precache" else { return }
        cancelResolvingTask(for: itemID)
        releaseActiveSlot(itemID: itemID)
        if item.state == "completed" {
            cachedPrecacheBytes = max(0, cachedPrecacheBytes - item.bytes)
        }
        if !item.localPath.isEmpty {
            let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
            try? FileManager.default.removeItem(at: fileURL)
        }
        rollbackTierByItemID.removeValue(forKey: itemID)
        removeResumeData(for: itemID)
        ctx.delete(item)
        try? ctx.save()
    }

    func clearPrecacheOnly() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.kind == "precache" })
        guard let items = try? ctx.fetch(desc) else { return }
        for item in items {
            cancelResolvingTask(for: item.id)
            transport.cancel(itemID: item.id)
            releaseActiveSlot(itemID: item.id)
            rollbackTierByItemID.removeValue(forKey: item.id)
            if !item.localPath.isEmpty {
                let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
                try? FileManager.default.removeItem(at: fileURL)
            }
            removeResumeData(for: item.id)
            ctx.delete(item)
        }
        cachedPrecacheBytes = 0
        try? ctx.save()
        notifySummaryChanged()
    }

    func clearTemporaryCaches() {
        clearPrecacheOnly()
        cachedTemporaryCacheBytes = 0
        Task {
            await CoverImagePipeline.shared.clearCache()
            await refreshCachedStorageMetrics()
        }
    }

    func refreshCachedStorageMetrics() async {
        let metrics = await storageReconciler.computeStorageMetrics(
            manualBytes: totalManualDownloadedBytes(),
            context: modelContext,
            fallbackPrecacheBytes: cachedPrecacheBytes,
            availableDiskBytesProvider: availableDiskBytesProvider
        )
        cachedManualDownloadedBytes = metrics.manualBytes
        cachedPrecacheBytes = metrics.precacheBytes
        cachedTemporaryCacheBytes = metrics.temporaryCacheBytes
        cachedAvailableDiskBytes = metrics.availableDiskBytes
    }

    @discardableResult
    func removeDownloads(forBookID bookID: String, deferred: Bool, scheduleTimer: Bool = true) -> PendingRemoval {
        if !deferred {
            removeDownloads(forBookID: bookID)
            return PendingRemoval(bookID: bookID, scheduleTimer: false, onCancel: {}, onCommit: {})
        }
        hiddenPendingRemovalBookIDs.insert(bookID)
        rebuildSummariesFromContext()
        return PendingRemoval(
            bookID: bookID,
            delaySeconds: 5.0,
            scheduleTimer: scheduleTimer,
            onCancel: { [weak self] in
                self?.hiddenPendingRemovalBookIDs.remove(bookID)
                self?.rebuildSummariesFromContext()
            },
            onCommit: { [weak self] in
                self?.hiddenPendingRemovalBookIDs.remove(bookID)
                self?.removeDownloads(forBookID: bookID)
            }
        )
    }

    /// 7-2：批量删除单书下载记录时严格过滤 `kind == "manual"`，避免误删后台 `precache` 预缓存
    func removeDownloads(forBookID bookID: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.bookID == bookID && $0.kind == "manual" }
        )
        guard let items = try? ctx.fetch(desc) else { return }
        for item in items {
            cancelResolvingTask(for: item.id)
            transport.cancel(itemID: item.id)
            releaseActiveSlot(itemID: item.id)
            rollbackTierByItemID.removeValue(forKey: item.id)
            clearProgress(forItemID: item.id)
            clearInProgressMetrics(forItemID: item.id)
            removeResumeData(for: item.id)
            if !item.localPath.isEmpty {
                let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
                try? FileManager.default.removeItem(at: fileURL)
            }
            ctx.delete(item)
        }
        try? ctx.save()
        removeBookSnapshots(bookID: bookID)
        notifySummaryChanged()
        if self === DownloadManager.shared, let currentChap = PlayerEngine.shared.currentChapter {
            PlayerEngine.shared.handleLocalFileDeleted(bookID: bookID, chapterID: currentChap.id)
        }
        pumpQueue()
    }

    private func cleanupAndDelete(_ item: DownloadItem, in ctx: ModelContext) {
        let itemID = item.id
        cancelResolvingTask(for: itemID)
        transport.cancel(itemID: itemID)
        releaseActiveSlot(itemID: itemID)
        clearProgress(forItemID: itemID)
        clearInProgressMetrics(forItemID: itemID)
        rollbackTierByItemID.removeValue(forKey: itemID)
        removeResumeData(for: itemID)
        if !item.localPath.isEmpty && !item.localPath.hasPrefix("fixture/") {
            let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
            try? FileManager.default.removeItem(at: fileURL)
        }
        if item.kind == "precache" && item.state == "completed" {
            cachedPrecacheBytes = max(0, cachedPrecacheBytes - item.bytes)
        }
        ctx.delete(item)
    }

    @discardableResult
    func removeDownloadItem(bookID: String, chapterID: String) -> Bool {
        let itemID = "\(bookID)::\(chapterID)"
        cancelResolvingTask(for: itemID)
        guard let ctx = modelContext else { return false }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first else {
            return false
        }
        deletingItemIDs.insert(itemID)
        defer {
            deletingItemIDs.remove(itemID)
        }
        let hadLocalFile = !item.localPath.isEmpty
        cleanupAndDelete(item, in: ctx)
        try? ctx.save()
        if var bookMap = snapshotsByBookID[bookID] {
            bookMap.removeValue(forKey: itemID)
            if bookMap.isEmpty {
                snapshotsByBookID.removeValue(forKey: bookID)
                summariesByBookID.removeValue(forKey: bookID)
            } else {
                snapshotsByBookID[bookID] = bookMap
                recomputeSummary(for: bookID)
            }
        }
        notifySummaryChanged()
        if hadLocalFile && self === DownloadManager.shared {
            PlayerEngine.shared.handleLocalFileDeleted(bookID: bookID, chapterID: chapterID)
        }
        pumpQueue()
        return true
    }

    @discardableResult
    func removeFailedItems(forBookID bookID: String) -> Int {
        guard let ctx = modelContext else { return 0 }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> {
                $0.bookID == bookID && $0.state == "failed" && $0.kind == "manual"
            }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return 0 }
        let removedIDs = items.map(\.id)
        for item in items {
            cleanupAndDelete(item, in: ctx)
        }
        try? ctx.save()
        if var bookMap = snapshotsByBookID[bookID] {
            for itemID in removedIDs {
                bookMap.removeValue(forKey: itemID)
            }
            if bookMap.isEmpty {
                snapshotsByBookID.removeValue(forKey: bookID)
                summariesByBookID.removeValue(forKey: bookID)
            } else {
                snapshotsByBookID[bookID] = bookMap
                recomputeSummary(for: bookID)
            }
        }
        notifySummaryChanged()
        return removedIDs.count
    }

    @discardableResult
    func removeAllFailedItems() -> Int {
        guard let ctx = modelContext else { return 0 }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> {
                $0.state == "failed" && $0.kind == "manual"
            }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return 0 }
        let count = items.count
        for item in items {
            cleanupAndDelete(item, in: ctx)
        }
        try? ctx.save()
        rebuildSummariesFromContext()
        return count
    }

    func totalManualDownloadedBytes() -> Int64 {
        summariesByBookID.values.reduce(0) { $0 + $1.totalBytes }
    }

    func totalPrecacheAndTempBytes() -> Int64 {
        let total = storageReconciler.totalPrecacheBytes(context: modelContext, fallback: cachedPrecacheBytes)
        cachedPrecacheBytes = total
        return total
    }

    private var totalActiveCount: Int {
        activeManualIDs.count + activePrecacheIDs.count
    }

    private func markActive(itemID: String, isPrecache: Bool) {
        if isPrecache {
            activeManualIDs.remove(itemID)
            activePrecacheIDs.insert(itemID)
        } else {
            activePrecacheIDs.remove(itemID)
            activeManualIDs.insert(itemID)
        }
    }

    private func releaseActiveSlot(itemID: String) {
        activeManualIDs.remove(itemID)
        activePrecacheIDs.remove(itemID)
    }

    func pumpQueue() {
        _ = launchQueuedItems()
    }

    /// 启动本轮可调度的排队任务，并返回对应 Task 数组供后台接力等待 `transport.start(...)` 完成
    @discardableResult
    private func launchQueuedItems() -> [Task<Void, Never>] {
        guard let ctx = modelContext else { return [] }
        if AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi {
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "queued" })
            if let queued = try? ctx.fetch(desc), !queued.isEmpty {
                for item in queued {
                    item.state = "waitingWiFi"
                    upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
                }
                try? ctx.save()
                notifySummaryChanged()
            }
            return []
        }

        var launchedTasks: [Task<Void, Never>] = []
        var mutated = false
        let now = Date()
        var earliestDeferredDate: Date?
        while totalActiveCount < maxConcurrent {
            // M1：按 kind 分两次查询，彻底消除前 20 条全为 precache 时手动下载被饿死的问题
            var manualDesc = FetchDescriptor<DownloadItem>(
                predicate: #Predicate<DownloadItem> { $0.state == "queued" && $0.kind != "precache" },
                sortBy: [SortDescriptor(\DownloadItem.createdAt)]
            )
            manualDesc.fetchLimit = 20
            let queuedManual = (try? ctx.fetch(manualDesc)) ?? []
            var next: DownloadItem? = queuedManual.first(where: { item in
                guard !activeManualIDs.contains(item.id) else { return false }
                if let notBefore = retryNotBeforeByItemID[item.id], notBefore > now {
                    if earliestDeferredDate == nil || notBefore < earliestDeferredDate! {
                        earliestDeferredDate = notBefore
                    }
                    return false
                }
                return true
            })

            if next == nil && activePrecacheIDs.count < maxConcurrentPrecache {
                var precacheDesc = FetchDescriptor<DownloadItem>(
                    predicate: #Predicate<DownloadItem> { $0.state == "queued" && $0.kind == "precache" },
                    sortBy: [SortDescriptor(\DownloadItem.createdAt)]
                )
                precacheDesc.fetchLimit = 10
                let queuedPrecache = (try? ctx.fetch(precacheDesc)) ?? []
                next = queuedPrecache.first(where: { item in
                    guard !activePrecacheIDs.contains(item.id) else { return false }
                    if let notBefore = retryNotBeforeByItemID[item.id], notBefore > now {
                        if earliestDeferredDate == nil || notBefore < earliestDeferredDate! {
                            earliestDeferredDate = notBefore
                        }
                        return false
                    }
                    return true
                })
            }

            guard let nextItem = next else { break }
            retryNotBeforeByItemID.removeValue(forKey: nextItem.id)
            nextItem.state = "downloading"
            let isPrecache = nextItem.kind == "precache"
            markActive(itemID: nextItem.id, isPrecache: isPrecache)
            upsertSnapshot(for: nextItem, isFileVerified: verifyFileExists(localPath: nextItem.localPath))
            mutated = true

            let itemID = nextItem.id
            let token = UUID()
            cancelResolvingTask(for: itemID)
            resolvingTaskTokens[itemID] = token
            let task: Task<Void, Never> = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.resolvingTaskTokens[itemID] == token {
                        self.resolvingTaskTokens.removeValue(forKey: itemID)
                        self.resolvingTasksByItemID.removeValue(forKey: itemID)
                    }
                }
                await self.executeDownload(for: nextItem)
            }
            resolvingTasksByItemID[itemID] = task
            launchedTasks.append(task)
        }
        if mutated {
            try? ctx.save()
            notifySummaryChanged()
        }
        if let wakeupAt = earliestDeferredDate, launchedTasks.isEmpty {
            let delay = max(0.05, wakeupAt.timeIntervalSinceNow)
            retryWakeupTask?.cancel()
            retryWakeupTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.pumpQueue()
            }
        }
        return launchedTasks
    }

    private struct UnsupportedStream: Error {}

    var customStreamResolver: ((DownloadItem) async throws -> PlayStreamInfo)?

    private func resolveStream(for item: DownloadItem) async throws -> PlayStreamInfo {
        if let custom = customStreamResolver {
            return try await custom(item)
        }
        let snapshotTier: AudioQualityTier? = QualityPolicy.sourceHasMultipleBitrates(sourceID: item.sourceID)
            ? (AudioQualityTier(rawValue: item.qualityTierSnapshot) ?? effectiveQualityTier(forBookID: item.bookID))
            : nil
        let observedMs = ChapterProgressCache.shared.progress(bookID: item.bookID, chapterID: item.chapterID)?.durationMs ?? 0
        let expectedDuration: Double? = item.expectedDurationSec > 0
            ? item.expectedDurationSec
            : (observedMs > 120_000 ? Double(observedMs) / 1000 : nil)
        return try await PluginRuntime.shared.resolvePlayStream(
            sourceID: item.sourceID,
            episodeURL: item.chapterID,
            forDownload: true,
            tier: snapshotTier,
            expectedDurationSec: expectedDuration
        )
    }

    private static func conciseErrorMessage(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "下载失败，请稍后重试" }
        if cleaned.count <= 64 {
            return cleaned
        }
        return String(cleaned.prefix(63)) + "…"
    }

    /// 最终失败处理：若旧离线文件仍完好存在，则自动回滚为 completed + qualityIsStale，防止用户丢失离线音频
    private func markFinalFailureOrRollback(
        _ item: DownloadItem,
        in ctx: ModelContext?,
        isPrecache: Bool,
        errorMessage: String = ""
    ) {
        if !item.localPath.isEmpty && verifyFileExists(localPath: item.localPath) {
            if let oldTier = rollbackTierByItemID.removeValue(forKey: item.id) {
                item.qualityTierSnapshot = oldTier
            }
            item.state = "completed"
            item.qualityIsStale = QualityPolicy.sourceHasMultipleBitrates(sourceID: item.sourceID)
            item.retryCount = 0
            item.lastErrorMessage = ""
            if isPrecache {
                cachedPrecacheBytes += item.bytes
            } else {
                upsertSnapshot(for: item, isFileVerified: true)
            }
            return
        }
        rollbackTierByItemID.removeValue(forKey: item.id)
        if isPrecache {
            ctx?.delete(item)
            removeSnapshot(bookID: item.bookID, itemID: item.id)
        } else {
            item.state = "failed"
            item.lastErrorMessage = Self.conciseErrorMessage(errorMessage)
            upsertSnapshot(for: item, isFileVerified: false)
        }
    }

    private func executeDownload(for item: DownloadItem) async {
        let itemID = item.id
        let isPrecache = item.kind == "precache"
        do {
            let stream = try await resolveStream(for: item)
            // 解析期间若任务已取消或用户已暂停/删除，则放弃启动（先检查槽位与存活态，避免访问已删除对象）
            guard !Task.isCancelled,
                  (isPrecache ? activePrecacheIDs.contains(itemID) : activeManualIDs.contains(itemID)),
                  !item.isDeleted,
                  item.modelContext != nil,
                  item.state == "downloading" else {
                releaseActiveSlot(itemID: itemID)
                clearInProgressMetrics(forItemID: itemID)
                return
            }
            try performDownload(for: item, stream: stream)
        } catch is CancellationError {
            releaseActiveSlot(itemID: itemID)
            clearInProgressMetrics(forItemID: itemID)
            return
        } catch is UnsupportedStream {
            let stillActive = isPrecache ? activePrecacheIDs.contains(itemID) : activeManualIDs.contains(itemID)
            releaseActiveSlot(itemID: itemID)
            clearInProgressMetrics(forItemID: itemID)
            guard stillActive, !item.isDeleted, item.modelContext != nil else {
                pumpQueue()
                return
            }
            markFinalFailureOrRollback(
                item,
                in: modelContext,
                isPrecache: isPrecache,
                errorMessage: DownloadError.unsupportedStream.errorDescription ?? "该章节暂不支持离线下载"
            )
            try? modelContext?.save()
            notifySummaryChanged()
            pumpQueue()
        } catch {
            let stillActive = isPrecache ? activePrecacheIDs.contains(itemID) : activeManualIDs.contains(itemID)
            releaseActiveSlot(itemID: itemID)
            clearInProgressMetrics(forItemID: itemID)
            guard !Task.isCancelled, stillActive, !item.isDeleted, item.modelContext != nil, item.state != "paused" else {
                pumpQueue()
                return
            }
            if item.retryCount < 2 {
                item.retryCount += 1
                item.state = "queued"
                if !isPrecache {
                    upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
                }
            } else {
                markFinalFailureOrRollback(
                    item,
                    in: modelContext,
                    isPrecache: isPrecache,
                    errorMessage: error.localizedDescription
                )
            }
            try? modelContext?.save()
            notifySummaryChanged()
            pumpQueue()
        }
    }

    private func performDownload(for item: DownloadItem, stream: PlayStreamInfo) throws {
        guard let url = JsHostBridge.makeRequestURL(from: stream.url, relativeTo: item.chapterID) else {
            throw PluginError.parseFailed("无效音频地址")
        }
        let lowerURL = url.absoluteString.lowercased()
        if stream.kind != .onDemand || lowerURL.contains(".m3u8") {
            throw UnsupportedStream()
        }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.allowsCellularAccess = !AppSettingsStore.shared.wifiOnlyDownload
        var hasUA = false, hasCookie = false
        for (k, v) in stream.headers {
            let lk = k.lowercased()
            if lk == "x-media-type" { continue }
            if lk == "user-agent" { hasUA = true }
            if lk == "cookie" { hasCookie = true }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !hasUA { req.setValue(JsHostBridge.mobileUA, forHTTPHeaderField: "User-Agent") }
        if !hasCookie {
            let cookie = CookieSync.cookieHeader(for: url)
            if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        }

        if let streamDur = stream.durationSec, streamDur > 1 {
            resolvedDurationSecByItemID[item.id] = streamDur
            if item.expectedDurationSec <= 0 {
                item.expectedDurationSec = streamDur
            }
        }
        if let expectedLen = stream.fileSize, expectedLen > 0 {
            updateInProgressBitrate(
                forItemID: item.id,
                expectedContentLength: expectedLen,
                durationSec: stream.durationSec
            )
        }

        let descriptor = DownloadTaskDescriptor(
            itemID: item.id,
            bookID: item.bookID,
            chapterID: item.chapterID,
            resolvedBy: stream.resolvedBy
        )
        let requestFingerprint = Self.makeRequestFingerprint(for: req)
        activeRequestFingerprintByItemID[item.id] = requestFingerprint

        let supportsMultiBitrate = QualityPolicy.sourceHasMultipleBitrates(sourceID: item.sourceID)
        let currentTierRaw = supportsMultiBitrate ? effectiveQualityTier(forBookID: item.bookID).rawValue : ""
        let normalizedSnap = AudioQualityTier(rawValue: item.qualityTierSnapshot)?.rawValue ?? item.qualityTierSnapshot
        let tierChanged = supportsMultiBitrate && (normalizedSnap != currentTierRaw)
        let savedFingerprint = resumeFingerprintByItemID[item.id]
        // 7-3：鉴权/Cookie 刷新、主机变更或仅 Wi-Fi 策略切换时，废弃过期 resumeData 并用最新 URLRequest 重建任务
        let policyOrAuthChanged = (savedFingerprint != nil && savedFingerprint != requestFingerprint)
        let shouldDiscardResume = tierChanged || policyOrAuthChanged
        let resumeData: Data?
        if shouldDiscardResume {
            removeResumeData(for: item.id)
            resumeData = nil
        } else {
            resumeData = loadResumeData(for: item.id)
            removeResumeData(for: item.id)
        }
        transport.start(request: req, descriptor: descriptor, resumeData: resumeData)
    }

    private static func makeRequestFingerprint(for request: URLRequest) -> ResumeRequestFingerprint {
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let authMaterial = "\(cookie)|\(auth)"
        let digest = SHA256.hash(data: Data(authMaterial.utf8)).map { String(format: "%02x", $0) }.joined()
        return ResumeRequestFingerprint(
            allowsCellular: request.allowsCellularAccess,
            authDigest: digest,
            urlHost: request.url?.host?.lowercased() ?? ""
        )
    }

    /// M3：后台冷启若 modelContext 极端超时未就绪，将已下完的音频转存至持久 staging 目录避免丢弃重下
    private func preserveTempFileToPersistentStaging(
        tempFileURL: URL,
        itemID: String,
        suggestedFilename: String?
    ) {
        let fm = FileManager.default
        let stagingDir = Self.downloadsRootURL.appendingPathComponent(".pending_staging", isDirectory: true)
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = (suggestedFilename as NSString?)?.pathExtension
        let safeExt = (ext?.isEmpty == false) ? ext! : "audio"
        let dest = stagingDir.appendingPathComponent("\(JsHostBridge.md5Hex(itemID)).\(safeExt)")
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: tempFileURL, to: dest)
        } catch {
            try? fm.removeItem(at: tempFileURL)
        }
    }

    private func handleTransportEvent(_ event: DownloadTransportEvent) async {
        switch event {
        case .progress(let itemID, let fraction):
            itemProgress[itemID] = fraction
            DownloadProgressStore.shared.updateProgress(fraction, for: itemID)

        case .finished(let descriptor, let tempFileURL, let statusCode, let mimeType, let originalURL, let suggestedFilename, let expectedContentLength):
            await contextReady()
            guard let ctx = modelContext else {
                NSLog("[Downloads] modelContext 未就绪且等待超时，转存临时文件至持久 staging 目录: \(descriptor.itemID)")
                releaseActiveSlot(itemID: descriptor.itemID)
                clearProgress(forItemID: descriptor.itemID)
                clearInProgressMetrics(forItemID: descriptor.itemID)
                preserveTempFileToPersistentStaging(
                    tempFileURL: tempFileURL,
                    itemID: descriptor.itemID,
                    suggestedFilename: suggestedFilename
                )
                return
            }
            let itemID = descriptor.itemID
            releaseActiveSlot(itemID: itemID)
            clearProgress(forItemID: itemID)
            clearInProgressMetrics(forItemID: itemID)

            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            guard let item = try? ctx.fetch(desc).first else {
                try? FileManager.default.removeItem(at: tempFileURL)
                relayNextInBackground()
                return
            }
            let isPrecache = item.kind == "precache"

            if !(200..<300).contains(statusCode) {
                try? FileManager.default.removeItem(at: tempFileURL)
                await handleTaskFailure(
                    item: item,
                    descriptor: descriptor,
                    statusCode: statusCode,
                    errorDescription: "服务器返回 HTTP \(statusCode)"
                )
                return
            }

            let rootDir = downloadsRootDirectory
            let outcome = await DownloadFileProcessor.shared.validateAndMove(
                tempFileURL: tempFileURL,
                bookID: item.bookID,
                chapterID: item.chapterID,
                downloadsRoot: rootDir,
                mimeType: mimeType,
                originalURL: originalURL,
                suggestedFilename: suggestedFilename,
                expectedContentLength: expectedContentLength
            )

            switch outcome {
            case .success(let relPath, let fileSize):
                guard !item.isDeleted, item.modelContext != nil else {
                    if !relPath.isEmpty && !relPath.hasPrefix("fixture/") {
                        try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(relPath))
                    }
                    relayNextInBackground()
                    return
                }
                let chain: QualityChain = (descriptor.resolvedBy == BuiltinParserRuntime.resolverTag) ? .builtinParser : .bookSource
                let tier = AudioQualityTier(rawValue: item.qualityTierSnapshot) ?? effectiveQualityTier(forBookID: item.bookID)
                item.qualityCodeSnapshot = QualityPolicy.code(for: tier, chain: chain, isOnWiFi: isOnWiFi)
                let expectedDurSnapshot = item.expectedDurationSec
                if relPath.hasPrefix("fixture/") {
                    if expectedDurSnapshot > 1 {
                        item.actualDurationSec = expectedDurSnapshot
                        item.actualBitrateKbps = AudioQualityTier.computedBitrateKbps(bytes: fileSize, durationSec: expectedDurSnapshot) ?? 0
                    } else {
                        item.actualDurationSec = 0
                        item.actualBitrateKbps = 0
                    }
                }
                let oldLocalPath = item.localPath
                if !oldLocalPath.isEmpty && oldLocalPath != relPath && !oldLocalPath.hasPrefix("fixture/") {
                    let oldFileURL = rootDir.appendingPathComponent(oldLocalPath)
                    let oldPrevURL = oldFileURL.appendingPathExtension("prev")
                    Task.detached(priority: .utility) {
                        let fm = FileManager.default
                        if fm.fileExists(atPath: oldFileURL.path) {
                            try? fm.removeItem(at: oldPrevURL)
                            if (try? fm.moveItem(at: oldFileURL, to: oldPrevURL)) != nil {
                                // 先改名让位并刷新 mtime，由孤儿清理在保护期后统一回收，避免打断正在播放的旧句柄
                                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: oldPrevURL.path)
                            } else {
                                try? fm.removeItem(at: oldFileURL)
                            }
                        }
                    }
                }
                rollbackTierByItemID.removeValue(forKey: itemID)
                item.localPath = relPath
                item.bytes = fileSize
                item.state = "completed"
                item.qualityIsStale = false
                item.lastErrorMessage = ""
                removeResumeData(for: itemID)
                if isPrecache {
                    cachedPrecacheBytes += fileSize
                } else {
                    upsertSnapshot(for: item, isFileVerified: true)
                }
                try? ctx.save()
                // 保留 .prev 600s 保护窗口由 cleanupOrphanFiles 统一回收（与跨扩展名让位策略一致）
                notifySummaryChanged()
                relayNextInBackground()
                // R3-5：校验移盘落盘并触发接力后，再低优异步探测真实时长与净码率回写
                if !relPath.hasPrefix("fixture/") {
                    let destURL = rootDir.appendingPathComponent(relPath)
                    enqueueAudioMetricsProbe(
                        itemID: itemID,
                        fileURL: destURL,
                        fileSize: fileSize,
                        expectedDurationSec: expectedDurSnapshot,
                        overwriteExisting: true
                    )
                }

            case .invalidPayload:
                guard !item.isDeleted, item.modelContext != nil else {
                    relayNextInBackground()
                    return
                }
                markFinalFailureOrRollback(
                    item,
                    in: ctx,
                    isPrecache: isPrecache,
                    errorMessage: "下载内容校验失败（非有效音频）"
                )
                try? ctx.save()
                notifySummaryChanged()
                relayNextInBackground()

            case .incompleteLength:
                await handleTaskFailure(
                    item: item,
                    descriptor: descriptor,
                    statusCode: nil,
                    errorDescription: "音频文件下载不完整"
                )

            case .moveFailed:
                await handleTaskFailure(
                    item: item,
                    descriptor: descriptor,
                    statusCode: nil,
                    errorDescription: "本地保存音频文件失败"
                )
            }

        case .failed(let descriptor, let statusCode, let errorDescription):
            await contextReady()
            guard let ctx = modelContext else {
                NSLog("[Downloads] modelContext 未就绪且等待超时，安全释放失败任务槽位: \(descriptor.itemID)")
                releaseActiveSlot(itemID: descriptor.itemID)
                clearProgress(forItemID: descriptor.itemID)
                clearInProgressMetrics(forItemID: descriptor.itemID)
                return
            }
            let itemID = descriptor.itemID
            releaseActiveSlot(itemID: itemID)
            clearProgress(forItemID: itemID)
            clearInProgressMetrics(forItemID: itemID)
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            guard let item = try? ctx.fetch(desc).first else {
                relayNextInBackground()
                return
            }
            let reason: String
            if !errorDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = errorDescription
            } else if let code = statusCode {
                reason = "网络请求失败（HTTP \(code)）"
            } else {
                reason = "网络下载失败，请稍后重试"
            }
            await handleTaskFailure(
                item: item,
                descriptor: descriptor,
                statusCode: statusCode,
                errorDescription: reason
            )
        }
    }

    private func handleTaskFailure(
        item: DownloadItem,
        descriptor: DownloadTaskDescriptor,
        statusCode: Int?,
        errorDescription: String = ""
    ) async {
        guard let ctx = modelContext, !item.isDeleted, item.modelContext != nil, item.state != "paused" else {
            relayNextInBackground()
            return
        }
        let isPrecache = item.kind == "precache"
        if let code = statusCode, [401, 403, 410].contains(code) {
            // 7-3：鉴权或直链签名失效时立即作废旧 resumeData，确保重试使用最新 URLRequest
            removeResumeData(for: item.id)
            if descriptor.resolvedBy == BuiltinParserRuntime.resolverTag {
                await BuiltinParserRuntime.shared.invalidateCache(parserID: nil, episodeURL: item.chapterID)
            }
        }
        guard !item.isDeleted, item.modelContext != nil, item.state != "paused" else {
            relayNextInBackground()
            return
        }
        if item.retryCount < 2 {
            item.retryCount += 1
            item.state = "queued"
            // M2：指数退避（第 1 次 2s，第 2 次 6s；429/503 限流场景加倍）
            let baseDelay: TimeInterval = (item.retryCount == 1) ? 2.0 : 6.0
            let multiplier: TimeInterval = (statusCode == 429 || statusCode == 503) ? 2.0 : 1.0
            let backoff = baseDelay * multiplier * retryBackoffScale
            if backoff > 0 {
                retryNotBeforeByItemID[item.id] = Date().addingTimeInterval(backoff)
            }
            if !isPrecache {
                upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
            }
        } else {
            markFinalFailureOrRollback(
                item,
                in: ctx,
                isPrecache: isPrecache,
                errorMessage: errorDescription
            )
        }
        try? ctx.save()
        notifySummaryChanged()
        relayNextInBackground()
    }

    private func endRelayBackgroundTask(_ taskID: UIBackgroundTaskIdentifier) {
        guard taskID != .invalid else { return }
        guard activeRelayBackgroundTasks.remove(taskID) != nil else { return }
        UIApplication.shared.endBackgroundTask(taskID)
    }

    private func relayNextInBackground() {
        var batchTaskID: UIBackgroundTaskIdentifier = .invalid
        batchTaskID = UIApplication.shared.beginBackgroundTask(withName: "DSNovelDownloadRelay") { [weak self] in
            let expiredID = batchTaskID
            Task { @MainActor [weak self] in
                self?.endRelayBackgroundTask(expiredID)
            }
        }
        let taskID = batchTaskID
        if taskID != .invalid {
            activeRelayBackgroundTasks.insert(taskID)
        }

        let launchedTasks = launchQueuedItems()
        if launchedTasks.isEmpty {
            endRelayBackgroundTask(taskID)
            return
        }
        // S8：按批次局部持有 bgTask 句柄，仅在本批 executeDownload 完成后结束本批句柄，避免并发接力互杀
        Task { @MainActor [weak self] in
            for task in launchedTasks {
                await task.value
            }
            self?.endRelayBackgroundTask(taskID)
        }
    }

    // MARK: - ResumeData 持久化

    /// R3-2：续传直链 TTL（10 分钟），超时自动作废避免过期 CDN 签名导致反复失败
    static let resumeDataTTLSeconds: TimeInterval = 600

    private func resumeDataURL(for itemID: String) -> URL {
        let key = JsHostBridge.md5Hex(itemID)
        return resumeDataDirectory.appendingPathComponent("\(key).resume")
    }

    internal func resumeDataURLForTesting(for itemID: String) -> URL {
        resumeDataURL(for: itemID)
    }

    func saveResumeData(_ data: Data, for itemID: String) {
        try? data.write(to: resumeDataURL(for: itemID), options: .atomic)
    }

    func loadResumeData(for itemID: String) -> Data? {
        let url = resumeDataURL(for: itemID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        if let modDate, Date().timeIntervalSince(modDate) > Self.resumeDataTTLSeconds {
            try? fm.removeItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }

    func removeResumeData(for itemID: String) {
        resumeFingerprintByItemID.removeValue(forKey: itemID)
        try? FileManager.default.removeItem(at: resumeDataURL(for: itemID))
    }
}
