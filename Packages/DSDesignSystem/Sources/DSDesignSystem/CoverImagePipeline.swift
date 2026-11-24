import DSCore
import Foundation
import ImageIO
import UIKit

/// 封面图片异步管线（UI-07/AUD-24/AUD-25/AUD-59/AUD-95：订阅者计数取消 + HTTP(S) 与 10MB 限额 + 串行代际磁盘 I/O + 负缓存上限）
public actor CoverImagePipeline {
    private struct InflightEntry {
        let task: Task<UIImage?, Never>
        var subscribers: Set<UUID>
    }

    private static let maxImageBytes: Int = 10 * 1024 * 1024
    private static let maxNegativeEntries: Int = 500

    private nonisolated(unsafe) let memoryCache = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let session: URLSession
    private let negativeTTL: TimeInterval
    private let maxConcurrent: Int
    private let maxDiskBytes: Int
    private let diskWriter = CoverDiskWriter()

    private var negativeCache: [String: Date] = [:]
    private var inflight: [String: InflightEntry] = [:]
    private var activeDownloads: Int = 0
    private var downloadWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var diskWriteCount: Int = 0
    private var cacheEpoch: UInt64 = 0

    public init(
        diskDirectory: URL? = nil,
        session: URLSession = .shared,
        negativeTTL: TimeInterval = 120,
        maxConcurrent: Int = 8,
        maxDiskBytes: Int = 64 * 1024 * 1024
    ) {
        let base = diskDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskDir = base.appendingPathComponent("DSNovelV3Covers", isDirectory: true)
        self.session = session
        self.negativeTTL = max(10, negativeTTL)
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxDiskBytes = max(4 * 1024 * 1024, maxDiskBytes)
        self.memoryCache.countLimit = 220
        self.memoryCache.totalCostLimit = 48 * 1024 * 1024
        try? FileManager.default.createDirectory(at: self.diskDir, withIntermediateDirectories: true)
    }

    /// 线程安全 NSCache 同步快路径：供 DSCoverImage 初始化直出已缓存封面，零占位闪烁
    public nonisolated func cachedImageSync(for urlString: String) -> UIImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return memoryCache.object(forKey: trimmed as NSString)
    }

    public func storeInMemoryForTesting(_ image: UIImage, urlString: String) {
        let key = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        memoryCache.setObject(image, forKey: key as NSString, cost: Self.imageByteCost(image))
    }

    public func image(for urlString: String) async -> UIImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              DSSSRFValidator.isPublicHTTPURL(url) else {
            return nil
        }

        if let mem = memoryCache.object(forKey: trimmed as NSString) {
            return mem
        }
        if let expiresAt = negativeCache[trimmed] {
            if Date() < expiresAt { return nil }
            negativeCache.removeValue(forKey: trimmed)
        }

        let epochBeforeDisk = cacheEpoch
        let diskPath = diskURL(for: trimmed)
        if let decoded = await Self.readAndDecodeFromDisk(at: diskPath) {
            guard epochBeforeDisk == cacheEpoch else { return nil }
            memoryCache.setObject(decoded, forKey: trimmed as NSString, cost: Self.imageByteCost(decoded))
            return decoded
        }
        guard !Task.isCancelled else { return nil }

        let subscriberID = UUID()
        let task: Task<UIImage?, Never>
        if var existing = inflight[trimmed] {
            existing.subscribers.insert(subscriberID)
            inflight[trimmed] = existing
            task = existing.task
        } else {
            let created = Task<UIImage?, Never> {
                await self.fetchRemoteImage(url: url, key: trimmed, diskURL: diskPath)
            }
            inflight[trimmed] = InflightEntry(task: created, subscribers: [subscriberID])
            task = created
        }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.unsubscribe(key: trimmed, subscriberID: subscriberID) }
        }
        unsubscribe(key: trimmed, subscriberID: subscriberID)
        return result
    }

    /// 统计封面磁盘缓存总占用字节数
    public func diskUsageBytes() async -> Int64 {
        let dir = diskDir
        return await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return Int64(0) }
            return files.reduce(Int64(0)) { sum, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sum + Int64(max(0, size))
            }
        }.value
    }

    public func clearNegativeCache() { negativeCache.removeAll() }

    public func trimDiskCache(toMaxBytes maxBytes: Int64) async {
        await diskWriter.trimToMaxBytes(diskDir, maxBytes: maxBytes)
    }

    public func clearAll() async {
        cacheEpoch &+= 1
        for (_, entry) in inflight { entry.task.cancel() }
        inflight.removeAll()
        memoryCache.removeAllObjects()
        negativeCache.removeAll()
        await diskWriter.clearDirectory(diskDir)
    }

    public nonisolated static func validateAndDecodeImage(data: Data, contentType: String?) -> UIImage? {
        guard !data.isEmpty, data.count <= maxImageBytes else { return nil }
        if let ct = contentType?.lowercased(), !ct.isEmpty {
            if ct.contains("text/html") || ct.contains("application/json") || ct.contains("text/plain") {
                return nil
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return UIImage(cgImage: thumb)
        }
        guard let fallback = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: fallback)
    }

    private func isEpochCurrent(_ expected: UInt64) -> Bool {
        cacheEpoch == expected
    }

    private func unsubscribe(key: String, subscriberID: UUID) {
        guard var entry = inflight[key] else { return }
        entry.subscribers.remove(subscriberID)
        if entry.subscribers.isEmpty {
            entry.task.cancel()
            inflight.removeValue(forKey: key)
        } else {
            inflight[key] = entry
        }
    }

    private func recordNegative(key: String, ttl: TimeInterval? = nil) {
        let now = Date()
        negativeCache[key] = now.addingTimeInterval(ttl ?? negativeTTL)
        guard negativeCache.count > Self.maxNegativeEntries else { return }
        negativeCache = negativeCache.filter { now < $0.value }
        if negativeCache.count > Self.maxNegativeEntries {
            let overflow = negativeCache.count - Self.maxNegativeEntries
            for oldKey in negativeCache.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) {
                negativeCache.removeValue(forKey: oldKey)
            }
        }
    }

    private nonisolated static func readAndDecodeFromDisk(at url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let image = validateAndDecodeImage(data: data, contentType: "image/jpeg") else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let now = Date()
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(mtime) > 3600 {
                try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            }
            return image
        }.value
    }

    private nonisolated static func imageByteCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage {
            return max(1, cg.bytesPerRow * cg.height)
        }
        let pixels = Int(image.size.width * image.size.height * image.scale * image.scale)
        return max(1, pixels * 4)
    }

    private func acquireDownloadSlot() async -> Bool {
        if Task.isCancelled { return false }
        if activeDownloads < maxConcurrent {
            activeDownloads += 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                downloadWaiters.append((id: waiterID, continuation: cont))
            }
        } onCancel: {
            Task { await self.cancelDownloadWaiter(id: waiterID) }
        }
    }

    private func cancelDownloadWaiter(id: UUID) {
        guard let idx = downloadWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = downloadWaiters.remove(at: idx)
        waiter.continuation.resume(returning: false)
    }

    private func releaseDownloadSlot() {
        if !downloadWaiters.isEmpty {
            let next = downloadWaiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            activeDownloads = max(0, activeDownloads - 1)
        }
    }

    private func fetchRemoteImage(url: URL, key: String, diskURL: URL) async -> UIImage? {
        let epoch = cacheEpoch
        guard await acquireDownloadSlot() else { return nil }
        defer { releaseDownloadSlot() }
        guard !Task.isCancelled, epoch == cacheEpoch else { return nil }

        do {
            guard let (data, http) = try await fetchValidatedImageData(startingAt: url) else {
                recordNegative(key: key, ttl: min(12, negativeTTL))
                return nil
            }
            guard !Task.isCancelled, epoch == cacheEpoch else { return nil }
            let ct = http.value(forHTTPHeaderField: "Content-Type")
            guard (200...299).contains(http.statusCode), data.count <= Self.maxImageBytes else {
                let isPermanent = (http.statusCode == 404 || http.statusCode == 410)
                recordNegative(key: key, ttl: isPermanent ? negativeTTL : min(12, negativeTTL))
                return nil
            }
            let decoded: UIImage? = await Task.detached(priority: .utility) {
                Self.validateAndDecodeImage(data: data, contentType: ct)
            }.value
            guard !Task.isCancelled, epoch == cacheEpoch else { return nil }
            guard let image = decoded else {
                recordNegative(key: key)
                return nil
            }
            memoryCache.setObject(image, forKey: key as NSString, cost: Self.imageByteCost(image))
            diskWriteCount &+= 1
            let shouldPrune = (diskWriteCount % 16 == 0)
            let dir = diskDir
            let limit = maxDiskBytes
            let writer = diskWriter
            let diskData = (data.count > 120_000 ? image.jpegData(compressionQuality: 0.82) : nil) ?? data
            Task.detached(priority: .utility) { [weak self] in
                await writer.writeAndPrune(
                    data: diskData,
                    to: diskURL,
                    dir: dir,
                    maxBytes: limit,
                    shouldPrune: shouldPrune,
                    isEpochValid: { [weak self] in
                        guard let self else { return false }
                        return await self.isEpochCurrent(epoch)
                    }
                )
            }
            return image
        } catch is CancellationError {
            return nil
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return nil
        } catch {
            if epoch == cacheEpoch {
                recordNegative(key: key, ttl: min(12, negativeTTL))
            }
            return nil
        }
    }

    /// 逐跳校验公网语法 + DNS 私网/回环解析，并用块级流式 10MB 硬上限防重定向 SSRF 与 OOM
    private func fetchValidatedImageData(startingAt initialURL: URL) async throws -> (Data, HTTPURLResponse)? {
        var currentURL = initialURL
        for hop in 0...5 {
            guard DSSSRFValidator.isPublicHTTPURL(currentURL),
                  await DSSSRFValidator.firstBlockedResolvedHost(for: currentURL) == nil else { return nil }
            var req = URLRequest(url: currentURL)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            if let scheme = currentURL.scheme, let host = currentURL.host { req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer") }
            let (data, http) = try await DSCappedHTTPTransfer.fetch(request: req, session: session, maxBytes: Self.maxImageBytes, blockRedirects: true)
            guard (301...303).contains(http.statusCode) || http.statusCode == 307 || http.statusCode == 308 else { return (data, http) }
            guard hop < 5, let loc = http.value(forHTTPHeaderField: "Location")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !loc.isEmpty, let nextURL = URL(string: loc, relativeTo: currentURL)?.absoluteURL else { return nil }
            currentURL = nextURL
        }
        return nil
    }

    private func diskURL(for key: String) -> URL {
        diskDir.appendingPathComponent("\(DSCrypto.md5Hex(key)).img")
    }
}
