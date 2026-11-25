import Compression
import DSCore
import Foundation

/// 章节目录磁盘缓存（L-IOS-4：强制 4 字节魔数头 DSLZ/DSJS，损坏立即删文件返回 nil，绝不返回空 [] 锁死 0 章）
public actor ChapterCacheStore: ChapterCaching {
    private struct MemoryEntry {
        let chapters: [ChapterDTO]
        let updatedAt: Date
    }

    private struct CachedPayload: Codable {
        let savedAt: Date
        let chapters: [ChapterDTO]
    }

    private static let magicLZFSE = Data("DSLZ".utf8)
    private static let magicRawJSON = Data("DSJS".utf8)
    private static let maxDecompressedBytes = 32 * 1024 * 1024
    private static let mtimeTouchIntervalSeconds: TimeInterval = 48 * 3600
    private static let maxMemoryEntries = 12

    private let directory: URL
    private let maxEntries: Int
    private var memoryCache: [String: MemoryEntry] = [:]
    private var memoryOrder: [String] = []
    private var protectedBookIDs: Set<String> = []

    public init(baseDirectory: URL? = nil, maxEntries: Int = 200) {
        let root = baseDirectory ?? StorageContainerFactory.defaultStorageDirectory()
        self.directory = root.appendingPathComponent("ChapterCache", isDirectory: true)
        self.maxEntries = max(20, maxEntries)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func loadChapters(bookID: String) async -> [ChapterDTO]? {
        await loadChaptersWithTimestamp(bookID: bookID)?.chapters
    }

    public func loadChaptersWithTimestamp(bookID: String) async -> (chapters: [ChapterDTO], updatedAt: Date)? {
        if let hit = memoryCache[bookID] {
            touchMemoryLRU(bookID)
            return (hit.chapters, hit.updatedAt)
        }
        let fileURL = cacheURL(for: bookID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let raw = try? Data(contentsOf: fileURL), raw.count >= 4 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        let header = raw.prefix(4)
        let payload = raw.dropFirst(4)
        let jsonData: Data?

        if header == Self.magicLZFSE {
            jsonData = decompressLZFSE(Data(payload))
        } else if header == Self.magicRawJSON {
            jsonData = Data(payload)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        let now = Date()
        let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
        let chapters: [ChapterDTO]
        let savedAt: Date
        if let validJSON = jsonData,
           let envelope = try? JSONDecoder().decode(CachedPayload.self, from: validJSON),
           !envelope.chapters.isEmpty {
            chapters = envelope.chapters
            savedAt = envelope.savedAt
        } else if let validJSON = jsonData,
                  let legacy = try? JSONDecoder().decode([ChapterDTO].self, from: validJSON),
                  !legacy.isEmpty {
            chapters = legacy
            savedAt = mtime
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        if now.timeIntervalSince(mtime) > Self.mtimeTouchIntervalSeconds {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fileURL.path)
        }
        storeInMemory(chapters: chapters, updatedAt: savedAt, bookID: bookID)
        return (chapters, savedAt)
    }

    public func updateProtectedBookIDs(_ ids: Set<String>) {
        protectedBookIDs = ids
    }

    public func saveChapters(_ chapters: [ChapterDTO], bookID: String) async throws {
        guard !chapters.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let jsonData = try JSONEncoder().encode(CachedPayload(savedAt: now, chapters: chapters))
        let fileURL = cacheURL(for: bookID)

        var output: Data
        if let compressed = compressLZFSE(jsonData), compressed.count < jsonData.count {
            output = Self.magicLZFSE
            output.append(compressed)
        } else {
            output = Self.magicRawJSON
            output.append(jsonData)
        }
        try output.write(to: fileURL, options: [.atomic])
        storeInMemory(chapters: chapters, updatedAt: now, bookID: bookID)
        trimIfNeeded()
    }

    public func removeChapters(bookID: String) async {
        memoryCache.removeValue(forKey: bookID)
        memoryOrder.removeAll { $0 == bookID }
        try? FileManager.default.removeItem(at: cacheURL(for: bookID))
    }

    /// 统计章节目录磁盘缓存总占用字节数（后台脱离 actor 队列执行，不阻塞章节目录读取）
    public func diskUsageBytes() async -> Int64 {
        let dir = directory
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

    public func clearAll() async {
        memoryCache.removeAll()
        memoryOrder.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 清理目录缓存，同时保护指定书籍（如当前正在播放与已离线下载书籍），避免离线场景丢目录
    public func clearAll(preservingBookIDs protectedIDs: Set<String>) async {
        protectedBookIDs = protectedIDs
        guard !protectedIDs.isEmpty else {
            await clearAll()
            return
        }
        memoryCache = memoryCache.filter { protectedIDs.contains($0.key) }
        memoryOrder.removeAll { !protectedIDs.contains($0) }
        let protectedFiles = Set(protectedIDs.map { "\(DSCrypto.sha256Hex($0)).dscache" })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where !protectedFiles.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 按最久未修改顺序裁剪非保护书籍的章节目录磁盘缓存至目标字节上限
    public func trimOldestCaches(toMaxBytes maxBytes: Int64, preservingBookIDs protectedIDs: Set<String>) async {
        protectedBookIDs = protectedIDs
        let cap = max(0, maxBytes)
        let protectedFiles = Set(protectedIDs.map { "\(DSCrypto.sha256Hex($0)).dscache" })
        let hashToBookID: [String: String] = Dictionary(
            uniqueKeysWithValues: memoryCache.keys.map { ("\(DSCrypto.sha256Hex($0)).dscache", $0) }
        )
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var totalBytes: Int64 = 0
        var evictable: [(url: URL, name: String, date: Date, size: Int64)] = []
        for file in files {
            let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(max(0, vals?.fileSize ?? 0))
            totalBytes += size
            let name = file.lastPathComponent
            if !protectedFiles.contains(name) {
                let date = vals?.contentModificationDate ?? .distantPast
                evictable.append((file, name, date, size))
            }
        }
        guard totalBytes > cap else { return }
        for item in evictable.sorted(by: { $0.date < $1.date }) {
            guard totalBytes > cap else { break }
            try? FileManager.default.removeItem(at: item.url)
            if let bid = hashToBookID[item.name] {
                memoryCache.removeValue(forKey: bid)
                memoryOrder.removeAll { $0 == bid }
            }
            totalBytes -= item.size
        }
    }

    private func storeInMemory(chapters: [ChapterDTO], updatedAt: Date, bookID: String) {
        memoryCache[bookID] = MemoryEntry(chapters: chapters, updatedAt: updatedAt)
        touchMemoryLRU(bookID)
        while memoryOrder.count > Self.maxMemoryEntries {
            let evicted = memoryOrder.removeFirst()
            memoryCache.removeValue(forKey: evicted)
        }
    }

    private func touchMemoryLRU(_ bookID: String) {
        memoryOrder.removeAll { $0 == bookID }
        memoryOrder.append(bookID)
    }

    private func cacheURL(for bookID: String) -> URL {
        directory.appendingPathComponent("\(DSCrypto.sha256Hex(bookID)).dscache")
    }

    private func trimIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > maxEntries else { return }

        let protectedFiles = Set(protectedBookIDs.map { "\(DSCrypto.sha256Hex($0)).dscache" })
        let evictableFiles = files.filter { !protectedFiles.contains($0.lastPathComponent) }
        let excess = files.count - maxEntries
        guard excess > 0, !evictableFiles.isEmpty else { return }

        // AUD-37：先 map 提取 (url, mtime) 再排序，避免排序比较器内重复触发文件系统属性读取
        let entriesWithDates: [(url: URL, mtime: Date)] = evictableFiles.map { url in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url: url, mtime: mtime)
        }
        let sorted = entriesWithDates.sorted { $0.mtime < $1.mtime }
        for stale in sorted.prefix(excess) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    private func compressLZFSE(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count + 256, 1024)
        var dst = Data(count: capacity)
        let written: Int = dst.withUnsafeMutableBytes { dstPtr in
            data.withUnsafeBytes { srcPtr in
                guard let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, capacity, srcBase, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        dst.count = written
        return dst
    }

    /// P2-04：使用 compression_stream_process 流式解压（32 MB 上限），兼容 >32x 高压缩率长目录且损坏立即失败
    private func decompressLZFSE(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        var status = compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        let chunkSize = 32 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuffer.deallocate() }

        var output = Data()
        output.reserveCapacity(min(Self.maxDecompressedBytes, max(data.count * 4, 4096)))

        let ok: Bool = data.withUnsafeBytes { rawSrc in
            guard let srcBase = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return false }
            streamPtr.pointee.src_ptr = srcBase
            streamPtr.pointee.src_size = data.count

            repeat {
                let prevSrcSize = streamPtr.pointee.src_size
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = chunkSize
                status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = chunkSize - streamPtr.pointee.dst_size
                    if produced > 0 {
                        if output.count + produced > Self.maxDecompressedBytes { return false }
                        output.append(dstBuffer, count: produced)
                    } else if status == COMPRESSION_STATUS_OK && streamPtr.pointee.src_size == prevSrcSize {
                        return false
                    }
                default:
                    return false
                }
            } while status == COMPRESSION_STATUS_OK
            return true
        }
        return (ok && !output.isEmpty) ? output : nil
    }
}
