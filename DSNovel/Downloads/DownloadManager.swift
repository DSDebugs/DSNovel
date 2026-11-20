import Foundation
import Observation
import Network
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

    func isStale(against currentTierRaw: String) -> Bool {
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
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        for url in urls where url.pathExtension.lowercased() == "tmp" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    func cleanupOrphanFiles(root: URL, whitelistKeys: Set<String>, minAgeSeconds: TimeInterval = 600) -> Int {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-minAgeSeconds)
        var removed = 0
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        for dir in dirs {
            let dirName = dir.lastPathComponent
            // 注：staging 目录位于 tmp/DSNovelDownloadStaging，不在下载根目录下，无需在此过滤
            if dirName == "fixture" { continue }
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else {
                continue
            }
            for file in files {
                let ext = file.pathExtension.lowercased()
                if ext == "tmp" || ext == "download" { continue }
                let key = "\(dirName)/\(file.deletingPathExtension().lastPathComponent)"
                if whitelistKeys.contains(key) { continue }
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if mod > cutoff { continue }
                if (try? fm.removeItem(at: file)) != nil {
                    removed += 1
                }
            }
        }
        return removed
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
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
    }

    private(set) var stateVersion: Int = 0
    /// 缓存的存储占用与磁盘余量统计（避免在 SwiftUI body 中直接执行 SwiftData fetch 或同步文件系统查询）
    private(set) var cachedManualDownloadedBytes: Int64 = 0
    private(set) var cachedTemporaryCacheBytes: Int64? = nil
    private(set) var cachedPrecacheBytes: Int64 = 0
    private(set) var cachedAvailableDiskBytes: Int64? = nil
    private(set) var summariesByBookID: [String: DownloadSummary] = [:]
    private(set) var snapshotsByBookID: [String: [String: DownloadItemSnapshot]] = [:]
    private(set) var itemProgress: [String: Double] = [:]
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
    /// 孤儿文件对账节流时间戳（避免多页面 onAppear 频繁触发全目录扫描）
    @ObservationIgnored private var lastOrphanSweepAt: Date?
    @ObservationIgnored private var relayBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    var isOnWiFi = true
    var minimumFreeDiskBytes: Int64 = 50 * 1024 * 1024 // 50 MB
    var availableDiskBytesProvider: @Sendable () -> Int64 = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? (10 * 1024 * 1024 * 1024)
    }

    private let pathMonitor = NWPathMonitor()
    private var transport: DownloadTransport
    private var contextWaiters: [CheckedContinuation<Void, Never>] = []
    var customDownloadsRootDirectory: URL?

    var downloadsRootDirectory: URL {
        if let custom = customDownloadsRootDirectory {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var resumeDataDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("DownloadResumeData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(transport: DownloadTransport? = nil) {
        let chosenTransport = transport ?? BackgroundDownloadSession.shared
        self.transport = chosenTransport
        chosenTransport.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleTransportEvent(event)
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasWiFi = self.isOnWiFi
                self.isOnWiFi = wifi
                if !wasWiFi && wifi {
                    self.promoteWaitingWiFiItems()
                    self.pumpQueue()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.dsnovel.netmonitor"))
    }

    func setTransportForTesting(_ newTransport: DownloadTransport) {
        self.transport = newTransport
        newTransport.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
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

    func contextReady() async {
        if modelContext != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            contextWaiters.append(continuation)
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

    private func upsertSnapshot(for item: DownloadItem, isFileVerified: Bool? = nil) {
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
            qualityIsStale: item.qualityIsStale
        )
        snapshotsByBookID[item.bookID, default: [:]][item.id] = snap
        recomputeSummary(for: item.bookID)
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

    /// 全量重建内存摘要（仅用于冷启动挂载 modelContext、磁盘对账及延迟删除切换）
    func rebuildSummariesFromContext() {
        guard let ctx = modelContext else { return }
        let allItems = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        var map: [String: DownloadSummary] = [:]
        var snapMap: [String: [String: DownloadItemSnapshot]] = [:]
        var precacheBytes: Int64 = 0
        var removedStaleCompleted = false
        var liveIDs: Set<String> = []

        for item in allItems {
            let isCompleted = (item.state == "completed")
            let verified = !item.localPath.isEmpty && verifyFileExists(localPath: item.localPath)
            if isCompleted && !verified {
                ctx.delete(item)
                removedStaleCompleted = true
                continue
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
                qualityIsStale: item.qualityIsStale
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
            let currentTierRaw = AppSettingsStore.shared.audioQualityTier.normalizedForSelection.rawValue
            let tierRaw = rollbackTierByItemID[itemID] ?? item.qualityTierSnapshot
            let isStale = item.qualityIsStale || (!tierRaw.isEmpty && tierRaw != currentTierRaw)
            return (url: url, tierRaw: tierRaw, isStale: isStale)
        } else {
            guard item.state == "completed" else { return nil }
            let wasPrecache = (item.kind == "precache")
            let removedBytes = item.bytes
            rollbackTierByItemID.removeValue(forKey: itemID)
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
        let currentTierRaw = AppSettingsStore.shared.audioQualityTier.normalizedForSelection.rawValue
        if let bookID {
            guard !hiddenPendingRemovalBookIDs.contains(bookID),
                  let snaps = snapshotsByBookID[bookID] else {
                return 0
            }
            return snaps.values.reduce(0) { count, snap in
                count + (snap.isFileVerified && snap.isStale(against: currentTierRaw) ? 1 : 0)
            }
        }
        var total = 0
        for (bid, snaps) in snapshotsByBookID where !hiddenPendingRemovalBookIDs.contains(bid) {
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
        let currentTierRaw = AppSettingsStore.shared.audioQualityTier.normalizedForSelection.rawValue
        return snap.isFileVerified && snap.isStale(against: currentTierRaw)
    }

    /// 把"档位过期"的已完成条目重置为待下载（保留原 localPath 不清空，失败时可回滚保底）
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
        let currentTier = AppSettingsStore.shared.audioQualityTier.normalizedForSelection.rawValue
        let initialState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        var refreshed = 0

        for item in items {
            if let chapterFilter, !chapterFilter.contains(item.chapterID) {
                continue
            }
            if item.kind != "manual" {
                continue
            }
            let isStale = item.qualityIsStale || (!item.qualityTierSnapshot.isEmpty && item.qualityTierSnapshot != currentTier)
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
        let tierSnapshot = AppSettingsStore.shared.audioQualityTier.normalizedForSelection.rawValue
        var added = 0
        var anyMutated = false
        for ch in chapters {
            let itemID = "\(book.id)::\(ch.id)"
            let expectedDuration = max(0, ch.hintDurationSec)
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            if let existing = try? ctx.fetch(desc).first {
                var mutated = false
                var snapshotUpdated = false
                var counted = false
                if expectedDuration > 0 && existing.expectedDurationSec != expectedDuration {
                    existing.expectedDurationSec = expectedDuration
                    mutated = true
                }
                if kind == "manual" && existing.kind == "precache" {
                    if existing.state == "completed" {
                        cachedPrecacheBytes = max(0, cachedPrecacheBytes - existing.bytes)
                        if !existing.qualityTierSnapshot.isEmpty && existing.qualityTierSnapshot != tierSnapshot {
                            existing.qualityIsStale = true
                        }
                    }
                    existing.kind = "manual"
                    counted = true
                    mutated = true
                }
                if existing.state == "failed" || existing.state == "paused" {
                    requeue(existing, targetState: initialState)
                    counted = true
                    mutated = true
                    snapshotUpdated = true
                } else if existing.state == "completed" && !verifyFileExists(localPath: existing.localPath) {
                    existing.localPath = ""
                    existing.bytes = 0
                    rollbackTierByItemID.removeValue(forKey: existing.id)
                    removeResumeData(for: existing.id)
                    requeue(existing, targetState: initialState)
                    counted = true
                    mutated = true
                    snapshotUpdated = true
                } else if existing.state == "completed",
                          verifyFileExists(localPath: existing.localPath),
                          !existing.qualityTierSnapshot.isEmpty,
                          existing.qualityTierSnapshot != tierSnapshot {
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
                        upsertSnapshot(for: existing, isFileVerified: verifyFileExists(localPath: existing.localPath))
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
            upsertSnapshot(for: record, isFileVerified: false)
            added += 1
            anyMutated = true
        }
        try? ctx.save()
        if added > 0 || anyMutated {
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
        guard let ctx = modelContext else { return }
        for itemID in cancelledIDs {
            releaseActiveSlot(itemID: itemID)
            itemProgress.removeValue(forKey: itemID)
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            if let item = try? ctx.fetch(desc).first {
                item.state = (wifiOnly && !isOnWiFi) ? "waitingWiFi" : "queued"
                upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
            }
        }
        if !wifiOnly || isOnWiFi {
            promoteWaitingWiFiItems()
        }
        try? ctx.save()
        notifySummaryChanged()
        pumpQueue()
    }

    func reconcileCompletedFiles() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "completed" })
        if let items = try? ctx.fetch(desc), !items.isEmpty {
            var changed = false
            for item in items {
                if item.localPath.isEmpty || !verifyFileExists(localPath: item.localPath) {
                    rollbackTierByItemID.removeValue(forKey: item.id)
                    ctx.delete(item)
                    changed = true
                }
            }
            if changed {
                try? ctx.save()
            }
        }
        rebuildSummariesFromContext()
        sweepOrphanFiles()
    }

    private func sweepOrphanFiles() {
        guard let ctx = modelContext else { return }
        let now = Date()
        if let last = lastOrphanSweepAt, now.timeIntervalSince(last) <= 300 {
            return
        }
        lastOrphanSweepAt = now
        let items = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        var keys: Set<String> = []
        for item in items {
            if item.localPath.hasPrefix("fixture/") { continue }
            keys.insert("\(JsHostBridge.md5Hex(item.bookID))/\(JsHostBridge.md5Hex(item.chapterID))")
            if !item.localPath.isEmpty {
                let url = URL(fileURLWithPath: item.localPath)
                let dirName = url.deletingLastPathComponent().lastPathComponent
                let stem = url.deletingPathExtension().lastPathComponent
                if !dirName.isEmpty && dirName != "/" && dirName != "." && !stem.isEmpty {
                    keys.insert("\(dirName)/\(stem)")
                }
            }
        }
        let rootDir = downloadsRootDirectory
        Task.detached(priority: .utility) {
            let n = await DownloadFileProcessor.shared.cleanupOrphanFiles(root: rootDir, whitelistKeys: keys)
            if n > 0 {
                NSLog("[Downloads] 清理孤儿文件 \(n) 个")
            }
        }
    }

    func recoverInterruptedItems() {
        Task { @MainActor in
            let activeIDs = await transport.activeTaskItemIDs()
            // 后台清理 staging 目录中遗留的孤儿 .tmp 文件
            Task.detached(priority: .utility) {
                await DownloadFileProcessor.shared.cleanupOrphanedStagingFiles(
                    in: BackgroundDownloadSession.stagingDirectory
                )
            }
            guard let ctx = modelContext else { return }
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
        transport.cancel(itemID: itemID)
        releaseActiveSlot(itemID: itemID)
        itemProgress.removeValue(forKey: itemID)
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
    private func requeue(_ item: DownloadItem, targetState: String, refreshTier: Bool = true) {
        let currentTier = AppSettingsStore.shared.audioQualityTier.normalizedForSelection.rawValue
        let tierChanged = (item.qualityTierSnapshot != currentTier)
        let hasExistingFile = !item.localPath.isEmpty && verifyFileExists(localPath: item.localPath)
        item.state = targetState
        item.retryCount = 0
        if refreshTier {
            item.qualityTierSnapshot = currentTier
            item.qualityIsStale = hasExistingFile
        }
        if tierChanged {
            removeResumeData(for: item.id)
        }
        upsertSnapshot(for: item, isFileVerified: hasExistingFile)
    }

    func retryFailedItems(forBookID bookID: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.bookID == bookID && $0.state == "failed" }
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
        let data = await transport.pause(itemID: item.id)
        if let data, !data.isEmpty {
            saveResumeData(data, for: item.id)
        }
        item.state = "paused"
        releaseActiveSlot(itemID: item.id)
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

    /// 按 bookID 范围暂停该书所有进行中/排队中的下载项
    func pauseItems(forBookID bookID: String) async {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> {
                $0.bookID == bookID && ($0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi")
            }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        guard !items.isEmpty else { return }
        for item in items {
            if item.state == "downloading" {
                let data = await transport.pause(itemID: item.id)
                if let data, !data.isEmpty {
                    saveResumeData(data, for: item.id)
                }
            }
            releaseActiveSlot(itemID: item.id)
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

    /// 按 bookID 范围恢复该书所有已暂停的下载项
    func resumePausedItems(forBookID bookID: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.bookID == bookID && $0.state == "paused" }
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

    func pauseAllActive() async {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi" }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        for item in items {
            if item.state == "downloading" {
                let data = await transport.pause(itemID: item.id)
                if let data, !data.isEmpty {
                    saveResumeData(data, for: item.id)
                }
            }
            releaseActiveSlot(itemID: item.id)
            item.state = "paused"
            let fileExists = verifyFileExists(localPath: item.localPath)
            if !item.localPath.isEmpty && !fileExists {
                rollbackTierByItemID.removeValue(forKey: item.id)
            }
            upsertSnapshot(for: item, isFileVerified: fileExists)
        }
        activeManualIDs.removeAll()
        activePrecacheIDs.removeAll()
        try? ctx.save()
        notifySummaryChanged()
    }

    func resumeAllPaused() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "paused" })
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
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "failed" })
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
        let manual = totalManualDownloadedBytes()
        let precache = totalPrecacheAndTempBytes()
        let coverBytes = await CoverImagePipeline.shared.diskUsageBytes()
        let provider = availableDiskBytesProvider
        let freeBytes = await Task.detached(priority: .utility) {
            provider()
        }.value
        cachedManualDownloadedBytes = manual
        cachedPrecacheBytes = precache
        cachedTemporaryCacheBytes = precache + coverBytes
        cachedAvailableDiskBytes = freeBytes
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

    func removeDownloads(forBookID bookID: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.bookID == bookID })
        guard let items = try? ctx.fetch(desc) else { return }
        for item in items {
            transport.cancel(itemID: item.id)
            releaseActiveSlot(itemID: item.id)
            rollbackTierByItemID.removeValue(forKey: item.id)
            itemProgress.removeValue(forKey: item.id)
            removeResumeData(for: item.id)
            if item.kind == "precache" && item.state == "completed" {
                cachedPrecacheBytes = max(0, cachedPrecacheBytes - item.bytes)
            }
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

    func totalManualDownloadedBytes() -> Int64 {
        summariesByBookID.values.reduce(0) { $0 + $1.totalBytes }
    }

    func totalPrecacheAndTempBytes() -> Int64 {
        guard let ctx = modelContext else { return cachedPrecacheBytes }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.kind == "precache" && $0.state == "completed" })
        let items = (try? ctx.fetch(desc)) ?? []
        let total = items.reduce(0) { $0 + $1.bytes }
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
        while totalActiveCount < maxConcurrent {
            var desc = FetchDescriptor<DownloadItem>(
                predicate: #Predicate<DownloadItem> { $0.state == "queued" },
                sortBy: [SortDescriptor(\DownloadItem.createdAt)]
            )
            desc.fetchLimit = 20
            guard let queued = try? ctx.fetch(desc), !queued.isEmpty else { break }
            let next = queued.first(where: { $0.kind != "precache" && !activeManualIDs.contains($0.id) })
                ?? queued.first(where: { $0.kind == "precache" && activePrecacheIDs.count < maxConcurrentPrecache && !activePrecacheIDs.contains($0.id) })
            guard let nextItem = next else { break }
            nextItem.state = "downloading"
            let isPrecache = nextItem.kind == "precache"
            markActive(itemID: nextItem.id, isPrecache: isPrecache)
            upsertSnapshot(for: nextItem, isFileVerified: verifyFileExists(localPath: nextItem.localPath))
            mutated = true

            let task: Task<Void, Never> = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.executeDownload(for: nextItem)
            }
            launchedTasks.append(task)
        }
        if mutated {
            try? ctx.save()
            notifySummaryChanged()
        }
        return launchedTasks
    }

    private struct UnsupportedStream: Error {}

    var customStreamResolver: ((DownloadItem) async throws -> PlayStreamInfo)?

    private func resolveStream(for item: DownloadItem) async throws -> PlayStreamInfo {
        if let custom = customStreamResolver {
            return try await custom(item)
        }
        let snapshotTier = AudioQualityTier(rawValue: item.qualityTierSnapshot)?.normalizedForSelection
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

    /// 最终失败处理：若旧离线文件仍完好存在，则自动回滚为 completed + qualityIsStale，防止用户丢失离线音频
    private func markFinalFailureOrRollback(_ item: DownloadItem, in ctx: ModelContext?, isPrecache: Bool) {
        if !item.localPath.isEmpty && verifyFileExists(localPath: item.localPath) {
            if let oldTier = rollbackTierByItemID.removeValue(forKey: item.id) {
                item.qualityTierSnapshot = oldTier
            }
            item.state = "completed"
            item.qualityIsStale = true
            item.retryCount = 0
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
            upsertSnapshot(for: item, isFileVerified: false)
        }
    }

    private func executeDownload(for item: DownloadItem) async {
        let itemID = item.id
        let isPrecache = item.kind == "precache"
        do {
            let stream = try await resolveStream(for: item)
            // 解析期间若用户已暂停/取消/删除，则放弃启动
            guard item.state == "downloading",
                  (isPrecache ? activePrecacheIDs.contains(itemID) : activeManualIDs.contains(itemID)) else {
                releaseActiveSlot(itemID: itemID)
                return
            }
            try performDownload(for: item, stream: stream)
        } catch is UnsupportedStream {
            releaseActiveSlot(itemID: itemID)
            markFinalFailureOrRollback(item, in: modelContext, isPrecache: isPrecache)
            try? modelContext?.save()
            notifySummaryChanged()
            pumpQueue()
        } catch {
            releaseActiveSlot(itemID: itemID)
            if item.retryCount < 2 {
                item.retryCount += 1
                item.state = "queued"
                if !isPrecache {
                    upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
                }
            } else {
                markFinalFailureOrRollback(item, in: modelContext, isPrecache: isPrecache)
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

        let descriptor = DownloadTaskDescriptor(
            itemID: item.id,
            bookID: item.bookID,
            chapterID: item.chapterID,
            resolvedBy: stream.resolvedBy
        )
        let currentTierRaw = AppSettingsStore.shared.audioQualityTier.normalizedForSelection.rawValue
        let shouldDiscardResume = item.qualityTierSnapshot != currentTierRaw
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

    private func handleTransportEvent(_ event: DownloadTransportEvent) async {
        switch event {
        case .progress(let itemID, let fraction):
            itemProgress[itemID] = fraction
            stateVersion &+= 1

        case .finished(let descriptor, let tempFileURL, let statusCode, let mimeType, let originalURL, let suggestedFilename, let expectedContentLength):
            await contextReady()
            guard let ctx = modelContext else {
                try? FileManager.default.removeItem(at: tempFileURL)
                return
            }
            let itemID = descriptor.itemID
            releaseActiveSlot(itemID: itemID)
            itemProgress.removeValue(forKey: itemID)

            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            guard let item = try? ctx.fetch(desc).first else {
                try? FileManager.default.removeItem(at: tempFileURL)
                relayNextInBackground()
                return
            }
            let isPrecache = item.kind == "precache"

            if !(200..<300).contains(statusCode) {
                try? FileManager.default.removeItem(at: tempFileURL)
                await handleTaskFailure(item: item, descriptor: descriptor, statusCode: statusCode)
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
                let chain: QualityChain = (descriptor.resolvedBy == BuiltinParserRuntime.resolverTag) ? .builtinParser : .bookSource
                let tier = AudioQualityTier(rawValue: item.qualityTierSnapshot)?.normalizedForSelection ?? .auto
                item.qualityCodeSnapshot = QualityPolicy.code(for: tier, chain: chain, isOnWiFi: isOnWiFi)
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
                removeResumeData(for: itemID)
                if isPrecache {
                    cachedPrecacheBytes += fileSize
                } else {
                    upsertSnapshot(for: item, isFileVerified: true)
                }
                try? ctx.save()
                let prevURL = rootDir.appendingPathComponent(relPath).appendingPathExtension("prev")
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: prevURL)
                }
                notifySummaryChanged()
                relayNextInBackground()

            case .invalidPayload:
                markFinalFailureOrRollback(item, in: ctx, isPrecache: isPrecache)
                try? ctx.save()
                notifySummaryChanged()
                relayNextInBackground()

            case .incompleteLength, .moveFailed:
                await handleTaskFailure(item: item, descriptor: descriptor, statusCode: nil)
            }

        case .failed(let descriptor, let statusCode, _):
            await contextReady()
            guard let ctx = modelContext else { return }
            let itemID = descriptor.itemID
            releaseActiveSlot(itemID: itemID)
            itemProgress.removeValue(forKey: itemID)
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            guard let item = try? ctx.fetch(desc).first else {
                relayNextInBackground()
                return
            }
            await handleTaskFailure(item: item, descriptor: descriptor, statusCode: statusCode)
        }
    }

    private func handleTaskFailure(item: DownloadItem, descriptor: DownloadTaskDescriptor, statusCode: Int?) async {
        guard let ctx = modelContext else { return }
        let isPrecache = item.kind == "precache"
        if let code = statusCode, [401, 403, 410].contains(code),
           descriptor.resolvedBy == BuiltinParserRuntime.resolverTag {
            await BuiltinParserRuntime.shared.invalidateCache(parserID: nil, episodeURL: item.chapterID)
        }
        if item.retryCount < 2 {
            item.retryCount += 1
            item.state = "queued"
            if !isPrecache {
                upsertSnapshot(for: item, isFileVerified: verifyFileExists(localPath: item.localPath))
            }
        } else {
            markFinalFailureOrRollback(item, in: ctx, isPrecache: isPrecache)
        }
        try? ctx.save()
        notifySummaryChanged()
        relayNextInBackground()
    }

    private func endRelayBackgroundTask() {
        if relayBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(relayBackgroundTask)
            relayBackgroundTask = .invalid
        }
    }

    private func relayNextInBackground() {
        endRelayBackgroundTask()
        relayBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DSNovelDownloadRelay") { [weak self] in
            Task { @MainActor in
                self?.endRelayBackgroundTask()
            }
        }
        let launchedTasks = launchQueuedItems()
        if launchedTasks.isEmpty {
            endRelayBackgroundTask()
            return
        }
        // 延后结束 bgTask，等待本轮 executeDownload 完成解析并调用 transport.start(...)
        Task { @MainActor [weak self] in
            for task in launchedTasks {
                await task.value
            }
            self?.endRelayBackgroundTask()
        }
    }

    // MARK: - ResumeData 持久化

    private func resumeDataURL(for itemID: String) -> URL {
        let key = JsHostBridge.md5Hex(itemID)
        return resumeDataDirectory.appendingPathComponent("\(key).resume")
    }

    func saveResumeData(_ data: Data, for itemID: String) {
        try? data.write(to: resumeDataURL(for: itemID), options: .atomic)
    }

    func loadResumeData(for itemID: String) -> Data? {
        try? Data(contentsOf: resumeDataURL(for: itemID))
    }

    func removeResumeData(for itemID: String) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: itemID))
    }
}
