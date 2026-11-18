import Foundation
import Observation
import Network
import SwiftData
import UIKit

struct DownloadSummary: Equatable, Hashable, Sendable {
    var bookID: String
    var bookTitle: String
    var sourceID: String
    var completedCount: Int
    var totalCount: Int
    var totalBytes: Int64
    var failedCount: Int
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

/// 下载与预缓存调度器（T3-04 增量汇总 / waitingWiFi / 磁盘预检 / 延迟删除 + T3-06 后台下载会话）
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

    private(set) var summariesByBookID: [String: DownloadSummary] = [:]
    private(set) var itemProgress: [String: Double] = [:]
    private(set) var hiddenPendingRemovalBookIDs: Set<String> = []
    private(set) var isDiskInsufficient: Bool = false

    private let maxConcurrent = 3
    private var activeTasksCount = 0
    private let maxConcurrentPrecache = 1
    private var activePrecacheCount = 0
    var isOnWiFi = true
    var minimumFreeDiskBytes: Int64 = 50 * 1024 * 1024 // 50 MB
    var availableDiskBytesProvider: () -> Int64 = {
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

    func contextReady() async {
        if modelContext != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            contextWaiters.append(continuation)
        }
    }

    func rebuildSummariesFromContext() {
        guard let ctx = modelContext else { return }
        let allItems = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        var map: [String: DownloadSummary] = [:]
        for item in allItems where item.kind == "manual" && !hiddenPendingRemovalBookIDs.contains(item.bookID) {
            var entry = map[item.bookID] ?? DownloadSummary(
                bookID: item.bookID,
                bookTitle: item.bookTitle,
                sourceID: item.sourceID,
                completedCount: 0,
                totalCount: 0,
                totalBytes: 0,
                failedCount: 0
            )
            entry.totalCount += 1
            if item.state == "completed" {
                entry.completedCount += 1
                entry.totalBytes += item.bytes
            } else if item.state == "failed" {
                entry.failedCount += 1
            }
            map[item.bookID] = entry
        }
        summariesByBookID = map
    }

    func localFileURL(bookID: String, chapterID: String) -> URL? {
        guard let ctx = modelContext else { return nil }
        let itemID = "\(bookID)::\(chapterID)"
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first,
              item.state == "completed",
              !item.localPath.isEmpty else {
            return nil
        }
        let url = downloadsRootDirectory.appendingPathComponent(item.localPath)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        } else {
            ctx.delete(item)
            try? ctx.save()
            rebuildSummariesFromContext()
            return nil
        }
    }

    @discardableResult
    func enqueueChaptersWithCheck(_ chapters: [ChapterDTO], for book: BookRef, kind: String = "manual") throws -> Int {
        guard let ctx = modelContext else { return 0 }
        let freeBytes = availableDiskBytesProvider()
        if freeBytes < minimumFreeDiskBytes {
            isDiskInsufficient = true
            throw DownloadError.insufficientDisk
        }
        isDiskInsufficient = false

        let initialState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        var added = 0
        for ch in chapters {
            let itemID = "\(book.id)::\(ch.id)"
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            if let existing = try? ctx.fetch(desc).first {
                if kind == "manual" && existing.kind == "precache" {
                    existing.kind = "manual"
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
                state: initialState
            )
            ctx.insert(record)
            added += 1
        }
        try? ctx.save()
        rebuildSummariesFromContext()
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
        }
        try? ctx.save()
    }

    func handleWiFiOnlySettingChanged(_ wifiOnly: Bool) async {
        let cancelledIDs = await transport.cancelTasksDisallowingMismatch(allowsCellular: !wifiOnly)
        guard let ctx = modelContext else { return }
        for itemID in cancelledIDs {
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            if let item = try? ctx.fetch(desc).first {
                item.state = (wifiOnly && !isOnWiFi) ? "waitingWiFi" : "queued"
            }
        }
        if !wifiOnly || isOnWiFi {
            promoteWaitingWiFiItems()
        }
        try? ctx.save()
        rebuildSummariesFromContext()
        pumpQueue()
    }

    func reconcileCompletedFiles() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "completed" })
        guard let items = try? ctx.fetch(desc), !items.isEmpty else { return }
        var changed = false
        for item in items where !item.localPath.isEmpty {
            let url = downloadsRootDirectory.appendingPathComponent(item.localPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                ctx.delete(item)
                changed = true
            }
        }
        if changed {
            try? ctx.save()
            rebuildSummariesFromContext()
        }
    }

    /// T3-06 重启对账：与后台 URLSession 中仍在运行的任务比对，无任务者回退为 queued
    func recoverInterruptedItems() {
        Task { @MainActor in
            let activeIDs = await transport.activeTaskItemIDs()
            guard let ctx = modelContext else { return }
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "downloading" })
            if let items = try? ctx.fetch(desc), !items.isEmpty {
                for item in items where !activeIDs.contains(item.id) {
                    if item.kind == "precache" {
                        ctx.delete(item)
                    } else {
                        item.state = "queued"
                    }
                }
                try? ctx.save()
            }
            rebuildSummariesFromContext()
            pumpQueue()
        }
    }

    func dropQueuedPrecache() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.kind == "precache" && $0.state == "queued" }
        )
        guard let items = try? ctx.fetch(desc), !items.isEmpty else { return }
        for item in items { ctx.delete(item) }
        try? ctx.save()
    }

    func invalidateLocalFile(bookID: String, chapterID: String) {
        guard let ctx = modelContext else { return }
        let itemID = "\(bookID)::\(chapterID)"
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first else { return }
        if !item.localPath.isEmpty {
            try? FileManager.default.removeItem(at: downloadsRootDirectory.appendingPathComponent(item.localPath))
        }
        removeResumeData(for: itemID)
        ctx.delete(item)
        try? ctx.save()
        rebuildSummariesFromContext()
    }

    func pauseItem(_ item: DownloadItem) async {
        let data = await transport.pause(itemID: item.id)
        if let data, !data.isEmpty {
            saveResumeData(data, for: item.id)
        }
        item.state = "paused"
        activeTasksCount = max(0, activeTasksCount - 1)
        try? modelContext?.save()
        rebuildSummariesFromContext()
    }

    func resumeItem(_ item: DownloadItem) {
        item.state = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        try? modelContext?.save()
        rebuildSummariesFromContext()
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
            item.state = "paused"
        }
        activeTasksCount = 0
        activePrecacheCount = 0
        try? ctx.save()
        rebuildSummariesFromContext()
    }

    func resumeAllPaused() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "paused" })
        let items = (try? ctx.fetch(desc)) ?? []
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        for item in items {
            item.state = targetState
        }
        try? ctx.save()
        rebuildSummariesFromContext()
        pumpQueue()
    }

    func retryFailedItem(_ item: DownloadItem) {
        item.state = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        item.retryCount = 0
        try? modelContext?.save()
        rebuildSummariesFromContext()
        pumpQueue()
    }

    func retryAllFailed() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "failed" })
        let items = (try? ctx.fetch(desc)) ?? []
        let targetState = (AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi) ? "waitingWiFi" : "queued"
        for item in items {
            item.state = targetState
            item.retryCount = 0
        }
        try? ctx.save()
        rebuildSummariesFromContext()
        pumpQueue()
    }

    func cleanupPrecacheIfNeeded(bookID: String, chapterID: String) {
        guard let ctx = modelContext else { return }
        let itemID = "\(bookID)::\(chapterID)"
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first, item.kind == "precache" else { return }
        if !item.localPath.isEmpty {
            let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
            try? FileManager.default.removeItem(at: fileURL)
        }
        removeResumeData(for: itemID)
        ctx.delete(item)
        try? ctx.save()
    }

    func clearPrecacheOnly() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.kind == "precache" })
        guard let items = try? ctx.fetch(desc) else { return }
        for item in items {
            if !item.localPath.isEmpty {
                let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
                try? FileManager.default.removeItem(at: fileURL)
            }
            removeResumeData(for: item.id)
            ctx.delete(item)
        }
        try? ctx.save()
        rebuildSummariesFromContext()
    }

    func clearTemporaryCaches() {
        clearPrecacheOnly()
        Task {
            await CoverImagePipeline.shared.clearCache()
        }
    }

    /// T3-04 延迟删除（5 秒后真正删文件与记录，可取消）
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
            removeResumeData(for: item.id)
            if !item.localPath.isEmpty {
                let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
                try? FileManager.default.removeItem(at: fileURL)
            }
            ctx.delete(item)
        }
        try? ctx.save()
        rebuildSummariesFromContext()
    }

    func totalManualDownloadedBytes() -> Int64 {
        summariesByBookID.values.reduce(0) { $0 + $1.totalBytes }
    }

    func totalPrecacheAndTempBytes() -> Int64 {
        guard let ctx = modelContext else { return 0 }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.kind == "precache" && $0.state == "completed" })
        let items = (try? ctx.fetch(desc)) ?? []
        return items.reduce(0) { $0 + $1.bytes }
    }

    func pumpQueue() {
        guard let ctx = modelContext else { return }
        if AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi {
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "queued" })
            if let queued = try? ctx.fetch(desc), !queued.isEmpty {
                for item in queued { item.state = "waitingWiFi" }
                try? ctx.save()
                rebuildSummariesFromContext()
            }
            return
        }
        while activeTasksCount < maxConcurrent {
            var desc = FetchDescriptor<DownloadItem>(
                predicate: #Predicate<DownloadItem> { $0.state == "queued" },
                sortBy: [SortDescriptor(\DownloadItem.createdAt)]
            )
            desc.fetchLimit = 20
            guard let queued = try? ctx.fetch(desc), !queued.isEmpty else { break }
            let next = queued.first(where: { $0.kind != "precache" })
                ?? queued.first(where: { _ in activePrecacheCount < maxConcurrentPrecache })
            guard let nextItem = next else { break }
            nextItem.state = "downloading"
            try? ctx.save()
            rebuildSummariesFromContext()
            activeTasksCount += 1
            let isPrecache = nextItem.kind == "precache"
            if isPrecache { activePrecacheCount += 1 }

            Task {
                await executeDownload(for: nextItem)
            }
        }
    }

    private struct UnsupportedStream: Error {}

    var customStreamResolver: ((DownloadItem) async throws -> PlayStreamInfo)?

    private func resolveStream(for item: DownloadItem) async throws -> PlayStreamInfo {
        if let custom = customStreamResolver {
            return try await custom(item)
        }
        return try await PluginRuntime.shared.resolvePlayStream(
            sourceID: item.sourceID,
            episodeURL: item.chapterID,
            forDownload: true
        )
    }

    private func executeDownload(for item: DownloadItem) async {
        let isPrecache = item.kind == "precache"
        do {
            let stream = try await resolveStream(for: item)
            try performDownload(for: item, stream: stream)
        } catch is UnsupportedStream {
            finishActiveSlot(isPrecache: isPrecache)
            if isPrecache {
                modelContext?.delete(item)
            } else {
                item.state = "failed"
            }
            try? modelContext?.save()
            rebuildSummariesFromContext()
            pumpQueue()
        } catch {
            finishActiveSlot(isPrecache: isPrecache)
            if item.retryCount < 2 {
                item.retryCount += 1
                item.state = "queued"
            } else if isPrecache {
                modelContext?.delete(item)
            } else {
                item.state = "failed"
            }
            try? modelContext?.save()
            rebuildSummariesFromContext()
            pumpQueue()
        }
    }

    /// T3-06 提交通道：构造请求并通过 `transport.start` 提交后台会话（不再使用 URLSession.shared.download）
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
        let resumeData = loadResumeData(for: item.id)
        removeResumeData(for: item.id)
        transport.start(request: req, descriptor: descriptor, resumeData: resumeData)
    }

    private func handleTransportEvent(_ event: DownloadTransportEvent) async {
        switch event {
        case .progress(let itemID, let fraction):
            itemProgress[itemID] = fraction

        case .finished(let descriptor, let tempFileURL, let statusCode, let mimeType):
            await contextReady()
            guard let ctx = modelContext else { return }
            let itemID = descriptor.itemID
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            guard let item = try? ctx.fetch(desc).first else {
                try? FileManager.default.removeItem(at: tempFileURL)
                return
            }
            let isPrecache = item.kind == "precache"
            finishActiveSlot(isPrecache: isPrecache)
            itemProgress.removeValue(forKey: itemID)

            if !(200..<300).contains(statusCode) {
                try? FileManager.default.removeItem(at: tempFileURL)
                await handleTaskFailure(item: item, descriptor: descriptor, statusCode: statusCode)
                return
            }

            let mime = mimeType?.lowercased() ?? ""
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempFileURL.path)[.size] as? Int64) ?? 0
            if mime.hasPrefix("text/") || mime.contains("mpegurl") || mime.contains("json") || mime.contains("html") || fileSize < 1024 {
                try? FileManager.default.removeItem(at: tempFileURL)
                if isPrecache {
                    ctx.delete(item)
                } else {
                    item.state = "failed"
                }
                try? ctx.save()
                rebuildSummariesFromContext()
                relayNextInBackground()
                return
            }

            let ext = Self.inferAudioExtension(url: tempFileURL, mimeType: mimeType)
            let safeBookDir = JsHostBridge.md5Hex(item.bookID)
            let safeChapFile = "\(JsHostBridge.md5Hex(item.chapterID)).\(ext)"
            let relPath = "\(safeBookDir)/\(safeChapFile)"
            let destDir = downloadsRootDirectory.appendingPathComponent(safeBookDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destFile = downloadsRootDirectory.appendingPathComponent(relPath)
            try? FileManager.default.removeItem(at: destFile)
            do {
                try FileManager.default.moveItem(at: tempFileURL, to: destFile)
                item.localPath = relPath
                item.bytes = fileSize
                item.state = "completed"
                removeResumeData(for: itemID)
                try? ctx.save()
                rebuildSummariesFromContext()
            } catch {
                try? FileManager.default.removeItem(at: tempFileURL)
                await handleTaskFailure(item: item, descriptor: descriptor, statusCode: nil)
                return
            }
            relayNextInBackground()

        case .failed(let descriptor, let statusCode, _):
            await contextReady()
            guard let ctx = modelContext else { return }
            let itemID = descriptor.itemID
            let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
            guard let item = try? ctx.fetch(desc).first else { return }
            finishActiveSlot(isPrecache: item.kind == "precache")
            itemProgress.removeValue(forKey: itemID)
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
        } else if isPrecache {
            ctx.delete(item)
        } else {
            item.state = "failed"
        }
        try? ctx.save()
        rebuildSummariesFromContext()
        relayNextInBackground()
    }

    private func finishActiveSlot(isPrecache: Bool) {
        activeTasksCount = max(0, activeTasksCount - 1)
        if isPrecache {
            activePrecacheCount = max(0, activePrecacheCount - 1)
        }
    }

    private func relayNextInBackground() {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "DSNovelDownloadRelay") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        pumpQueue()
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
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

    private static func inferAudioExtension(url: URL, mimeType: String?) -> String {
        let pathExt = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "flac", "ogg", "mp4"].contains(pathExt) {
            return pathExt
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
