import Compression
import DSCore
import Foundation

/// 章节目录磁盘缓存（L-IOS-4：强制 4 字节魔数头 DSLZ/DSJS，损坏立即删文件返回 nil，绝不返回空 [] 锁死 0 章）
public actor ChapterCacheStore: ChapterCaching {
    private static let magicLZFSE = Data("DSLZ".utf8)
    private static let magicRawJSON = Data("DSJS".utf8)
    private static let maxDecompressedBytes = 32 * 1024 * 1024
    private static let mtimeTouchIntervalSeconds: TimeInterval = 3600

    private let directory: URL
    private let maxEntries: Int

    public init(baseDirectory: URL? = nil, maxEntries: Int = 200) {
        let root = baseDirectory ?? StorageContainerFactory.defaultStorageDirectory()
        self.directory = root.appendingPathComponent("ChapterCache", isDirectory: true)
        self.maxEntries = max(20, maxEntries)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func loadChapters(bookID: String) async -> [ChapterDTO]? {
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
            // 未知/损坏头：立即删除文件并返回 nil 触发重新拉取
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        guard let validJSON = jsonData,
              let chapters = try? JSONDecoder().decode([ChapterDTO].self, from: validJSON),
              !chapters.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        // AUD-37：命中时节流刷新 mtime（距上次 > 1 小时），维持真实 LRU 淘汰顺序
        let now = Date()
        let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if now.timeIntervalSince(mtime) > Self.mtimeTouchIntervalSeconds {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fileURL.path)
        }
        return chapters
    }

    public func saveChapters(_ chapters: [ChapterDTO], bookID: String) async throws {
        guard !chapters.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonData = try JSONEncoder().encode(chapters)
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
        trimIfNeeded()
    }

    public func removeChapters(bookID: String) async {
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
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

        // AUD-37：先 map 提取 (url, mtime) 再排序，避免排序比较器内重复触发文件系统属性读取
        let entriesWithDates: [(url: URL, mtime: Date)] = files.map { url in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url: url, mtime: mtime)
        }
        let sorted = entriesWithDates.sorted { $0.mtime < $1.mtime }
        for stale in sorted.prefix(files.count - maxEntries) {
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
