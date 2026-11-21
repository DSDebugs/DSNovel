import Foundation

// MARK: - 内置解析：日志（内存 + 串行异步批量落盘 + 脱敏导出/统计）
//
// 修复 P1-05 / L-04 / P-06：
// - DateFormatter 严格限制在锁内访问，杜绝并发数据竞争
// - 磁盘写入经由独立串行队列防抖批量刷盘（不再每条日志开关文件与 stat），降低 IO 风暴
// - 提供脱敏导出（⑦ 可观测性）与成功率统计

struct BuiltinParserLogEntry: Identifiable, Equatable, Sendable {
    let id: UInt64
    let text: String
}

struct BuiltinParserLogStats: Equatable, Sendable {
    var totalResolves: Int
    var successes: Int
    var failures: Int
    var cacheHits: Int

    var successRatePercent: Int {
        let attempts = successes + failures
        guard attempts > 0 else { return 0 }
        return Int((Double(successes) / Double(attempts) * 100.0).rounded())
    }
}

final class BuiltinParserLogStore: @unchecked Sendable {
    static let shared = BuiltinParserLogStore()

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.dsnovel.builtinparser.logio", qos: .utility)
    private var buffers: [String: [BuiltinParserLogEntry]] = [:]
    private var versions: [String: UInt64] = [:]
    private var nextEntryID: UInt64 = 0
    private var loadedFromDisk: Set<String> = []
    private var pendingDiskEntries: [String: [String]] = [:]
    private var flushScheduled = false
    /// 展示给 UI 的条数
    private let displayCapacity = 200
    /// 落盘保留条数（略大于展示容量，便于回溯）
    private let persistCapacity = 400
    /// 单文件体积上限
    private let maxFileBytes = 256 * 1024

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private init() {}

    private func makeEntryLocked(_ text: String) -> BuiltinParserLogEntry {
        nextEntryID &+= 1
        return BuiltinParserLogEntry(id: nextEntryID, text: text)
    }

    func append(_ parserID: String, _ line: String) {
        lock.lock()
        let stamp = formatter.string(from: Date())
        let entryText = "[\(stamp)] \(line)"
        var buffer = buffers[parserID] ?? []
        buffer.append(makeEntryLocked(entryText))
        if buffer.count > persistCapacity {
            buffer.removeFirst(buffer.count - persistCapacity)
        }
        buffers[parserID] = buffer
        versions[parserID, default: 0] &+= 1

        var pending = pendingDiskEntries[parserID] ?? []
        pending.append(entryText)
        pendingDiskEntries[parserID] = pending
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        lock.unlock()

        #if DEBUG
        print("[BuiltinParser] \(entryText)")
        #endif

        if shouldSchedule {
            ioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.flushPendingToDisk()
            }
        }
    }

    /// 10-3：获取指定解析器日志当前单调版本号（O(1) 无拷贝，供日志页增量刷新判定）
    func version(for parserID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return versions[parserID] ?? 0
    }

    /// 10-3：按版本号增量拉取带稳定单调递增 ID 的日志快照；版本号未变化时返回 nil，避免无意义全表重建
    func snapshotAsync(
        for parserID: String,
        afterVersion: UInt64?
    ) async -> (version: UInt64, entries: [BuiltinParserLogEntry], stats: BuiltinParserLogStats)? {
        lock.lock()
        let memory = buffers[parserID] ?? []
        let alreadyLoaded = loadedFromDisk.contains(parserID)
        let currentVersion = versions[parserID] ?? 0
        if (!memory.isEmpty || alreadyLoaded), let afterVersion, afterVersion == currentVersion {
            lock.unlock()
            return nil
        }
        if !memory.isEmpty || alreadyLoaded {
            let slice = Array(memory.suffix(displayCapacity))
            lock.unlock()
            return (currentVersion, slice, Self.computeStats(from: slice.map(\.text)))
        }
        lock.unlock()

        let restoredText: [String] = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: Self.readFromDisk(parserID: parserID))
            }
        }
        lock.lock()
        loadedFromDisk.insert(parserID)
        if (buffers[parserID] ?? []).isEmpty && !restoredText.isEmpty {
            buffers[parserID] = restoredText.map { makeEntryLocked($0) }
            versions[parserID, default: 0] &+= 1
        }
        let finalVersion = versions[parserID] ?? 0
        let latest = buffers[parserID] ?? []
        let slice = Array(latest.suffix(displayCapacity))
        lock.unlock()
        if let afterVersion, afterVersion == finalVersion {
            return nil
        }
        return (finalVersion, slice, Self.computeStats(from: slice.map(\.text)))
    }

    /// 读取：内存优先；已有缓存或已加载过磁盘时直接返回内存快照，避免阻塞主线程
    func lines(for parserID: String) -> [String] {
        lock.lock()
        let memory = buffers[parserID] ?? []
        let alreadyLoaded = loadedFromDisk.contains(parserID)
        lock.unlock()
        if !memory.isEmpty || alreadyLoaded {
            return Array(memory.suffix(displayCapacity)).map(\.text)
        }
        let restored = ioQueue.sync {
            Self.readFromDisk(parserID: parserID)
        }
        lock.lock()
        loadedFromDisk.insert(parserID)
        if (buffers[parserID] ?? []).isEmpty && !restored.isEmpty {
            buffers[parserID] = restored.map { makeEntryLocked($0) }
            versions[parserID, default: 0] &+= 1
        }
        let latest = buffers[parserID] ?? []
        lock.unlock()
        return Array(latest.suffix(displayCapacity)).map(\.text)
    }

    /// 供 UI 异步读取日志：冷启动未命中内存缓存时在 ioQueue 异步读盘，不阻塞主线程
    func linesAsync(for parserID: String) async -> [String] {
        if let snap = await snapshotAsync(for: parserID, afterVersion: nil) {
            return snap.entries.map(\.text)
        }
        return []
    }

    func clear(_ parserID: String) {
        lock.lock()
        buffers[parserID] = []
        loadedFromDisk.insert(parserID)
        pendingDiskEntries[parserID] = nil
        versions[parserID, default: 0] &+= 1
        lock.unlock()
        ioQueue.async {
            Self.writeToDisk(parserID: parserID, lines: [])
        }
    }

    /// 统计解析成功率与缓存命中（⑦ 可观测性）
    func stats(for parserID: String) -> BuiltinParserLogStats {
        Self.computeStats(from: lines(for: parserID))
    }

    private static func computeStats(from all: [String]) -> BuiltinParserLogStats {
        var successes = 0
        var failures = 0
        var cacheHits = 0
        for line in all {
            if line.contains("解析成功（") {
                successes += 1
            } else if line.contains("解析失败：") || line.contains("内置解析未命中") {
                failures += 1
            } else if line.contains("命中解析缓存") {
                cacheHits += 1
            }
        }
        return BuiltinParserLogStats(
            totalResolves: successes + failures + cacheHits,
            successes: successes,
            failures: failures,
            cacheHits: cacheHits
        )
    }

    /// 导出脱敏日志文本（自动隐藏 Cookie、token、buy_key、sign 等敏感参数；⑦ 可观测性）
    func desensitizedExportText(for parserID: String) -> String {
        let all = lines(for: parserID)
        guard !all.isEmpty else { return "" }
        return all.map { Self.desensitize($0) }.joined(separator: "\n")
    }

    static func desensitize(_ text: String) -> String {
        var out = text
        for regex in sensitivePatterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "$1***")
        }
        return out
    }

    private static let sensitivePatterns: [NSRegularExpression] = {
        let raw = [
            "(1(?:&|%26)_token(?:=|%3[Dd]))[^;\\s&%]+",
            "((?:buy_key|sign|access_token|refresh_token|token|session_id|session|secret|cookie|Authorization)(?:=|%3[Dd]|:\\s*))[^&;\\s\\r\\n]+"
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    // MARK: 磁盘批量刷盘（仅在 ioQueue 执行）

    private func flushPendingToDisk() {
        lock.lock()
        let batch = pendingDiskEntries
        pendingDiskEntries = [:]
        flushScheduled = false
        lock.unlock()

        for (parserID, entries) in batch where !entries.isEmpty {
            Self.appendBatchToDisk(parserID: parserID, entries: entries, maxBytes: maxFileBytes)
        }
    }

    private static func logFileURL(parserID: String) -> URL {
        BuiltinParserStore.directory(for: parserID).appendingPathComponent("parser.log")
    }

    private static func appendBatchToDisk(parserID: String, entries: [String], maxBytes: Int) {
        let url = logFileURL(parserID: parserID)
        let payload = entries.joined(separator: "\n") + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
            let tail = readFromDisk(parserID: parserID)
            writeToDisk(parserID: parserID, lines: Array(tail.suffix(200)))
        }
    }

    private static func readFromDisk(parserID: String) -> [String] {
        let url = logFileURL(parserID: parserID)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func writeToDisk(parserID: String, lines: [String]) {
        let url = logFileURL(parserID: parserID)
        let text = lines.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
