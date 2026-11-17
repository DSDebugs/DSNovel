import Foundation
import Network
import SwiftData

/// 下载与预缓存调度器（4.4 节）：支持后台 URLSession、并发上限 3、仅 Wi-Fi 检查、区间批量入队与失败自动重试 2 次
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    var modelContext: ModelContext?
    private let maxConcurrent = 3
    private var activeTasksCount = 0
    /// 预缓存同一时刻只允许 1 个任务：避免与「当前章节在线播放」争抢带宽、JS 上下文和 WebView 嗅探通道
    private let maxConcurrentPrecache = 1
    private var activePrecacheCount = 0
    private var isOnWiFi = true
    private let pathMonitor = NWPathMonitor()

    var downloadsRootDirectory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                self?.isOnWiFi = wifi
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.dsnovel.netmonitor"))
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
            // 文件缺失自动修正记录并回退在线播放（4.4 节）
            ctx.delete(item)
            try? ctx.save()
            return nil
        }
    }

    func enqueueChapters(_ chapters: [ChapterDTO], for book: BookRef, kind: String = "manual") {
        guard let ctx = modelContext else { return }
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
                state: "queued"
            )
            ctx.insert(record)
        }
        try? ctx.save()
        pumpQueue()
    }

    /// 无损校验已完成离线文件是否在磁盘存在（不干扰正在进行的下载任务）
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
        }
    }

    /// 应用启动时修复上次被强杀/崩溃遗留的「downloading」僵尸记录（否则永远显示「正在缓存」且不会再被调度）
    func recoverInterruptedItems() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "downloading" })
        guard let items = try? ctx.fetch(desc), !items.isEmpty else { return }
        for item in items {
            if item.kind == "precache" {
                ctx.delete(item)
            } else {
                item.state = "queued"
            }
        }
        try? ctx.save()
        pumpQueue()
    }

    /// 切章时丢弃尚未开始的旧预缓存任务，避免历史章节的预缓存堆积并持续占用通道
    func dropQueuedPrecache() {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.kind == "precache" && $0.state == "queued" }
        )
        guard let items = try? ctx.fetch(desc), !items.isEmpty else { return }
        for item in items { ctx.delete(item) }
        try? ctx.save()
    }

    /// 本地文件损坏（无法解码）时删除记录与文件，播放引擎随后回退在线流
    func invalidateLocalFile(bookID: String, chapterID: String) {
        guard let ctx = modelContext else { return }
        let itemID = "\(bookID)::\(chapterID)"
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        guard let item = try? ctx.fetch(desc).first else { return }
        if !item.localPath.isEmpty {
            try? FileManager.default.removeItem(at: downloadsRootDirectory.appendingPathComponent(item.localPath))
        }
        ctx.delete(item)
        try? ctx.save()
    }

    func retryFailedItem(_ item: DownloadItem) {
        item.state = "queued"
        item.retryCount = 0
        try? modelContext?.save()
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
            ctx.delete(item)
        }
        try? ctx.save()
    }

    /// 清理所有预缓存音频与封面图片缓存（保留手动离线下载的章节）
    func clearTemporaryCaches() {
        clearPrecacheOnly()
        Task {
            await CoverImagePipeline.shared.clearCache()
        }
    }

    func removeDownloads(forBookID bookID: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.bookID == bookID })
        guard let items = try? ctx.fetch(desc) else { return }
        for item in items {
            if !item.localPath.isEmpty {
                let fileURL = downloadsRootDirectory.appendingPathComponent(item.localPath)
                try? FileManager.default.removeItem(at: fileURL)
            }
            ctx.delete(item)
        }
        try? ctx.save()
    }

    func totalManualDownloadedBytes() -> Int64 {
        guard let ctx = modelContext else { return 0 }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.kind == "manual" && $0.state == "completed" })
        let items = (try? ctx.fetch(desc)) ?? []
        return items.reduce(0) { $0 + $1.bytes }
    }

    /// 计算预缓存音频与封面缓存总字节数（供设置页「清理临时缓存」展示）
    func totalPrecacheAndTempBytes() -> Int64 {
        guard let ctx = modelContext else { return 0 }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.kind == "precache" && $0.state == "completed" })
        let items = (try? ctx.fetch(desc)) ?? []
        return items.reduce(0) { $0 + $1.bytes }
    }

    private func pumpQueue() {
        guard let ctx = modelContext else { return }
        if AppSettingsStore.shared.wifiOnlyDownload && !isOnWiFi {
            return
        }
        while activeTasksCount < maxConcurrent {
            var desc = FetchDescriptor<DownloadItem>(
                predicate: #Predicate<DownloadItem> { $0.state == "queued" },
                sortBy: [SortDescriptor(\DownloadItem.createdAt)]
            )
            desc.fetchLimit = 20
            guard let queued = try? ctx.fetch(desc), !queued.isEmpty else { break }
            // 手动下载优先；预缓存受并发上限约束
            let next = queued.first(where: { $0.kind != "precache" })
                ?? queued.first(where: { _ in activePrecacheCount < maxConcurrentPrecache })
            guard let nextItem = next else { break }
            nextItem.state = "downloading"
            try? ctx.save()
            activeTasksCount += 1
            let isPrecache = nextItem.kind == "precache"
            if isPrecache { activePrecacheCount += 1 }

            Task {
                await executeDownload(for: nextItem)
                self.activeTasksCount = max(0, self.activeTasksCount - 1)
                if isPrecache { self.activePrecacheCount = max(0, self.activePrecacheCount - 1) }
                self.pumpQueue()
            }
        }
    }

    private struct UnsupportedStream: Error {}

    /// 统一解析入口（官方书源接口优先，VIP 章节自动回退「内置解析」）
    private func resolveStream(for item: DownloadItem) async throws -> PlayStreamInfo {
        try await PluginRuntime.shared.resolvePlayStream(
            sourceID: item.sourceID,
            episodeURL: item.chapterID,
            forDownload: true
        )
    }

    private func executeDownload(for item: DownloadItem) async {
        let isPrecache = item.kind == "precache"
        do {
            // 直链（尤其内置解析给出的付费直链）有时效：首次失败且来源为内置解析时，
            // 作废缓存并强制重新解析一次，再退化为普通重试计数
            var attempt = 0
            var stream = try await resolveStream(for: item)
            while true {
                do {
                    try await performDownload(for: item, stream: stream)
                    return
                } catch {
                    if attempt == 0, stream.resolvedBy == BuiltinParserRuntime.resolverTag {
                        attempt = 1
                        await BuiltinParserRuntime.shared.invalidateCache(parserID: nil, episodeURL: item.chapterID)
                        stream = try await resolveStream(for: item)
                        continue
                    }
                    throw error
                }
            }
        } catch is UnsupportedStream {
            // 不可缓存的流：预缓存直接丢弃记录（在线播放即可），手动下载标记失败且不再重试
            if isPrecache {
                modelContext?.delete(item)
            } else {
                item.state = "failed"
            }
            try? modelContext?.save()
        } catch {
            // 失败项自动重试 2 次（4.4 节）；预缓存最终失败则直接丢弃，不留「失败」垃圾记录
            if item.retryCount < 2 {
                item.retryCount += 1
                item.state = "queued"
            } else if isPrecache {
                modelContext?.delete(item)
            } else {
                item.state = "failed"
            }
            try? modelContext?.save()
        }
    }

    /// 单次下载落盘：HLS/直播与文本响应一律按「不可缓存」处理
    private func performDownload(for item: DownloadItem, stream: PlayStreamInfo) async throws {
        guard let url = JsHostBridge.makeRequestURL(from: stream.url, relativeTo: item.chapterID) else {
            throw PluginError.parseFailed("无效音频地址")
        }
        // HLS(.m3u8)/直播无法作为单个文件保存：原实现会把几 KB 的播放列表当成 .mp3 存盘并标记完成，
        // 之后该章节优先播放本地「音频」，导致无法解码、进度/时长错乱
        let lowerURL = url.absoluteString.lowercased()
        if stream.kind != .onDemand || lowerURL.contains(".m3u8") {
            throw UnsupportedStream()
        }

        var req = URLRequest(url: url, timeoutInterval: 30)
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

        // 直接落盘（不再把整首音频读进内存）
        let (tmpURL, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw URLError(.badServerResponse)
        }
        let mime = http.mimeType?.lowercased() ?? ""
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.size] as? Int64) ?? 0
        if mime.hasPrefix("text/") || mime.contains("mpegurl") || mime.contains("json") || mime.contains("html") || fileSize < 1024 {
            try? FileManager.default.removeItem(at: tmpURL)
            throw UnsupportedStream()
        }

        let ext = Self.inferAudioExtension(url: url, mimeType: http.mimeType)
        let safeBookDir = JsHostBridge.md5Hex(item.bookID)
        let safeChapFile = "\(JsHostBridge.md5Hex(item.chapterID)).\(ext)"
        let relPath = "\(safeBookDir)/\(safeChapFile)"
        let destDir = downloadsRootDirectory.appendingPathComponent(safeBookDir, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = downloadsRootDirectory.appendingPathComponent(relPath)
        try? FileManager.default.removeItem(at: destFile)
        try FileManager.default.moveItem(at: tmpURL, to: destFile)

        item.localPath = relPath
        item.bytes = fileSize
        item.state = "completed"
        try? modelContext?.save()
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
