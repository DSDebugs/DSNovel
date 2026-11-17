import Foundation
import Compression
import CryptoKit

/// 章节列表大体量缓存：以 LZFSE 压缩 JSON 写入 Caches/chapters/<bookID>.json.lzfse，不入 SwiftData 数据库
enum ChapterCacheStore {
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
        try? compressed.write(to: fileURL(for: bookID), options: .atomic)
    }

    static func loadChapters(for bookID: String) -> [ChapterDTO]? {
        let url = fileURL(for: bookID)
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? Data(contentsOf: url), !raw.isEmpty else {
            return nil
        }
        let jsonData = decompressLZFSE(raw) ?? raw
        return try? JSONDecoder().decode([ChapterDTO].self, from: jsonData)
    }

    /// 缓存文件的年龄（秒）；不存在返回 nil。用于「近期刚拉取过就不再整本重拉」
    static func cacheAge(for bookID: String) -> TimeInterval? {
        let url = fileURL(for: bookID)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        _ = cacheDirectory
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


/// 单章收听进度轻量化存储（UserDefaults 按书持久化 chapterID -> positionMs），供详情页每章展示「听至 mm:ss」
enum ChapterProgressStore {
    private static func key(for bookID: String) -> String {
        let digest = SHA256.hash(data: Data(bookID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return "chapter_prog_\(hex)"
    }

    static func loadAll(for bookID: String) -> [String: Int] {
        guard let dict = UserDefaults.standard.dictionary(forKey: key(for: bookID)) as? [String: Int] else {
            return [:]
        }
        return dict
    }

    static func save(bookID: String, chapterID: String, positionMs: Int) {
        guard !bookID.isEmpty, !chapterID.isEmpty, positionMs > 0 else { return }
        var dict = loadAll(for: bookID)
        dict[chapterID] = positionMs
        if dict.count > 500 {
            // 避免使用 Dictionary(_:uniquingKeysWith:) 在 Swift 5 模式下的重载歧义
            var trimmed: [String: Int] = [:]
            for (chapterID, position) in dict.prefix(400) {
                trimmed[chapterID] = position
            }
            UserDefaults.standard.set(trimmed, forKey: key(for: bookID))
        } else {
            UserDefaults.standard.set(dict, forKey: key(for: bookID))
        }
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
