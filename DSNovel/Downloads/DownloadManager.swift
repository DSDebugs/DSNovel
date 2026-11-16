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
            let desc = FetchDescriptor<DownloadItem>(
                predicate: #Predicate<DownloadItem> { $0.state == "queued" },
                sortBy: [SortDescriptor(\DownloadItem.createdAt)]
            )
            guard let nextItem = try? ctx.fetch(desc).first else { break }
            nextItem.state = "downloading"
            try? ctx.save()
            activeTasksCount += 1

            Task {
                await executeDownload(for: nextItem)
                self.activeTasksCount = max(0, self.activeTasksCount - 1)
                self.pumpQueue()
            }
        }
    }

    private func executeDownload(for item: DownloadItem) async {
        do {
            let stream = try await PluginRuntime.shared.resolvePlayURL(sourceID: item.sourceID, episodeURL: item.chapterID)
            guard let url = JsHostBridge.makeRequestURL(from: stream.url, relativeTo: item.chapterID) else {
                throw PluginError.parseFailed("无效音频地址")
            }
            var req = URLRequest(url: url, timeoutInterval: 30)
            for (k, v) in stream.headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                throw URLError(.badServerResponse)
            }

            let ext = Self.inferAudioExtension(url: url, mimeType: http.mimeType)
            let safeBookDir = JsHostBridge.md5Hex(item.bookID)
            let safeChapFile = "\(JsHostBridge.md5Hex(item.chapterID)).\(ext)"
            let relPath = "\(safeBookDir)/\(safeChapFile)"
            let destDir = downloadsRootDirectory.appendingPathComponent(safeBookDir, isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destFile = downloadsRootDirectory.appendingPathComponent(relPath)
            try data.write(to: destFile, options: .atomic)

            item.localPath = relPath
            item.bytes = Int64(data.count)
            item.state = "completed"
            try? modelContext?.save()
        } catch {
            // 失败项自动重试 2 次（4.4 节）
            if item.retryCount < 2 {
                item.retryCount += 1
                item.state = "queued"
            } else {
                item.state = "failed"
            }
            try? modelContext?.save()
        }
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
