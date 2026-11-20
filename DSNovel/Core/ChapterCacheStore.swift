import Foundation
import Compression
import CryptoKit

/// 章节列表大体量缓存：以 LZFSE 压缩 JSON 写入 Caches/chapters/<bookID>.json.lzfse，不入 SwiftData 数据库
/// 全部磁盘读写通过内部串行队列隔离，避免多线程并发写同一文件损坏。
enum ChapterCacheStore {
    static let maxCachedBooks = 100
    private static let ioQueue = DispatchQueue(label: "com.dsnovel.chaptercache.io", qos: .utility)

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

    static func saveChapters(_ chapters: [ChapterDTO], for bookID: String) {
        guard let jsonData = try? JSONEncoder().encode(chapters) else { return }
        let compressed = compressLZFSE(jsonData) ?? jsonData
        ioQueue.sync {
            try? compressed.write(to: fileURL(for: bookID), options: .atomic)
            pruneOldestIfNeeded()
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

    static func loadChapters(for bookID: String) -> [ChapterDTO]? {
        let raw: Data? = ioQueue.sync {
            let url = fileURL(for: bookID)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty else {
                return nil
            }
            return data
        }
        guard let raw else { return nil }
        guard let jsonData = decompressLZFSE(raw) else {
            return []
        }
        return try? JSONDecoder().decode([ChapterDTO].self, from: jsonData)
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

    static func clearAll() {
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
