import Foundation
import JavaScriptCore
import CryptoKit

// MARK: - 内置解析：日志（内存 + 串行异步批量落盘 + 脱敏导出/统计）
//
// 修复 P1-05 / L-04 / P-06：
// - DateFormatter 严格限制在锁内访问，杜绝并发数据竞争
// - 磁盘写入经由独立串行队列防抖批量刷盘（不再每条日志开关文件与 stat），降低 IO 风暴
// - 提供脱敏导出（⑦ 可观测性）与成功率统计

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
    private var buffers: [String: [String]] = [:]
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

    func append(_ parserID: String, _ line: String) {
        lock.lock()
        let stamp = formatter.string(from: Date())
        let entry = "[\(stamp)] \(line)"
        var buffer = buffers[parserID] ?? []
        buffer.append(entry)
        if buffer.count > persistCapacity {
            buffer.removeFirst(buffer.count - persistCapacity)
        }
        buffers[parserID] = buffer

        var pending = pendingDiskEntries[parserID] ?? []
        pending.append(entry)
        pendingDiskEntries[parserID] = pending
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        lock.unlock()

        #if DEBUG
        print("[BuiltinParser] \(entry)")
        #endif

        if shouldSchedule {
            ioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.flushPendingToDisk()
            }
        }
    }

    /// 读取：内存优先；已有缓存或已加载过磁盘时直接返回内存快照，避免阻塞主线程
    func lines(for parserID: String) -> [String] {
        lock.lock()
        let memory = buffers[parserID] ?? []
        let alreadyLoaded = loadedFromDisk.contains(parserID)
        lock.unlock()
        if !memory.isEmpty || alreadyLoaded {
            return Array(memory.suffix(displayCapacity))
        }
        let restored = ioQueue.sync {
            Self.readFromDisk(parserID: parserID)
        }
        lock.lock()
        loadedFromDisk.insert(parserID)
        if (buffers[parserID] ?? []).isEmpty && !restored.isEmpty {
            buffers[parserID] = restored
        }
        let latest = buffers[parserID] ?? restored
        lock.unlock()
        return Array(latest.suffix(displayCapacity))
    }

    /// 供 UI 异步读取日志：冷启动未命中内存缓存时在 ioQueue 异步读盘，不阻塞主线程
    func linesAsync(for parserID: String) async -> [String] {
        lock.lock()
        let memory = buffers[parserID] ?? []
        let alreadyLoaded = loadedFromDisk.contains(parserID)
        lock.unlock()
        if !memory.isEmpty || alreadyLoaded {
            return Array(memory.suffix(displayCapacity))
        }
        let restored: [String] = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: Self.readFromDisk(parserID: parserID))
            }
        }
        lock.lock()
        loadedFromDisk.insert(parserID)
        if (buffers[parserID] ?? []).isEmpty && !restored.isEmpty {
            buffers[parserID] = restored
        }
        let latest = buffers[parserID] ?? restored
        lock.unlock()
        return Array(latest.suffix(displayCapacity))
    }

    func clear(_ parserID: String) {
        lock.lock()
        buffers[parserID] = []
        loadedFromDisk.insert(parserID)
        pendingDiskEntries[parserID] = nil
        lock.unlock()
        ioQueue.async {
            Self.writeToDisk(parserID: parserID, lines: [])
        }
    }

    /// 统计解析成功率与缓存命中（⑦ 可观测性）
    func stats(for parserID: String) -> BuiltinParserLogStats {
        let all = lines(for: parserID)
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

// MARK: - 内置解析：运行时
//
// 职责：
//  1. 扫盘加载已安装解析器（磁盘是唯一数据源，解析路径不依赖 SwiftData）
//  2. 干跑校验（analyze，独立队列 + 超时 + 禁网）与安装（install）
//  3. 以独立 JSVirtualMachine 池执行解析脚本（与书源池隔离），带并发闸门 / single-flight / 结果缓存 / 负缓存
//  4. checkStatus 自检
//
// 链路固定为：解析器优先 → 失败回落官方书源通道 → 都失败返回具体原因。

actor BuiltinParserRuntime {
    static let shared = BuiltinParserRuntime()

    /// PlayStreamInfo.resolvedBy 的标记值
    static let resolverTag = "builtinParser"

    /// 单条缓存同时记录播放流与下载流，避免播放与下载重复解析（P-04）
    private struct CachedResolution {
        var playStream: PlayStreamInfo
        var downloadStream: PlayStreamInfo
        var expiresAt: Date
    }

    private struct NegativeEntry {
        var error: BuiltinParserError
        var expiresAt: Date
    }

    private struct PooledContext {
        var context: JSContext
        var generation: Int
        var lastUsedAt: Date
    }

    private var didLoad = false
    private var installed: [InstalledBuiltinParser] = []
    private var contextPool: [String: [PooledContext]] = [:]
    private var contextCount: [String: Int] = [:]
    private var contextWaiters: [String: [ContextWaiter]] = [:]
    private var parserGeneration: [String: Int] = [:]
    private var cache: [String: CachedResolution] = [:]
    private var negativeCache: [String: NegativeEntry] = [:]
    private var inflight: [String: Task<CachedResolution, Error>] = [:]

    private var activeSlots = 0
    private var slotWaiters: [SlotWaiter] = []

    /// 全局同时执行的解析脚本上限（与下载并发 3 对齐，避免把共享账号打到限流）
    private let maxConcurrentResolves = 3
    /// 单解析器 JSContext 池上限（P-07：降低常驻 VM 内存）
    private let maxContextsPerParser = 2
    /// 空闲 JSContext 回收阈值（P-07：60s）
    private let idleContextTTL: TimeInterval = 60.0
    private let defaultTimeout: TimeInterval = 20.0
    private let analyzeTimeout: TimeInterval = 5.0
    /// 等待并发槽位的最长时间（H-01 防御性兜底）
    static let maxSlotWaitSeconds: TimeInterval = 8.0
    /// 解析结果缓存条数上限
    private let maxCacheEntries = 500
    /// 直链缓存默认 / 上限秒数
    static let defaultLinkTTL = 900
    static let maxLinkTTL = 1800
    /// 等待空闲 JSContext 的最长时间（超时放弃本次解析，避免挂死）
    static let maxContextWaitSeconds: TimeInterval = 12

    private static let jsQueue = DispatchQueue(label: "com.dsnovel.builtinparser.jsruntime",
                                               qos: .userInitiated,
                                               attributes: .concurrent)

    private static let defaultCookieProbe = "https://www.ximalaya.com/"

    /// 静态缓存 prelude_parser.js，避免每次解析重复读盘（P-01）
    private static let cachedPrelude: String? = {
        guard let url = Bundle.main.url(forResource: "prelude_parser", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }()

    /// 预编译章节 ID 提取正则（P-13）
    private static let trackIDRegexes: [NSRegularExpression] = {
        let patterns = [
            "xm:(\\d+)",
            "trackId=(\\d+)",
            "track[Ii]d[\"'=:]+(\\d+)",
            "/(\\d+)/ts-",
            "^(\\d+)$"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // MARK: 加载

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        BuiltinParserStore.cleanupTemporaryDirectories()
        installed = BuiltinParserStore.installedParsers()
    }

    @discardableResult
    func reload() -> [InstalledBuiltinParser] {
        let oldHashes = Dictionary(installed.map { ($0.id, $0.sha256) }, uniquingKeysWith: { _, new in new })
        BuiltinParserStore.cleanupTemporaryDirectories()
        installed = BuiltinParserStore.installedParsers()
        didLoad = true
        let newHashes = Dictionary(installed.map { ($0.id, $0.sha256) }, uniquingKeysWith: { _, new in new })
        for (id, oldHash) in oldHashes where newHashes[id] != oldHash {
            invalidateParserState(parserID: id)
        }
        for id in contextPool.keys where newHashes[id] == nil {
            invalidateParserState(parserID: id)
        }
        return installed
    }

    private func invalidateParserState(parserID: String) {
        parserGeneration[parserID, default: 0] += 1
        contextPool[parserID] = nil
        contextCount[parserID] = nil
        if let waiters = contextWaiters.removeValue(forKey: parserID) {
            for waiter in waiters {
                waiter.resume(throwing: BuiltinParserError.invokeFailed("解析脚本已更新，请重试"))
            }
        }
        cache = cache.filter { !$0.key.hasPrefix("\(parserID)|") }
        negativeCache = negativeCache.filter { !$0.key.hasPrefix("\(parserID)|") }
    }

    func installedParsers() -> [InstalledBuiltinParser] {
        ensureLoaded()
        return installed
    }

    /// 供测试断言并发槽位不变量（H-01）
    func debugActiveSlotCount() -> Int {
        activeSlots
    }

    /// host 匹配优先 + sourceID 兜底（仅匹配已启用的解析器）
    func parser(forSourceID sourceID: String, sourceURL: String) -> InstalledBuiltinParser? {
        ensureLoaded()
        let enabledParsers = installed.filter { isEnabled(for: $0.id) }
        // 1) host 优先
        if let byHost = enabledParsers.first(where: { !$0.meta.targets.hosts.isEmpty && $0.meta.targets.matches(sourceID: sourceID, sourceURL: sourceURL) }) {
            return byHost
        }
        // 2) sourceID 兜底
        return enabledParsers.first { $0.meta.targets.sourceIDs.contains(sourceID) }
    }

    func parser(withID parserID: String) -> InstalledBuiltinParser? {
        installedParsers().first { $0.id == parserID }
    }

    // MARK: 启用与配置（Keychain 托管，键前缀 parser_pref_<parserID>.<key>）

    nonisolated static func enabledKey(_ parserID: String) -> String { "parser_enabled_\(parserID)" }

    func isEnabled(for parserID: String) -> Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey(parserID)) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, for parserID: String) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey(parserID))
    }

    /// 解析脚本自己的配置项，键名与 HostBridge parser 作用域一致：parser_pref_<parserID>.<key>
    nonisolated static func prefKey(_ parserID: String, _ key: String) -> String {
        "parser_pref_\(parserID).\(key)"
    }

    nonisolated static func readConfigValue(parserID: String, key: String, defaultValue: String = "") -> String {
        if let v = BuiltinParserKeychain.string(forKey: prefKey(parserID, key)), !v.isEmpty {
            return v
        }
        return defaultValue
    }

    /// P0-01~03 修复：标记为 nonisolated 并经 Keychain 线程安全写入，避免 SwiftUI 视图同步调用触发 Actor 隔离编译错误
    nonisolated func setConfigValue(parserID: String, key: String, value: String?) {
        BuiltinParserKeychain.set(value, forKey: Self.prefKey(parserID, key))
    }

    // MARK: 干跑校验与安装

    /// 在独立队列与限时沙箱中干跑脚本（H-06：禁网 + 超时丢弃 VM，绝不冻结 Actor）
    func analyze(scriptText: String, fileName: String) async throws -> BuiltinParserPreview {
        guard let prelude = Self.loadPrelude() else {
            throw BuiltinParserError.invokeFailed("缺少 prelude_parser.js 资源，请重新构建 App")
        }
        let timeout = analyzeTimeout

        let rawArray: [[String: Any]] = try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGenericGate<[[String: Any]]> { result in
                continuation.resume(with: result)
            }
            Self.jsQueue.async {
                guard !gate.isDone else { return }
                guard let ctx = JSContext(virtualMachine: JSVirtualMachine()) else {
                    gate.finish(.failure(BuiltinParserError.invokeFailed("无法创建校验沙箱")))
                    return
                }
                // 预览干跑禁网、无 Cookie 权限，防止顶层代码在导入确认前发起网络请求
                JsHostBridge.installParserNative(
                    into: ctx,
                    parserID: "preview",
                    parserName: "preview",
                    allowedHosts: [],
                    allowNetwork: false
                )
                ctx.evaluateScript(prelude)
                if let exception = ctx.exception {
                    gate.finish(.failure(BuiltinParserError.scriptInvalid("引导脚本异常：\(exception.toString() ?? "unknown")")))
                    return
                }
                ctx.evaluateScript(scriptText, withSourceURL: URL(string: "parser://preview/\(fileName)"))
                if let exception = ctx.exception {
                    gate.finish(.failure(BuiltinParserError.scriptInvalid(Self.classifyScriptError(exception.toString() ?? "unknown"))))
                    return
                }
                guard let metaValue = ctx.objectForKeyedSubscript("__metaParser")?.call(withArguments: []),
                      let metaJSON = metaValue.toString(),
                      let metaData = metaJSON.data(using: .utf8),
                      let array = try? JSONSerialization.jsonObject(with: metaData) as? [[String: Any]],
                      !array.isEmpty else {
                    gate.finish(.failure(BuiltinParserError.scriptInvalid("脚本未注册内置解析器（未调用 registerBuiltinParser）")))
                    return
                }
                gate.finish(.success(array))
            }
            Self.jsQueue.asyncAfter(deadline: .now() + timeout) {
                gate.finish(.failure(BuiltinParserError.scriptInvalid("脚本校验超时（可能存在死循环）")))
            }
        }

        let meta = try Self.decodeMeta(rawArray[0])
        let scriptData = Data(scriptText.utf8)
        let sha = BuiltinParserStore.sha256Hex(scriptData)
        let existing = BuiltinParserStore.loadParser(in: BuiltinParserStore.directory(for: meta.id))
        return BuiltinParserPreview(
            meta: meta,
            fileName: fileName,
            sha256: sha,
            sizeBytes: scriptData.count,
            scriptText: scriptText,
            isUpdate: existing != nil,
            installedVersion: existing?.meta.version
        )
    }

    @discardableResult
    func install(preview: BuiltinParserPreview) throws -> InstalledBuiltinParser {
        let parser = try BuiltinParserStore.install(preview: preview)
        installed = BuiltinParserStore.installedParsers()
        didLoad = true
        invalidateParserState(parserID: parser.id)
        BuiltinParserLogStore.shared.append(parser.id, "已安装 v\(parser.meta.version)（sha256 \(parser.sha256.prefix(12))）")
        return parser
    }

    func uninstall(parserID: String) throws {
        try BuiltinParserStore.remove(parserID: parserID)
        invalidateParserState(parserID: parserID)
        installed = BuiltinParserStore.installedParsers()
        didLoad = true
    }

    private static func decodeMeta(_ raw: [String: Any]) throws -> BuiltinParserMeta {
        func stringValue(_ any: Any?) -> String {
            if let s = any as? String { return s }
            if let n = any as? NSNumber { return n.stringValue }
            return ""
        }
        let id = stringValue(raw["id"])
        guard !id.isEmpty else {
            throw BuiltinParserError.scriptInvalid("解析器缺少 id")
        }
        let hosts = (raw["hosts"] as? [String])?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        let sourceIDs = (raw["sourceIDs"] as? [String])?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        guard !hosts.isEmpty || !sourceIDs.isEmpty else {
            throw BuiltinParserError.scriptInvalid("脚本的 targets 未声明有效的 hosts 或 sourceIDs 数组")
        }
        let configRaw = (raw["config"] as? [[String: Any]]) ?? []
        let config = configRaw.map { item in
            BuiltinParserConfigItem(
                key: stringValue(item["key"]),
                title: stringValue(item["title"]),
                defaultValue: stringValue(item["defaultValue"]),
                kind: stringValue(item["kind"]).isEmpty ? "text" : stringValue(item["kind"]),
                options: (item["options"] as? [String]) ?? []
            )
        }
        let methods = Set((raw["methods"] as? [String]) ?? [])
        return BuiltinParserMeta(
            id: id,
            name: stringValue(raw["name"]).isEmpty ? id : stringValue(raw["name"]),
            version: stringValue(raw["version"]),
            author: stringValue(raw["author"]),
            summary: stringValue(raw["summary"]),
            targets: BuiltinParserTargets(hosts: hosts, sourceIDs: sourceIDs),
            supportsPlayback: (raw["supportsPlayback"] as? Bool) ?? true,
            supportsDownload: (raw["supportsDownload"] as? Bool) ?? true,
            requiresCookie: (raw["requiresCookie"] as? Bool) ?? true,
            qualities: Set((raw["qualities"] as? [String]) ?? []),
            config: config,
            methods: methods
        )
    }

    /// 把脚本执行期异常归类成用户能看懂的原因
    nonisolated private static func classifyScriptError(_ raw: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("registerSource is not defined") || message.contains("Can't find variable: registerSource") || message.contains("registerSource") {
            return "这是书源脚本（调用了 registerSource），请在「书源管理 → 添加书源」里导入；内置解析脚本必须调用 registerBuiltinParser"
        }
        if message.contains("必须实现 resolveAudio") {
            return "脚本缺少 resolveAudio(request) 方法，无法返回音频地址"
        }
        if message.contains("必须在 targets 中声明") || message.contains("必须为字符串数组") {
            return "脚本的 targets 未声明有效的目标书源数组（hosts 或 sourceIDs）"
        }
        if message.contains("缺少 id 或 name") {
            return "registerBuiltinParser 缺少 id 或 name"
        }
        if message.isEmpty || message == "unknown" {
            return "脚本执行失败但未给出原因，请确认粘贴的是完整的内置解析脚本"
        }
        return "脚本存在语法或运行错误：\(message)"
    }

    private static func loadPrelude() -> String? {
        cachedPrelude
    }

    // MARK: 解析（播放/下载统一入口）

    func resolve(
        parser: InstalledBuiltinParser,
        sourceID: String,
        episodeURL: String,
        forDownload: Bool,
        qualityCode: String = "high"
    ) async throws -> PlayStreamInfo {
        let key = try cacheKey(parser: parser, episodeURL: episodeURL, qualityCode: qualityCode, forDownload: forDownload)

        if let cached = cache[key], cached.expiresAt > Date() {
            let remain = max(0, Int(cached.expiresAt.timeIntervalSinceNow))
            BuiltinParserLogStore.shared.append(parser.id, "命中解析缓存（直链剩余约 \(remain)s，档位 \(qualityCode)）")
            return forDownload ? cached.downloadStream : cached.playStream
        }

        if let neg = negativeCache[key] {
            if neg.expiresAt > Date() {
                throw neg.error
            } else {
                negativeCache[key] = nil
            }
        }

        if let running = inflight[key] {
            let resolution = try await running.value
            return forDownload ? resolution.downloadStream : resolution.playStream
        }

        let task = Task<CachedResolution, Error> { [parser, sourceID, episodeURL, forDownload, qualityCode] in
            try await self.performResolve(parser: parser,
                                          sourceID: sourceID,
                                          episodeURL: episodeURL,
                                          forDownload: forDownload,
                                          qualityCode: qualityCode,
                                          cacheKey: key)
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        do {
            let resolution = try await task.value
            return forDownload ? resolution.downloadStream : resolution.playStream
        } catch {
            if let parserError = error as? BuiltinParserError,
               let ttl = parserError.negativeCacheTTL {
                negativeCache[key] = NegativeEntry(error: parserError, expiresAt: Date().addingTimeInterval(ttl))
            }
            throw error
        }
    }

    /// 写解析缓存并按容量/过期淘汰（P-16：单次 O(n log n) 裁剪替代循环内 O(n²)）
    private func storeCache(_ key: String, _ value: CachedResolution) {
        cache[key] = value
        guard cache.count > maxCacheEntries else { return }
        let now = Date()
        for (k, v) in cache where v.expiresAt <= now { cache[k] = nil }
        let overflow = cache.count - maxCacheEntries
        guard overflow > 0 else { return }
        let victims = cache.sorted { $0.value.expiresAt < $1.value.expiresAt }.prefix(overflow)
        for (k, _) in victims {
            cache[k] = nil
        }
    }

    private func performResolve(
        parser: InstalledBuiltinParser,
        sourceID: String,
        episodeURL: String,
        forDownload: Bool,
        qualityCode: String,
        cacheKey key: String
    ) async throws -> CachedResolution {
        let quality = qualityCode.isEmpty ? "high" : qualityCode
        let linkTTL = min(max(Self.defaultLinkTTL, 30), Self.maxLinkTTL)

        let request: [String: Any] = [
            "sourceID": sourceID,
            "episodeURL": episodeURL,
            "trackId": Self.extractTrackID(from: episodeURL) ?? "",
            "forDownload": forDownload,
            "quality": quality
        ]
        let argsJSON = try Self.jsonString([request])

        BuiltinParserLogStore.shared.append(parser.id, "resolve \(episodeURL)（\(forDownload ? "下载" : "播放")，音质 \(quality)）")
        let started = Date()
        let raw = try await evaluate(parser: parser, method: "resolveAudio", argsJSON: argsJSON, timeout: defaultTimeout)
        guard let raw, let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuiltinParserError.invokeFailed("脚本未返回有效结果")
        }

        if let reason = dict["reason"] as? String, !reason.isEmpty {
            let message = (dict["message"] as? String) ?? ""
            BuiltinParserLogStore.shared.append(parser.id, "解析失败：\(reason) \(message)")
            throw BuiltinParserError.rejected(reason, message)
        }

        let plainURL = (dict["url"] as? String) ?? ""
        let downloadURL = (dict["downloadUrl"] as? String) ?? ""
        let resolvedPlayURL = !plainURL.isEmpty ? plainURL : downloadURL
        let resolvedDownloadURL = !downloadURL.isEmpty ? downloadURL : plainURL
        guard !resolvedPlayURL.isEmpty else {
            throw BuiltinParserError.invokeFailed("脚本未返回音频地址")
        }

        var headers: [String: String] = [:]
        if let rawHeaders = dict["headers"] as? [String: Any] {
            for (k, v) in rawHeaders {
                if let s = v as? String, !s.isEmpty { headers[k] = s }
            }
        }

        func detectKind(_ u: String) -> StreamKind {
            if let kindString = (dict["kind"] as? String)?.lowercased() {
                if kindString.contains("hls") || kindString.contains("m3u8") { return .hls }
                if kindString.contains("live") { return .live }
            }
            return u.lowercased().contains(".m3u8") ? .hls : .onDemand
        }

        var expiresAt = Date().addingTimeInterval(TimeInterval(max(linkTTL, 30)))
        if let epoch = (dict["expiresAt"] as? NSNumber)?.doubleValue, epoch > 0 {
            let fromScript = Date(timeIntervalSince1970: epoch)
            if fromScript < expiresAt { expiresAt = fromScript }
        }

        let durationSec = (dict["durationSec"] as? NSNumber)?.doubleValue
        let fileSize = (dict["fileSize"] as? NSNumber)?.int64Value
        let isTrial = (dict["isTrial"] as? Bool) ?? false

        let playStream = PlayStreamInfo(
            url: resolvedPlayURL,
            headers: headers,
            kind: detectKind(resolvedPlayURL),
            resolvedBy: Self.resolverTag,
            expiresAt: expiresAt,
            durationSec: durationSec,
            fileSize: fileSize,
            isTrial: isTrial
        )
        let downloadStream = PlayStreamInfo(
            url: resolvedDownloadURL,
            headers: headers,
            kind: detectKind(resolvedDownloadURL),
            resolvedBy: Self.resolverTag,
            expiresAt: expiresAt,
            durationSec: durationSec,
            fileSize: fileSize,
            isTrial: isTrial
        )
        let resolution = CachedResolution(playStream: playStream, downloadStream: downloadStream, expiresAt: expiresAt)
        storeCache(key, resolution)

        let cost = Int(Date().timeIntervalSince(started) * 1000)
        let targetURL = forDownload ? resolvedDownloadURL : resolvedPlayURL
        let actualQuality = (dict["quality"] as? String) ?? quality
        BuiltinParserLogStore.shared.append(parser.id, "解析成功（\(cost)ms，\(actualQuality)）：\(Self.mask(targetURL))")
        return resolution
    }

    /// checkStatus() 自检
    func checkStatus(parserID: String) async throws -> BuiltinParserStatus {
        guard let parser = parser(withID: parserID) ?? BuiltinParserStore.loadParser(in: BuiltinParserStore.directory(for: parserID)) else {
            throw BuiltinParserError.notInstalled
        }
        let started = Date()
        let raw = try await evaluate(parser: parser, method: "checkStatus", argsJSON: "[]", timeout: 15)
        let cost = Int(Date().timeIntervalSince(started) * 1000)
        guard let raw, let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuiltinParserError.invokeFailed("自检未返回结果")
        }
        if let reason = dict["reason"] as? String, !reason.isEmpty {
            throw BuiltinParserError.rejected(reason, (dict["message"] as? String) ?? "")
        }
        let status = BuiltinParserStatus(
            ok: (dict["ok"] as? Bool) ?? false,
            message: (dict["message"] as? String) ?? "",
            latencyMs: (dict["latencyMs"] as? NSNumber)?.intValue ?? cost,
            nickname: (dict["nickname"] as? String) ?? "",
            vipExpireAt: (dict["vipExpireAt"] as? String) ?? ""
        )
        BuiltinParserLogStore.shared.append(parser.id, "自检：\(status.ok ? "通过" : "失败") \(status.message)（\(status.latencyMs)ms）")
        return status
    }

    func invalidateCache(parserID: String? = nil, episodeURL: String? = nil) {
        for key in cache.keys {
            if let parserID, !key.hasPrefix("\(parserID)|") { continue }
            if let episodeURL, !key.contains("|\(episodeURL)|") { continue }
            cache[key] = nil
        }
        for key in negativeCache.keys {
            if let parserID, !key.hasPrefix("\(parserID)|") { continue }
            if let episodeURL, !key.contains("|\(episodeURL)|") { continue }
            negativeCache[key] = nil
        }
    }

    // MARK: 脚本执行

    private func evaluate(
        parser: InstalledBuiltinParser,
        method: String,
        argsJSON: String,
        timeout: TimeInterval
    ) async throws -> String? {
        try await acquireSlot()
        let leased: (ctx: JSContext, generation: Int)
        do {
            leased = try await leaseContext(parser: parser)
        } catch {
            releaseSlot()
            throw error
        }
        let ctx = leased.ctx
        let generation = leased.generation

        let gateBox = OnceGateBox()
        let outcome: Result<String?, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<String?, Error>, Never>) in
                let gate = OnceContinuationGate { result in
                    continuation.resume(returning: result)
                }
                gateBox.set(gate)
                if Task.isCancelled {
                    gate.finish(.failure(CancellationError()))
                    return
                }
                Self.jsQueue.async {
                    guard !gate.isDone else { return }
                    ctx.exception = nil
                    let index = 0
                    let value = ctx.objectForKeyedSubscript("__invokeParserSafe")?
                        .call(withArguments: [index, method, argsJSON])
                    if let exception = ctx.exception {
                        ctx.exception = nil
                        gate.finish(.failure(BuiltinParserError.invokeFailed(exception.toString() ?? "unknown")))
                        return
                    }
                    guard let json = value?.toString() else {
                        gate.finish(.success(nil))
                        return
                    }
                    guard let data = json.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        gate.finish(.success(json))
                        return
                    }
                    if let errMessage = dict["e"] as? String {
                        if (dict["c"] as? Bool) == true {
                            gate.finish(.failure(CancellationError()))
                            return
                        }
                        let reason = (dict["r"] as? String) ?? ""
                        if !reason.isEmpty {
                            gate.finish(.failure(BuiltinParserError.rejected(reason, errMessage)))
                        } else {
                            gate.finish(.failure(BuiltinParserError.invokeFailed(errMessage)))
                        }
                        return
                    }
                    gate.finish(.success(dict["v"] as? String))
                }
                Self.jsQueue.asyncAfter(deadline: .now() + timeout) {
                    gate.finish(.failure(BuiltinParserError.timeout))
                }
            }
        } onCancel: {
            // M-02：Task 取消（如切章/取消下载）立即唤醒等待者并释放并发槽位
            gateBox.cancel()
        }

        releaseSlot()
        let shouldDiscard: Bool
        if case .failure(let error) = outcome {
            if case BuiltinParserError.timeout = error {
                shouldDiscard = true
            } else if error is CancellationError {
                shouldDiscard = true
            } else {
                shouldDiscard = false
            }
        } else {
            shouldDiscard = false
        }

        if shouldDiscard {
            await discardContext(parser: parser, generation: generation)
            if case .failure(let error) = outcome, case BuiltinParserError.timeout = error {
                BuiltinParserLogStore.shared.append(parser.id, "执行超时（\(Int(timeout))s），已丢弃该 JSContext")
            }
        } else {
            releaseContext(ctx, parserID: parser.id, generation: generation)
        }

        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: 上下文池

    private func pruneIdleContexts(parserID: String) {
        guard var pool = contextPool[parserID], !pool.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-idleContextTTL)
        let before = pool.count
        pool.removeAll { $0.lastUsedAt < cutoff }
        let removed = before - pool.count
        if removed > 0 {
            contextPool[parserID] = pool.isEmpty ? nil : pool
            contextCount[parserID] = max(0, (contextCount[parserID] ?? removed) - removed)
        }
    }

    private func leaseContext(parser: InstalledBuiltinParser) async throws -> (ctx: JSContext, generation: Int) {
        pruneIdleContexts(parserID: parser.id)
        let currentGen = parserGeneration[parser.id] ?? 0

        if var pool = contextPool[parser.id] {
            while let entry = pool.popLast() {
                if entry.generation == currentGen {
                    contextPool[parser.id] = pool.isEmpty ? nil : pool
                    return (entry.context, entry.generation)
                }
                // 旧世代上下文直接丢弃并归还计数
                contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
            }
            contextPool[parser.id] = nil
        }

        let created = contextCount[parser.id] ?? 0
        if created < maxContextsPerParser {
            contextCount[parser.id] = created + 1
            // P-01：仅新建 context 时才读盘加载脚本；P1-06：JS 编译移至 jsQueue 避免阻塞协作线程池
            guard let prelude = Self.loadPrelude() else {
                contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
                throw BuiltinParserError.invokeFailed("缺少 prelude_parser.js 资源")
            }
            guard let script = BuiltinParserStore.scriptText(for: parser) else {
                contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
                throw BuiltinParserError.notInstalled
            }
            let ctx = await Self.makeContextAsync(parser: parser, prelude: prelude, script: script)
            // 二次校验世代：若创建期间脚本已更新/卸载，直接丢弃且不改动新世代 contextCount
            guard (parserGeneration[parser.id] ?? 0) == currentGen else {
                throw BuiltinParserError.invokeFailed("解析脚本已更新，请重试")
            }
            if let ctx {
                return (ctx, currentGen)
            }
            contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
            BuiltinParserLogStore.shared.append(parser.id, "创建 JSContext 失败")
            throw BuiltinParserError.scriptInvalid("创建 JSContext 失败")
        }

        // 池已满：等待别人归还（带 deadline，避免永久挂起）
        BuiltinParserLogStore.shared.append(parser.id, "JSContext 池已满，等待空闲上下文…")
        let ctx = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSContext, Error>) in
            let waiter = ContextWaiter(continuation)
            var waiters = contextWaiters[parser.id] ?? []
            waiters.append(waiter)
            contextWaiters[parser.id] = waiters
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.maxContextWaitSeconds) { [weak self] in
                guard let self else { return }
                Task { await self.expireWaiter(waiter, parserID: parser.id) }
            }
        }
        return (ctx, parserGeneration[parser.id] ?? currentGen)
    }

    private func expireWaiter(_ waiter: ContextWaiter, parserID: String) {
        guard var waiters = contextWaiters[parserID],
              let idx = waiters.firstIndex(where: { $0 === waiter }) else { return }
        waiters.remove(at: idx)
        contextWaiters[parserID] = waiters.isEmpty ? nil : waiters
        BuiltinParserLogStore.shared.append(parserID, "等待 JSContext 超时（\(Int(Self.maxContextWaitSeconds))s），放弃本次解析")
        waiter.resume(throwing: BuiltinParserError.timeout)
    }

    /// 超时/取消丢弃上下文时唤醒队首等待者，避免池名额腾出后等待者空等（M-01 / P1-06）
    private func discardContext(parser: InstalledBuiltinParser, generation: Int) async {
        let currentGen = parserGeneration[parser.id] ?? 0
        guard generation == currentGen else { return }
        contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)

        guard var waiters = contextWaiters[parser.id], !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        contextWaiters[parser.id] = waiters.isEmpty ? nil : waiters

        contextCount[parser.id] = (contextCount[parser.id] ?? 0) + 1
        let fresh: JSContext?
        if let prelude = Self.loadPrelude(),
           let script = BuiltinParserStore.scriptText(for: parser) {
            fresh = await Self.makeContextAsync(parser: parser, prelude: prelude, script: script)
        } else {
            fresh = nil
        }

        // 二次校验世代：若重建期间脚本已更新/卸载，直接丢弃且不修改新世代 contextCount
        guard (parserGeneration[parser.id] ?? 0) == currentGen else {
            _ = next.resume(throwing: BuiltinParserError.invokeFailed("解析脚本已更新，请重试"))
            return
        }

        guard let fresh else {
            contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
            _ = next.resume(throwing: BuiltinParserError.scriptInvalid("重建 JSContext 失败"))
            return
        }

        if next.resume(returning: fresh) {
            return
        }
        // 等待者已超时：尝试转交后续等待者，否则归还到空闲池保持 contextCount 守恒
        releaseContext(fresh, parserID: parser.id, generation: currentGen)
    }

    private func releaseContext(_ ctx: JSContext, parserID: String, generation: Int) {
        let currentGen = parserGeneration[parserID] ?? 0
        guard generation == currentGen else {
            // 归还时脚本已更新：直接丢弃，不污染新世代池
            return
        }
        while var waiters = contextWaiters[parserID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            contextWaiters[parserID] = waiters.isEmpty ? nil : waiters
            if next.resume(returning: ctx) {
                return
            }
        }
        var pool = contextPool[parserID] ?? []
        pool.append(PooledContext(context: ctx, generation: generation, lastUsedAt: Date()))
        contextPool[parserID] = pool
    }

    private static func makeContextAsync(parser: InstalledBuiltinParser, prelude: String, script: String) async -> JSContext? {
        await withCheckedContinuation { continuation in
            Self.jsQueue.async {
                let ctx = Self.makeContext(parser: parser, prelude: prelude, script: script)
                continuation.resume(returning: ctx)
            }
        }
    }

    private static func makeContext(parser: InstalledBuiltinParser, prelude: String, script: String) -> JSContext? {
        let ctx = JSContext(virtualMachine: JSVirtualMachine())
        guard let ctx else { return nil }
        ctx.exceptionHandler = { _, exception in
            BuiltinParserLogStore.shared.append(parser.id, "JS 异常：\(exception?.toString() ?? "unknown")")
        }
        // H-06：按脚本声明的目标 hosts 收敛宿主桥域名权限（保留远端共享 Cookie 所需域名）
        JsHostBridge.installParserNative(
            into: ctx,
            parserID: parser.id,
            parserName: parser.meta.name,
            allowedHosts: parser.meta.targets.hosts,
            allowNetwork: true
        )
        ctx.evaluateScript(prelude)
        ctx.evaluateScript(script, withSourceURL: URL(string: "parser://\(parser.id)/\(parser.fileName)"))
        if let exception = ctx.exception {
            ctx.exception = nil
            BuiltinParserLogStore.shared.append(parser.id, "脚本加载失败：\(exception.toString() ?? "unknown")")
            return nil
        }
        return ctx
    }

    // MARK: 并发槽位闸门（修复 P0-05 / H-01 永久泄漏死锁 + 等待超时保护）

    private func releaseSlot() {
        while !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            if next.resumeIfNeeded(returning: ()) {
                // 槽位直接移交给被唤醒的等待者，activeSlots 保持不变
                return
            }
        }
        activeSlots = max(0, activeSlots - 1)
    }

    private func acquireSlot() async throws {
        if activeSlots < maxConcurrentResolves {
            activeSlots += 1
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waiter = SlotWaiter(continuation)
            slotWaiters.append(waiter)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.maxSlotWaitSeconds) { [weak self] in
                guard let self else { return }
                Task { await self.expireSlotWaiter(waiter) }
            }
        }
        // P0-05 / H-01 修复：槽位已由 releaseSlot 直接移交，绝不再执行 activeSlots += 1
    }

    private func expireSlotWaiter(_ waiter: SlotWaiter) {
        if let idx = slotWaiters.firstIndex(where: { $0 === waiter }) {
            slotWaiters.remove(at: idx)
        }
        _ = waiter.resumeIfNeeded(throwing: BuiltinParserError.timeout)
    }

    // MARK: 工具

    /// 缓存键：解析器 + 章节 + 音质档 + 动态目标域 Cookie 指纹（P1-10 + P-04）
    private func cacheKey(
        parser: InstalledBuiltinParser,
        episodeURL: String,
        qualityCode: String,
        forDownload: Bool
    ) throws -> String {
        let probeURL: URL
        if let firstHost = parser.meta.targets.hosts.first, !firstHost.isEmpty,
           let dynamicURL = URL(string: "https://\(firstHost)/") {
            probeURL = dynamicURL
        } else {
            probeURL = URL(string: Self.defaultCookieProbe)!
        }
        let cookieHeader = CookieSync.cookieHeader(for: probeURL)
        let fingerprint = BuiltinParserStore.sha256Hex(Data(cookieHeader.utf8)).prefix(8)
        return "\(parser.id)|\(episodeURL)|\(qualityCode)|\(fingerprint)::\(forDownload ? "dl" : "play")"
    }

    static func extractTrackID(from episodeURL: String) -> String? {
        let nsRange = NSRange(episodeURL.startIndex..., in: episodeURL)
        for regex in trackIDRegexes {
            if let match = regex.firstMatch(in: episodeURL, range: nsRange),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: episodeURL) {
                return String(episodeURL[range])
            }
        }
        return nil
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private static func mask(_ url: String) -> String {
        guard url.count > 48 else { return url }
        return String(url.prefix(40)) + "…"
    }
}

// MARK: - 单次续体守护（防止超时、取消与正常返回竞争导致重复 resume）

final class OnceContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let onFinish: (Result<String?, Error>) -> Void

    init(onFinish: @escaping (Result<String?, Error>) -> Void) {
        self.onFinish = onFinish
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func finish(_ result: Result<String?, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        onFinish(result)
    }
}

private final class OnceGenericGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let onFinish: (Result<Value, Error>) -> Void

    init(onFinish: @escaping (Result<Value, Error>) -> Void) {
        self.onFinish = onFinish
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        onFinish(result)
    }
}

private final class OnceGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: OnceContinuationGate?
    private var cancelledBeforeSet = false

    func set(_ gate: OnceContinuationGate) {
        lock.lock()
        self.gate = gate
        let shouldCancel = cancelledBeforeSet
        lock.unlock()
        if shouldCancel {
            gate.finish(.failure(CancellationError()))
        }
    }

    func cancel() {
        lock.lock()
        let current = gate
        if current == nil { cancelledBeforeSet = true }
        lock.unlock()
        current?.finish(.failure(CancellationError()))
    }
}

/// 池满时排队等待空闲 JSContext 的单次续体句柄（支持被正常归还或超时任一方先唤醒）
private final class ContextWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSContext, Error>?

    init(_ continuation: CheckedContinuation<JSContext, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning ctx: JSContext) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(returning: ctx)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(throwing: error)
        return true
    }
}

/// 并发槽位排队句柄（支持被 releaseSlot 或超时任一方先唤醒）
private final class SlotWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resumeIfNeeded(returning value: Void) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(returning: value)
        return true
    }

    @discardableResult
    func resumeIfNeeded(throwing error: Error) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(throwing: error)
        return true
    }
}
