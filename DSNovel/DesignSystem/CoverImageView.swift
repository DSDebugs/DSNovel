import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// 封面网络拉取协议（支持在单元测试中注入假网络测量请求合并与磁盘淘汰）
protocol CoverImageDataFetching: Sendable {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionCoverImageFetcher: CoverImageDataFetching {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// 高性能封面图片管线（T0-06 + v2.8 滚动性能优化）：
/// - 内存 NSCache（上限 80 MB，直接用 url_pixelMax 作键，消除主线程 SHA256 开销）
/// - 磁盘缓存（上限 200 MB，超出淘汰至 70%，30 秒节流，后台卸载不阻塞 Actor）
/// - 同 URL 并发请求合并 + 最多 8 路并发下载限流 + 快速取消不可见卡片
actor CoverImagePipeline {
    static let shared = CoverImagePipeline()

    nonisolated(unsafe) private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024 // 80 MB
        return cache
    }()

    private let diskDirectory: URL
    private let maxDiskBytes: Int
    private let fetcher: CoverImageDataFetching
    private var inflightTasks: [String: Task<Data?, Never>] = [:]
    private var lastEvictionTime: TimeInterval = 0
    private let evictionThrottleInterval: TimeInterval
    private let maxConcurrentDownloads: Int = 8
    private var activeDownloads: Int = 0
    private var downloadWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        diskDirectory: URL? = nil,
        maxDiskBytes: Int = 200 * 1024 * 1024,
        evictionThrottleInterval: TimeInterval = 30.0,
        fetcher: CoverImageDataFetching = URLSessionCoverImageFetcher()
    ) {
        if let diskDirectory {
            self.diskDirectory = diskDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.diskDirectory = caches.appendingPathComponent("CoverCache", isDirectory: true)
        }
        self.maxDiskBytes = maxDiskBytes
        self.evictionThrottleInterval = evictionThrottleInterval
        self.fetcher = fetcher
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
    }

    func cachedImage(for key: String) -> UIImage? {
        memoryCache.object(forKey: key as NSString)
    }

    nonisolated static func memoryCacheKey(for url: String, side: CGFloat, scale: CGFloat) -> String {
        let pixelMax = Int(max(side, 80) * scale)
        return "\(url)_\(pixelMax)"
    }

    nonisolated func cachedInMemory(for url: String, side: CGFloat = 96, scale: CGFloat = 3.0) -> UIImage? {
        guard !url.isEmpty else { return nil }
        let cacheKey = Self.memoryCacheKey(for: url, side: side, scale: scale)
        return memoryCache.object(forKey: cacheKey as NSString)
    }

    func image(for url: String, headers: [String: String] = [:], targetSize: CGSize, scale: CGFloat = 3.0) async -> UIImage? {
        await loadImage(url: url, headers: headers, targetPointSize: targetSize, scale: scale)
    }

    private func acquireDownloadSlot() async {
        if activeDownloads < maxConcurrentDownloads {
            activeDownloads += 1
            return
        }
        await withCheckedContinuation { cont in
            downloadWaiters.append(cont)
        }
        activeDownloads += 1
    }

    private func releaseDownloadSlot() {
        activeDownloads = max(0, activeDownloads - 1)
        if !downloadWaiters.isEmpty {
            let next = downloadWaiters.removeFirst()
            next.resume()
        }
    }

    func loadImage(url: String, headers: [String: String] = [:], targetPointSize: CGSize, scale: CGFloat = 3.0) async -> UIImage? {
        guard !url.isEmpty, let requestURL = URL(string: url) else { return nil }
        let maxSide = max(targetPointSize.width, targetPointSize.height)
        let pixelMax = Int(max(maxSide, 80) * scale)
        let cacheKey = Self.memoryCacheKey(for: url, side: maxSide, scale: scale)

        if let mem = memoryCache.object(forKey: cacheKey as NSString) {
            return mem
        }
        if Task.isCancelled { return nil }

        let urlHash = sha256Hex(url)
        let diskURL = diskDirectory.appendingPathComponent(urlHash + ".img")

        // 磁盘读取与降采样卸载到后台线程，不阻塞 Actor 队列
        let diskImage: UIImage? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard !Task.isCancelled,
                  fm.fileExists(atPath: diskURL.path),
                  let data = try? Data(contentsOf: diskURL),
                  let downsampled = CoverImagePipeline.downsample(data: data, maxDimensionInPixels: pixelMax) else {
                return nil
            }
            // 1 小时节流更新 modificationDate，避免高频滚动反复写入文件元数据
            let now = Date()
            let lastMod = (try? diskURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(lastMod) >= 3600 {
                try? fm.setAttributes([.modificationDate: now], ofItemAtPath: diskURL.path)
            }
            return downsampled
        }.value

        if let diskImage {
            let cost = Int(diskImage.size.width * diskImage.size.height * 4)
            memoryCache.setObject(diskImage, forKey: cacheKey as NSString, cost: cost)
            return diskImage
        }

        if Task.isCancelled { return nil }
        if let memAfterDisk = memoryCache.object(forKey: cacheKey as NSString) {
            return memAfterDisk
        }

        let task: Task<Data?, Never>
        if let existingTask = inflightTasks[url] {
            task = existingTask
        } else {
            let fetcherRef = self.fetcher
            let targetDiskURL = diskURL
            let newTask = Task<Data?, Never> { [weak self] in
                guard let self else { return nil }
                await self.acquireDownloadSlot()
                defer {
                    Task { await self.releaseDownloadSlot() }
                }
                if Task.isCancelled { return nil }
                var request = URLRequest(url: requestURL, timeoutInterval: 10)
                for (k, v) in headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }
                if request.value(forHTTPHeaderField: "User-Agent") == nil {
                    request.setValue(
                        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                        forHTTPHeaderField: "User-Agent"
                    )
                }
                do {
                    let (data, response) = try await fetcherRef.fetchData(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        return nil
                    }
                    guard !data.isEmpty else { return nil }
                    try? data.write(to: targetDiskURL, options: .atomic)
                    return data
                } catch {
                    return nil
                }
            }
            inflightTasks[url] = newTask
            task = newTask
        }

        let rawData = await task.value

        if Task.isCancelled {
            if inflightTasks[url] == task { inflightTasks[url] = nil }
            return nil
        }
        guard let data = rawData else {
            if inflightTasks[url] == task { inflightTasks[url] = nil }
            return nil
        }
        evictDiskCacheIfNeeded(force: false)

        let downsampled: UIImage? = await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return CoverImagePipeline.downsample(data: data, maxDimensionInPixels: pixelMax)
        }.value

        if let downsampled {
            let cost = Int(downsampled.size.width * downsampled.size.height * 4)
            memoryCache.setObject(downsampled, forKey: cacheKey as NSString, cost: cost)
        }
        if inflightTasks[url] == task {
            inflightTasks[url] = nil
        }
        return downsampled
    }

    func evictDiskCacheIfNeeded(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || (now - lastEvictionTime >= evictionThrottleInterval) else { return }
        lastEvictionTime = now

        let dir = self.diskDirectory
        let limit = self.maxDiskBytes
        if force {
            Self.performDiskEviction(in: dir, maxDiskBytes: limit)
        } else {
            Task.detached(priority: .background) {
                CoverImagePipeline.performDiskEviction(in: dir, maxDiskBytes: limit)
            }
        }
    }

    nonisolated private static func performDiskEviction(in diskDirectory: URL, maxDiskBytes: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var totalBytes = 0
        for u in urls {
            let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sz = vals?.fileSize ?? 0
            let dt = vals?.contentModificationDate ?? .distantPast
            totalBytes += sz
            entries.append((u, sz, dt))
        }

        guard totalBytes > maxDiskBytes else { return }
        let targetBytes = Int(Double(maxDiskBytes) * 0.70)
        let sortedOldestFirst = entries.sorted { $0.date < $1.date }
        for item in sortedOldestFirst {
            guard totalBytes > targetBytes else { break }
            try? fm.removeItem(at: item.url)
            totalBytes -= item.size
        }
    }

    nonisolated static func downsample(data: Data, maxDimensionInPixels: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxDimensionInPixels)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func diskUsageBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for u in urls {
            if let sz = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    private func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 纯色占位 + 降采样封面视图
struct CoverImageView: View, Equatable {
    let url: String
    let title: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    var headers: [String: String]
    var onImageLoaded: ((UIImage) -> Void)?

    init(
        url: String,
        title: String,
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat = 8,
        headers: [String: String] = [:],
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.url = url
        self.title = title
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.headers = headers
        self.onImageLoaded = onImageLoaded
    }

    static func == (lhs: CoverImageView, rhs: CoverImageView) -> Bool {
        lhs.url == rhs.url
            && lhs.title == rhs.title
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.cornerRadius == rhs.cornerRadius
            && lhs.headers == rhs.headers
    }

    var body: some View {
        DSCover(
            url: url,
            title: title,
            side: max(width, height),
            headers: headers,
            onImageLoaded: onImageLoaded
        )
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
