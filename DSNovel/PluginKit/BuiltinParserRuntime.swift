import Foundation
import JavaScriptCore
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

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
    private struct InflightEntry {
        let id: UUID
        let task: Task<CachedResolution, Error>
        var waiters: Set<UUID>
        var continuations: [UUID: InflightWaiter<CachedResolution>]
    }

    private var cache: [String: CachedResolution] = [:]
    private var negativeCache: [String: NegativeEntry] = [:]
    private var inflight: [String: InflightEntry] = [:]

    private var activeSlots = 0
    private var slotWaiters: [SlotWaiter] = []
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    init() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleMemoryWarning() }
        }
        #endif
    }

    /// P8：收到系统内存警告时立即释放全部空闲 JSContext 池并裁剪过期缓存
    func handleMemoryWarning() {
        for (parserID, pool) in contextPool {
            let removed = pool.count
            contextPool[parserID] = nil
            contextCount[parserID] = max(0, (contextCount[parserID] ?? removed) - removed)
        }
        let now = Date()
        cache = cache.filter { $0.value.expiresAt > now }
        negativeCache = negativeCache.filter { $0.value.expiresAt > now }
    }

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
                // M-P0-7：预览干跑禁网、无 Cookie 与 pref/cache 读写权限，且使用随机隔离命名空间
                let previewID = "preview-\(UUID().uuidString.prefix(8))"
                JsHostBridge.installParserNative(
                    into: ctx,
                    parserID: previewID,
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

    /// P6：按播放/下载场景从共享缓存提取可用流；若下载流不可用（如空地址或直播流）返回 nil 触发回落重解析
    private func usableStream(from resolution: CachedResolution, forDownload: Bool) -> PlayStreamInfo? {
        if forDownload {
            let stream = resolution.downloadStream
            guard !stream.url.isEmpty, stream.kind != .live else { return nil }
            return stream
        } else {
            guard !resolution.playStream.url.isEmpty else { return nil }
            return resolution.playStream
        }
    }

    func resolve(
        parser: InstalledBuiltinParser,
        sourceID: String,
        episodeURL: String,
        forDownload: Bool,
        qualityCode: String = "high"
    ) async throws -> PlayStreamInfo {
        try Task.checkCancellation()
        let key = try cacheKey(parser: parser, episodeURL: episodeURL, qualityCode: qualityCode)

        if let cached = cache[key], cached.expiresAt > Date(),
           let stream = usableStream(from: cached, forDownload: forDownload) {
            let remain = max(0, Int(cached.expiresAt.timeIntervalSinceNow))
            BuiltinParserLogStore.shared.append(parser.id, "命中解析缓存（直链剩余约 \(remain)s，档位 \(qualityCode)）")
            return stream
        }

        if let neg = negativeCache[key] {
            if neg.expiresAt > Date() {
                throw neg.error
            } else {
                negativeCache[key] = nil
            }
        }

        if inflight[key] != nil {
            let resolution = try await awaitInflight(key: key)
            if let stream = usableStream(from: resolution, forDownload: forDownload) {
                return stream
            }
        }

        let resolution = try await startOrJoinInflight(
            key: key,
            parser: parser,
            sourceID: sourceID,
            episodeURL: episodeURL,
            forDownload: forDownload,
            qualityCode: qualityCode
        )
        return forDownload ? resolution.downloadStream : resolution.playStream
    }

    /// S1：加入已有的 single-flight 任务，支持按等待者引用计数传播取消
    private func awaitInflight(key: String) async throws -> CachedResolution {
        try Task.checkCancellation()
        guard var entry = inflight[key] else {
            throw CancellationError()
        }
        let waiter = InflightWaiter<CachedResolution>()
        let waiterID = waiter.id
        let entryID = entry.id
        entry.waiters.insert(waiterID)
        entry.continuations[waiterID] = waiter
        inflight[key] = entry

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.attach(continuation)
            }
        } onCancel: {
            Task {
                await self.cancelInflightWaiter(key: key, entryID: entryID, waiterID: waiterID)
            }
        }
    }

    /// S1：创建或复用 single-flight 任务，并通过 waiters 引用计数保证最后等待者取消时立即取消底层 Task
    private func startOrJoinInflight(
        key: String,
        parser: InstalledBuiltinParser,
        sourceID: String,
        episodeURL: String,
        forDownload: Bool,
        qualityCode: String
    ) async throws -> CachedResolution {
        try Task.checkCancellation()
        if inflight[key] != nil {
            return try await awaitInflight(key: key)
        }

        let entryID = UUID()
        let waiter = InflightWaiter<CachedResolution>()
        let waiterID = waiter.id

        let task = Task<CachedResolution, Error> { [parser, sourceID, episodeURL, forDownload, qualityCode] in
            do {
                let res = try await self.performResolve(
                    parser: parser,
                    sourceID: sourceID,
                    episodeURL: episodeURL,
                    forDownload: forDownload,
                    qualityCode: qualityCode,
                    cacheKey: key
                )
                await self.finishInflight(key: key, entryID: entryID, result: .success(res))
                return res
            } catch {
                await self.finishInflight(key: key, entryID: entryID, result: .failure(error))
                throw error
            }
        }

        inflight[key] = InflightEntry(
            id: entryID,
            task: task,
            waiters: [waiterID],
            continuations: [waiterID: waiter]
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.attach(continuation)
            }
        } onCancel: {
            Task {
                await self.cancelInflightWaiter(key: key, entryID: entryID, waiterID: waiterID)
            }
        }
    }

    private func finishInflight(key: String, entryID: UUID, result: Result<CachedResolution, Error>) {
        if case .failure(let error) = result,
           let parserError = error as? BuiltinParserError,
           let ttl = parserError.negativeCacheTTL {
            negativeCache[key] = NegativeEntry(error: parserError, expiresAt: Date().addingTimeInterval(ttl))
        }
        guard let entry = inflight[key], entry.id == entryID else { return }
        inflight.removeValue(forKey: key)
        for waiter in entry.continuations.values {
            waiter.resume(with: result)
        }
    }

    private func cancelInflightWaiter(key: String, entryID: UUID, waiterID: UUID) async {
        guard var entry = inflight[key], entry.id == entryID else { return }
        entry.waiters.remove(waiterID)
        let waiter = entry.continuations.removeValue(forKey: waiterID)
        if entry.waiters.isEmpty {
            inflight.removeValue(forKey: key)
            entry.task.cancel()
            // 等待底层任务响应取消并完成槽位释放后唤醒最后一个等待者
            _ = await entry.task.result
            waiter?.resume(with: .failure(CancellationError()))
        } else {
            inflight[key] = entry
            waiter?.resume(with: .failure(CancellationError()))
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
        let actualLevel = (dict["actualLevel"] as? NSNumber)?.intValue
        let capped = dict["capped"] as? Bool
        let tierName = dict["tierName"] as? String
        let measuredKbps = (dict["measuredKbps"] as? NSNumber)?.intValue

        let playStream = PlayStreamInfo(
            url: resolvedPlayURL,
            headers: headers,
            kind: detectKind(resolvedPlayURL),
            resolvedBy: Self.resolverTag,
            expiresAt: expiresAt,
            durationSec: durationSec,
            fileSize: fileSize,
            isTrial: isTrial,
            actualLevel: actualLevel,
            capped: capped,
            tierName: tierName,
            measuredKbps: measuredKbps
        )
        let downloadStream = PlayStreamInfo(
            url: resolvedDownloadURL,
            headers: headers,
            kind: detectKind(resolvedDownloadURL),
            resolvedBy: Self.resolverTag,
            expiresAt: expiresAt,
            durationSec: durationSec,
            fileSize: fileSize,
            isTrial: isTrial,
            actualLevel: actualLevel,
            capped: capped,
            tierName: tierName,
            measuredKbps: measuredKbps
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

        let gateBox = OnceGateBox(context: ctx)
        let timeoutWork = DispatchWorkItem {
            // P6：超时立即中止底层挂起的网络请求并唤醒等待者
            gateBox.timeout()
        }
        let outcome: Result<String?, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<String?, Error>, Never>) in
                let gate = OnceContinuationGate { result in
                    continuation.resume(returning: result)
                }
                gateBox.set(gate)
                if Task.isCancelled {
                    gateBox.cancel()
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
                Self.jsQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            // M-02 + P6：Task 取消（如切章/取消下载）立即中止底层 HTTP 请求、唤醒等待者并释放并发槽位
            gateBox.cancel()
        }
        timeoutWork.cancel()
        gateBox.detachContext()

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
        try Task.checkCancellation()
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
            if Task.isCancelled {
                if let ctx {
                    releaseContext(ctx, parserID: parser.id, generation: currentGen)
                } else {
                    contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
                }
                throw CancellationError()
            }
            if let ctx {
                return (ctx, currentGen)
            }
            contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
            BuiltinParserLogStore.shared.append(parser.id, "创建 JSContext 失败")
            throw BuiltinParserError.scriptInvalid("创建 JSContext 失败")
        }

        // 池已满：等待别人归还（9-4：接入 withTaskCancellationHandler，上层取消立即退出并释放并发槽位）
        try Task.checkCancellation()
        BuiltinParserLogStore.shared.append(parser.id, "JSContext 池已满，等待空闲上下文…")
        let waiter = ContextWaiter()
        let ctx = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSContext, Error>) in
                if waiter.attach(continuation) {
                    var waiters = contextWaiters[parser.id] ?? []
                    waiters.append(waiter)
                    contextWaiters[parser.id] = waiters
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.maxContextWaitSeconds) { [weak self] in
                        guard let self else { return }
                        Task { await self.expireWaiter(waiter, parserID: parser.id) }
                    }
                }
            }
        } onCancel: {
            _ = waiter.resume(throwing: CancellationError())
            Task { await self.cancelContextWaiter(waiter, parserID: parser.id) }
        }
        return (ctx, parserGeneration[parser.id] ?? currentGen)
    }

    private func expireWaiter(_ waiter: ContextWaiter, parserID: String) {
        if var waiters = contextWaiters[parserID],
           let idx = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: idx)
            contextWaiters[parserID] = waiters.isEmpty ? nil : waiters
        }
        if waiter.resume(throwing: BuiltinParserError.timeout) {
            BuiltinParserLogStore.shared.append(parserID, "等待 JSContext 超时（\(Int(Self.maxContextWaitSeconds))s），放弃本次解析")
        }
    }

    private func cancelContextWaiter(_ waiter: ContextWaiter, parserID: String) {
        if var waiters = contextWaiters[parserID],
           let idx = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: idx)
            contextWaiters[parserID] = waiters.isEmpty ? nil : waiters
        }
        _ = waiter.resume(throwing: CancellationError())
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
        try Task.checkCancellation()
        if activeSlots < maxConcurrentResolves {
            activeSlots += 1
            return
        }
        let waiter = SlotWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if waiter.attach(continuation) {
                    slotWaiters.append(waiter)
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.maxSlotWaitSeconds) { [weak self] in
                        guard let self else { return }
                        Task { await self.expireSlotWaiter(waiter) }
                    }
                }
            }
        } onCancel: {
            _ = waiter.resumeIfNeeded(throwing: CancellationError())
            Task { await self.cancelSlotWaiter(waiter) }
        }
        // P0-05 / H-01 修复：槽位已由 releaseSlot 直接移交，绝不再执行 activeSlots += 1
    }

    private func expireSlotWaiter(_ waiter: SlotWaiter) {
        if let idx = slotWaiters.firstIndex(where: { $0 === waiter }) {
            slotWaiters.remove(at: idx)
        }
        _ = waiter.resumeIfNeeded(throwing: BuiltinParserError.timeout)
    }

    private func cancelSlotWaiter(_ waiter: SlotWaiter) {
        if let idx = slotWaiters.firstIndex(where: { $0 === waiter }) {
            slotWaiters.remove(at: idx)
        }
        _ = waiter.resumeIfNeeded(throwing: CancellationError())
    }

    // MARK: 工具

    /// 缓存键：解析器 + 章节 + 音质档 + 动态目标域 Cookie 指纹（P1-10 + P-04 + P6 播下共享）
    private func cacheKey(
        parser: InstalledBuiltinParser,
        episodeURL: String,
        qualityCode: String
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
        return "\(parser.id)|\(episodeURL)|\(qualityCode)|\(fingerprint)"
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
    private var context: JSContext?
    private var abortedError: Error?

    init(context: JSContext? = nil) {
        self.context = context
    }

    func set(_ gate: OnceContinuationGate) {
        lock.lock()
        self.gate = gate
        let pendingError = abortedError
        let ctx = pendingError != nil ? context : nil
        if pendingError != nil {
            context = nil
        }
        lock.unlock()
        if let pendingError {
            if let ctx {
                JsHostBridge.cancelActiveTasks(for: ctx)
            }
            gate.finish(.failure(pendingError))
        }
    }

    func detachContext() {
        lock.lock()
        context = nil
        lock.unlock()
    }

    func cancel() {
        abort(with: CancellationError())
    }

    func timeout() {
        abort(with: BuiltinParserError.timeout)
    }

    private func abort(with error: Error) {
        lock.lock()
        let current = gate
        if current?.isDone == true {
            context = nil
            lock.unlock()
            return
        }
        if abortedError == nil {
            abortedError = error
        }
        let ctx = context
        context = nil
        lock.unlock()
        if let ctx {
            JsHostBridge.cancelActiveTasks(for: ctx)
        }
        current?.finish(.failure(error))
    }
}

/// 池满时排队等待空闲 JSContext 的单次续体句柄（9-4：支持先取消后挂载、归还/取消/超时互斥单次唤醒）
private final class ContextWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSContext, Error>?
    private var pendingResult: Result<JSContext, Error>?
    private var isFinished = false

    init() {}

    @discardableResult
    func attach(_ continuation: CheckedContinuation<JSContext, Error>) -> Bool {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            isFinished = true
            lock.unlock()
            continuation.resume(with: pending)
            return false
        }
        if isFinished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    func resume(returning ctx: JSContext) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: ctx)
            return true
        }
        pendingResult = .success(ctx)
        lock.unlock()
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(throwing: error)
            return true
        }
        pendingResult = .failure(error)
        lock.unlock()
        return true
    }
}

/// S1：single-flight 等待者单次续体句柄（支持先取消后挂载、正常完成与取消竞争互斥）
private final class InflightWaiter<Value>: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isFinished = false

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            isFinished = true
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        if isFinished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(with: result)
            return true
        }
        pendingResult = result
        lock.unlock()
        return true
    }
}

/// 并发槽位排队句柄（支持被 releaseSlot、取消或超时任一方先唤醒，严格单次终态防泄漏）
private final class SlotWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var isFinished = false

    init() {}

    @discardableResult
    func attach(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            isFinished = true
            lock.unlock()
            continuation.resume(with: pending)
            return false
        }
        if isFinished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    func resumeIfNeeded(returning value: Void) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: value)
            return true
        }
        pendingResult = .success(value)
        lock.unlock()
        return true
    }

    @discardableResult
    func resumeIfNeeded(throwing error: Error) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(throwing: error)
            return true
        }
        pendingResult = .failure(error)
        lock.unlock()
        return true
    }
}
