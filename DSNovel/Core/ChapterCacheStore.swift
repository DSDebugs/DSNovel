import Foundation
import Compression
import CryptoKit

private final class ChapterCacheBox: NSObject {
    let chapters: [ChapterDTO]

    init(_ chapters: [ChapterDTO]) {
        self.chapters = chapters
    }
}

/// 章节列表大体量缓存：以魔数头 + LZFSE 压缩 JSON（或带魔数头的裸 JSON 回退态）写入 Caches/chapters/<bookID>.json.lzfse，不入 SwiftData 数据库
/// 内部维护 16 本热内存缓存（NSCache），全部磁盘读写通过内部串行队列隔离，避免多线程并发写同一文件损坏。
enum ChapterCacheStore {
    static let maxCachedBooks = 100
    static let maxMemoryCachedBooks = 16
    private static let ioQueue = DispatchQueue(label: "com.dsnovel.chaptercache.io", qos: .utility)

    /// M-P0-6：4 字节魔数头，显式区分 LZFSE 压缩态与裸 JSON 回退态
    private static let magicLZFSE: [UInt8] = [0x44, 0x53, 0x4C, 0x5A]   // "DSLZ"
    private static let magicRawJSON: [UInt8] = [0x44, 0x53, 0x4A, 0x53] // "DSJS"

    private static let memoryCache: NSCache<NSString, ChapterCacheBox> = {
        let cache = NSCache<NSString, ChapterCacheBox>()
        cache.countLimit = maxMemoryCachedBooks
        return cache
    }()

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("chapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for bookID: String) -> URL {
        let digest = SHA256.hash(data: Data(bookID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hex).json.lzfse")
    }

    private static func encodeCachePayload(from jsonData: Data) -> Data {
        if let compressed = compressLZFSE(jsonData), !compressed.isEmpty {
            var payload = Data(magicLZFSE)
            payload.append(compressed)
            return payload
        }
        var fallback = Data(magicRawJSON)
        fallback.append(jsonData)
        return fallback
    }

    static func saveChapters(_ chapters: [ChapterDTO], for bookID: String) {
        memoryCache.setObject(ChapterCacheBox(chapters), forKey: bookID as NSString)
        guard let jsonData = try? JSONEncoder().encode(chapters) else { return }
        let payload = encodeCachePayload(from: jsonData)
        ioQueue.sync {
            try? payload.write(to: fileURL(for: bookID), options: .atomic)
            pruneOldestIfNeeded()
        }
    }

    static func saveChaptersAsync(_ chapters: [ChapterDTO], for bookID: String) async {
        memoryCache.setObject(ChapterCacheBox(chapters), forKey: bookID as NSString)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                if let jsonData = try? JSONEncoder().encode(chapters) {
                    let payload = encodeCachePayload(from: jsonData)
                    try? payload.write(to: fileURL(for: bookID), options: .atomic)
                    pruneOldestIfNeeded()
                }
                continuation.resume()
            }
        }
    }

    /// 磁盘缓存条目超过 `maxCachedBooks` 时按文件修改时间淘汰最旧的缓存文件
    private static func pruneOldestIfNeeded() {
        let fm = FileManager.default
        let dir = cacheDirectory
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), urls.count > maxCachedBooks else {
            return
        }
        let sorted = urls.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lDate != rDate {
                return lDate < rDate
            }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
        let excessCount = sorted.count - maxCachedBooks
        for oldURL in sorted.prefix(excessCount) {
            try? fm.removeItem(at: oldURL)
        }
    }

    private static func readRawDataUnlocked(for bookID: String) -> Data? {
        let url = fileURL(for: bookID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    private static func removeCorruptedCacheUnlocked(for bookID: String) {
        memoryCache.removeObject(forKey: bookID as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: bookID))
    }

    /// M-P0-6：按魔数头区分压缩态/裸 JSON 态，同时兼容旧版无魔数头的 LZFSE 与裸 JSON；
    /// 任一解压或解码失败立即删除损坏缓存文件并返回 `nil`（绝不返回 `[]` 导致永久 0 章）。
    private static func decodeAndCacheChaptersUnlocked(from raw: Data, for bookID: String) -> [ChapterDTO]? {
        let jsonData: Data?
        if raw.starts(with: magicLZFSE) {
            let body = Data(raw.dropFirst(magicLZFSE.count))
            jsonData = decompressLZFSE(body)
        } else if raw.starts(with: magicRawJSON) {
            jsonData = Data(raw.dropFirst(magicRawJSON.count))
        } else {
            // 兼容旧版无魔数头缓存：优先尝试 LZFSE 解压，失败时尝试裸 JSON 兼容解码
            if let decompressed = decompressLZFSE(raw) {
                jsonData = decompressed
            } else if looksLikeJSONArray(raw) {
                jsonData = raw
            } else {
                jsonData = nil
            }
        }

        guard let validJSON = jsonData,
              let decoded = try? JSONDecoder().decode([ChapterDTO].self, from: validJSON) else {
            removeCorruptedCacheUnlocked(for: bookID)
            return nil
        }
        memoryCache.setObject(ChapterCacheBox(decoded), forKey: bookID as NSString)
        return decoded
    }

    private static func looksLikeJSONArray(_ data: Data) -> Bool {
        for byte in data {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue
            }
            return byte == 0x5B // '['
        }
        return false
    }

    static func loadChapters(for bookID: String) -> [ChapterDTO]? {
        if let cached = memoryCache.object(forKey: bookID as NSString) {
            return cached.chapters
        }
        return ioQueue.sync {
            guard let raw = readRawDataUnlocked(for: bookID) else { return nil }
            return decodeAndCacheChaptersUnlocked(from: raw, for: bookID)
        }
    }

    static func loadChaptersAsync(for bookID: String) async -> [ChapterDTO]? {
        if let cached = memoryCache.object(forKey: bookID as NSString) {
            return cached.chapters
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[ChapterDTO]?, Never>) in
            ioQueue.async {
                guard let raw = readRawDataUnlocked(for: bookID) else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = decodeAndCacheChaptersUnlocked(from: raw, for: bookID)
                continuation.resume(returning: result)
            }
        }
    }

    /// 缓存文件的年龄（秒）；不存在返回 nil。用于「近期刚拉取过就不再整本重拉」
    static func cacheAge(for bookID: String) -> TimeInterval? {
        ioQueue.sync {
            let url = fileURL(for: bookID)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return Date().timeIntervalSince(modified)
        }
    }

    static func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    static func clearAll() {
        memoryCache.removeAllObjects()
        ioQueue.sync {
            try? FileManager.default.removeItem(at: cacheDirectory)
            _ = cacheDirectory
        }
    }

    static func compressLZFSE(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let dstCapacity = max(data.count + 512, 1024)
        var dstBuffer = [UInt8](repeating: 0, count: dstCapacity)
        let written = data.withUnsafeBytes { srcPtr -> Int in
            guard let baseAddress = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                &dstBuffer,
                dstCapacity,
                baseAddress,
                data.count,
                nil,
                COMPRESSION_LZFSE
            )
        }
        guard written > 0 else { return nil }
        return Data(dstBuffer.prefix(written))
    }

    static func decompressLZFSE(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var dstCapacity = max(data.count * 6, 4096)
        for _ in 0..<4 {
            var dstBuffer = [UInt8](repeating: 0, count: dstCapacity)
            let decoded = data.withUnsafeBytes { srcPtr -> Int in
                guard let baseAddress = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    &dstBuffer,
                    dstCapacity,
                    baseAddress,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
            if decoded > 0 && decoded < dstCapacity {
                return Data(dstBuffer.prefix(decoded))
            }
            dstCapacity *= 4
        }
        return nil
    }
}


/// 单章收听进度轻量化存储（T0-05：每条进度保存更新时间，超过上限时按更新时间淘汰最旧项，兼容旧版纯 Int 字典格式）
enum ChapterProgressStore {
    static let maxEntriesPerBook = 400

    private static func key(for bookID: String) -> String {
        let digest = SHA256.hash(data: Data(bookID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return "chapter_prog_\(hex)"
    }

    static func loadAll(for bookID: String, defaults: UserDefaults = .standard) -> [String: Int] {
        guard let raw = defaults.dictionary(forKey: key(for: bookID)) else {
            return [:]
        }
        var result: [String: Int] = [:]
        for (chapterID, val) in raw {
            if let pos = val as? Int {
                result[chapterID] = pos
            } else if let num = val as? NSNumber {
                result[chapterID] = num.intValue
            } else if let entry = val as? [String: Any] {
                if let pos = entry["p"] as? Int {
                    result[chapterID] = pos
                } else if let num = entry["p"] as? NSNumber {
                    result[chapterID] = num.intValue
                }
            }
        }
        return result
    }

    static func save(
        bookID: String,
        chapterID: String,
        positionMs: Int,
        now: TimeInterval = Date().timeIntervalSince1970,
        defaults: UserDefaults = .standard
    ) {
        guard !bookID.isEmpty, !chapterID.isEmpty, positionMs > 0 else { return }
        let storageKey = key(for: bookID)
        let raw = defaults.dictionary(forKey: storageKey) ?? [:]

        var entries: [String: (pos: Int, updatedAt: TimeInterval)] = [:]
        for (cid, val) in raw {
            if let pos = val as? Int {
                entries[cid] = (pos, now - 1.0)
            } else if let num = val as? NSNumber {
                entries[cid] = (num.intValue, now - 1.0)
            } else if let dict = val as? [String: Any] {
                let p = (dict["p"] as? Int) ?? (dict["p"] as? NSNumber)?.intValue ?? 0
                let u = (dict["u"] as? TimeInterval) ?? (dict["u"] as? NSNumber)?.doubleValue ?? (now - 1.0)
                if p > 0 {
                    entries[cid] = (p, u)
                }
            }
        }

        entries[chapterID] = (positionMs, now)

        if entries.count > maxEntriesPerBook {
            let sorted = entries.sorted { a, b in
                if a.value.updatedAt != b.value.updatedAt {
                    return a.value.updatedAt > b.value.updatedAt
                }
                return a.key < b.key
            }
            var kept: [String: [String: Any]] = [:]
            for (idx, item) in sorted.enumerated() where idx < maxEntriesPerBook {
                kept[item.key] = ["p": item.value.pos, "u": item.value.updatedAt]
            }
            defaults.set(kept, forKey: storageKey)
        } else {
            var serialized: [String: [String: Any]] = [:]
            for (cid, item) in entries {
                serialized[cid] = ["p": item.pos, "u": item.updatedAt]
            }
            defaults.set(serialized, forKey: storageKey)
        }
    }

    static func clear(for bookID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: bookID))
    }

    static func formattedPosition(ms: Int) -> String {
        guard ms > 0 else { return "00:00" }
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
