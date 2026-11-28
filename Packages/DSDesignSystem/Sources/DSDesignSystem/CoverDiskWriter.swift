import Foundation

/// 串行磁盘读写与 LRU 裁剪执行器（消除并发写盘/裁剪竞争，并在写入前复核代际）
actor CoverDiskWriter {
    func writeAndPrune(
        data: Data,
        to url: URL,
        dir: URL,
        maxBytes: Int,
        shouldPrune: Bool,
        isEpochValid: @Sendable () async -> Bool
    ) async {
        guard await isEpochValid() else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard await isEpochValid() else { return }
        try? data.write(to: url, options: [.atomic])
        guard shouldPrune, await isEpochValid() else { return }
        trimToMaxBytes(dir, maxBytes: Int64(Double(maxBytes) * 0.8), triggerLimit: Int64(maxBytes))
    }

    func clearDirectory(_ dir: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func trimToMaxBytes(_ dir: URL, maxBytes: Int64, triggerLimit: Int64? = nil) {
        let cap = max(0, maxBytes)
        let threshold = triggerLimit ?? cap
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int64)] = []
        var totalSize: Int64 = 0
        for file in files {
            let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(max(0, vals?.fileSize ?? 0))
            let date = vals?.contentModificationDate ?? .distantPast
            totalSize += size
            entries.append((file, date, size))
        }
        guard totalSize > threshold else { return }
        for item in entries.sorted(by: { $0.date < $1.date }) {
            guard totalSize > cap else { break }
            try? fm.removeItem(at: item.url)
            totalSize -= item.size
        }
    }
}
