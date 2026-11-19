import Foundation
import JavaScriptCore
import CryptoKit

// MARK: - 内置解析：日志环形缓冲（线程安全，供「查看日志」使用）

final class BuiltinParserLogStore: @unchecked Sendable {
    static let shared = BuiltinParserLogStore()

    private let lock = NSLock()
    private var buffers: [String: [String]] = [:]
    private let capacity = 200

    private init() {}

    func append(_ parserID: String, _ line: String) {
        let stamp = Self.formatter.string(from: Date())
        let entry = "[\(stamp)] \(line)"
        lock.lock()
        var buffer = buffers[parserID] ?? []
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        buffers[parserID] = buffer
        lock.unlock()
        #if DEBUG
        print("[BuiltinParser] \(entry)")
        #endif
    }

    func lines(for parserID: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffers[parserID] ?? []
    }

    func clear(_ parserID: String) {
        lock.lock()
        buffers[parserID] = []
        lock.unlock()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 内置解析：运行时
//
// 职责：
//  1. 扫盘加载已安装解析器（磁盘是唯一数据源，解析路径不依赖 SwiftData）
//  2. 干跑校验（analyze）与安装（install）
//  3. 以独立 JSVirtualMachine 池执行解析脚本（与书源池隔离），带并发闸门 / single-flight / 结果缓存 / 负缓存
//  4. checkStatus 自检
//
// 策略（宿主级，存 UserDefaults：parser_strategy_<parserID>）：
//  fallback（默认）= 官方书源接口优先，仅 VIP 受限错误回退到内置解析
//  always          = 一律优先走内置解析
//  never           = 关闭

actor BuiltinParserRuntime {
    static let shared = BuiltinParserRuntime()

    /// PlayStreamInfo.resolvedBy 的标记值
    static let resolverTag = "builtinParser"

    private struct CachedResolution {
        var stream: PlayStreamInfo
        var expiresAt: Date
    }

    private var installed: [InstalledBuiltinParser] = []
    private var contextPool: [String: [JSContext]] = [:]
    private var contextCount: [String: Int] = [:]
    private var contextWaiters: [String: [CheckedContinuation<JSContext, Never>]] = [:]
    private var cache: [String: CachedResolution] = [:]
    private var negativeCache: [String: Date] = [:]
    private var inflight: [String: Task<PlayStreamInfo, Error>] = [:]

    private var activeSlots = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    /// 全局同时执行的解析脚本上限（与下载并发 3 对齐，避免把共享账号打到限流）
    private let maxConcurrentResolves = 3
    private let maxContextsPerParser = 4
    private let defaultTimeout: TimeInterval = 20.0

    private static let jsQueue = DispatchQueue(label: "com.dsnovel.builtinparser.jsruntime",
                                               qos: .userInitiated,
                                               attributes: .concurrent)

    private static let ximalayaCookieProbe = "https://www.ximalaya.com/"

    // MARK: 加载

    @discardableResult
    func reload() -> [InstalledBuiltinParser] {
        let oldHashes = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0.sha256) })
        installed = BuiltinParserStore.installedParsers()
        let newHashes = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0.sha256) })
        for (id, oldHash) in oldHashes where newHashes[id] != oldHash {
            invalidateParserState(parserID: id)
        }
        for id in contextPool.keys where newHashes[id] == nil {
            invalidateParserState(parserID: id)
        }
        return installed
    }

    private func invalidateParserState(parserID: String) {
        contextPool[parserID] = nil
        contextCount[parserID] = nil
        cache = cache.filter { !$0.key.hasPrefix("\(parserID)|") }
        negativeCache = negativeCache.filter { !$0.key.hasPrefix("\(parserID)|") }
    }

    func installedParsers() -> [InstalledBuiltinParser] {
        if installed.isEmpty {
            installed = BuiltinParserStore.installedParsers()
        }
        return installed
    }

    /// host 匹配优先 + sourceID 兜底（仅匹配已启用的解析器）
    func parser(forSourceID sourceID: String, sourceURL: String) -> InstalledBuiltinParser? {
        if installed.isEmpty {
            installed = BuiltinParserStore.installedParsers()
        }
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

    // MARK: 策略与配置（UserDefaults，与 HostBridge 的 parser pref 前缀一致）

    static func strategyKey(_ parserID: String) -> String { "parser_strategy_\(parserID)" }
    static func enabledKey(_ parserID: String) -> String { "parser_enabled_\(parserID)" }

    func isEnabled(for parserID: String) -> Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey(parserID)) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, for parserID: String) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey(parserID))
    }

    func strategy(for parserID: String) -> BuiltinParserStrategy {
        let raw = UserDefaults.standard.string(forKey: Self.strategyKey(parserID)) ?? ""
        return BuiltinParserStrategy(rawValue: raw) ?? .fallback
    }

    func setStrategy(_ strategy: BuiltinParserStrategy, for parserID: String) {
        UserDefaults.standard.set(strategy.rawValue, forKey: Self.strategyKey(parserID))
    }

    /// 解析脚本自己的配置项，键名与 HostBridge parser 作用域一致：parser_pref_<parserID>.<key>
    nonisolated static func prefKey(_ parserID: String, _ key: String) -> String {
        "parser_pref_\(parserID).\(key)"
    }

    func configValue(parserID: String, key: String) -> String? {
        if let v = UserDefaults.standard.string(forKey: Self.prefKey(parserID, key)), !v.isEmpty {
            return v
        }
        return installedParsers().first { $0.id == parserID }?
            .meta.config.first { $0.key == key }?.defaultValue
    }

    func setConfigValue(parserID: String, key: String, value: String?) {
        if let value, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: Self.prefKey(parserID, key))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.prefKey(parserID, key))
        }
    }

    // MARK: 干跑校验与安装

    /// 在临时上下文里干跑脚本，校验它确实调用了 registerBuiltinParser 并返回元数据
    func analyze(scriptText: String, fileName: String) throws -> BuiltinParserPreview {
        guard let prelude = Self.loadPrelude() else {
            throw BuiltinParserError.invokeFailed("缺少 prelude_parser.js 资源，请重新构建 App")
        }
        let ctx = JSContext(virtualMachine: JSVirtualMachine())!
        JsHostBridge.installParserNative(into: ctx, parserID: "preview", parserName: "preview")
        ctx.evaluateScript(prelude)

        if let exception = ctx.exception {
            throw BuiltinParserError.scriptInvalid("引导脚本异常：\(exception.toString() ?? "unknown")")
        }

        ctx.evaluateScript(scriptText, withSourceURL: URL(string: "parser://preview/\(fileName)"))
        if let exception = ctx.exception {
            let message = exception.toString() ?? "unknown"
            if message.contains("registerSource is not defined") {
                throw BuiltinParserError.scriptInvalid("这是书源脚本（调用 registerSource），请在「书源管理 → 添加书源」里导入")
            }
            throw BuiltinParserError.scriptInvalid(message)
        }

        guard let metaValue = ctx.objectForKeyedSubscript("__metaParser")?.call(withArguments: []),
              let metaJSON = metaValue.toString(),
              let metaData = metaJSON.data(using: .utf8),
              let rawArray = try? JSONSerialization.jsonObject(with: metaData) as? [[String: Any]],
              !rawArray.isEmpty else {
            throw BuiltinParserError.scriptInvalid("脚本未注册内置解析器（未调用 registerBuiltinParser）")
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
        invalidateParserState(parserID: parser.id)
        BuiltinParserLogStore.shared.append(parser.id, "已安装 v\(parser.meta.version)（sha256 \(parser.sha256.prefix(12))）")
        return parser
    }

    func uninstall(parserID: String) throws {
        try BuiltinParserStore.remove(parserID: parserID)
        invalidateParserState(parserID: parserID)
        installed = BuiltinParserStore.installedParsers()
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
            targets: BuiltinParserTargets(hosts: (raw["hosts"] as? [String]) ?? [],
                                          sourceIDs: (raw["sourceIDs"] as? [String]) ?? []),
            supportsPlayback: (raw["supportsPlayback"] as? Bool) ?? true,
            supportsDownload: (raw["supportsDownload"] as? Bool) ?? true,
            requiresCookie: (raw["requiresCookie"] as? Bool) ?? true,
            config: config,
            methods: methods
        )
    }

    private static func loadPrelude() -> String? {
        if let url = Bundle.main.url(forResource: "prelude_parser", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return nil
    }

    // MARK: 解析（播放/下载统一入口）

    func resolve(
        parser: InstalledBuiltinParser,
        sourceID: String,
        episodeURL: String,
        forDownload: Bool
    ) async throws -> PlayStreamInfo {
        let key = try cacheKey(parser: parser, episodeURL: episodeURL, forDownload: forDownload)

        if let cached = cache[key], cached.expiresAt > Date() {
            return cached.stream
        }

        if let until = negativeCache[key], until > Date() {
            throw BuiltinParserError.rejected("rate_limited", "该章节刚刚解析失败，稍后自动重试")
        }

        if let running = inflight[key] {
            return try await running.value
        }

        let task = Task<PlayStreamInfo, Error> { [parser, sourceID, episodeURL, forDownload] in
            try await self.performResolve(parser: parser,
                                          sourceID: sourceID,
                                          episodeURL: episodeURL,
                                          forDownload: forDownload,
                                          cacheKey: key)
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        do {
            let stream = try await task.value
            return stream
        } catch {
            if let parserError = error as? BuiltinParserError, parserError.isRateLimited {
                negativeCache[key] = Date().addingTimeInterval(60)
            }
            throw error
        }
    }

    private func performResolve(
        parser: InstalledBuiltinParser,
        sourceID: String,
        episodeURL: String,
        forDownload: Bool,
        cacheKey key: String
    ) async throws -> PlayStreamInfo {
        let quality = configValue(parserID: parser.id, key: "quality") ?? "M4A_128"
        let defaultTTL = parser.meta.config.first { $0.key == "linkTTL" }.flatMap { Int($0.defaultValue) } ?? 900
        let linkTTL = Int(configValue(parserID: parser.id, key: "linkTTL") ?? "") ?? defaultTTL

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
        let url = (forDownload && !downloadURL.isEmpty) ? downloadURL : plainURL
        guard !url.isEmpty else {
            throw BuiltinParserError.invokeFailed("脚本未返回音频地址")
        }

        var headers: [String: String] = [:]
        if let rawHeaders = dict["headers"] as? [String: Any] {
            for (k, v) in rawHeaders {
                if let s = v as? String, !s.isEmpty { headers[k] = s }
            }
        }

        var kind: StreamKind = .onDemand
        if let kindString = (dict["kind"] as? String)?.lowercased() {
            if kindString.contains("hls") || kindString.contains("m3u8") {
                kind = .hls
            } else if kindString.contains("live") {
                kind = .live
            }
        } else if url.lowercased().contains(".m3u8") {
            kind = .hls
        }

        // 直链有效期：优先用脚本给出的 expiresAt（epoch 秒），再取 TTL 上限
        var expiresAt = Date().addingTimeInterval(TimeInterval(max(linkTTL, 30)))
        if let epoch = (dict["expiresAt"] as? NSNumber)?.doubleValue, epoch > 0 {
            let fromScript = Date(timeIntervalSince1970: epoch)
            if fromScript < expiresAt { expiresAt = fromScript }
        }

        let stream = PlayStreamInfo(url: url, headers: headers, kind: kind,
                                    resolvedBy: Self.resolverTag, expiresAt: expiresAt)
        cache[key] = CachedResolution(stream: stream, expiresAt: expiresAt)
        let cost = Int(Date().timeIntervalSince(started) * 1000)
        BuiltinParserLogStore.shared.append(parser.id, "解析成功（\(cost)ms，\(kind.rawValue)）：\(Self.mask(url))")
        return stream
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
    }

    func cachedExpiry(parserID: String, episodeURL: String) -> Date? {
        cache.first { $0.key.hasPrefix("\(parserID)|") && $0.key.contains("|\(episodeURL)|") }?.value.expiresAt
    }

    // MARK: 脚本执行

    private func evaluate(
        parser: InstalledBuiltinParser,
        method: String,
        argsJSON: String,
        timeout: TimeInterval
    ) async throws -> String? {
        guard let script = BuiltinParserStore.scriptText(for: parser) else {
            throw BuiltinParserError.notInstalled
        }
        guard let prelude = Self.loadPrelude() else {
            throw BuiltinParserError.invokeFailed("缺少 prelude_parser.js 资源")
        }

        try await acquireSlot()
        let ctx: JSContext
        do {
            ctx = try await leaseContext(parser: parser, prelude: prelude, script: script)
        } catch {
            releaseSlot()
            throw error
        }

        let outcome: Result<String?, Error> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String?, Error>, Never>) in
            let gate = OnceContinuationGate { result in
                continuation.resume(returning: result)
            }
            Self.jsQueue.async {
                guard !gate.isDone else { return }
                let index = 0
                let value = ctx.objectForKeyedSubscript("__invokeParserSafe")?
                    .call(withArguments: [index, method, argsJSON])
                if let exception = ctx.exception {
                    gate.finish(.failure(BuiltinParserError.invokeFailed(exception.toString() ?? "unknown")))
                    return
                }
                guard let json = value?.toString() else {
                    gate.finish(.success(nil))
                    return
                }
                // 解析信封 { v } / { e, c, r }
                guard let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    gate.finish(.success(json))
                    return
                }
                if let errMessage = dict["e"] as? String {
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

        releaseSlot()
        if case .failure(let error) = outcome, case BuiltinParserError.timeout = error {
            // 超时的上下文可能仍被卡住的脚本占用：不归还池，直接从计数中移除（下次将新建）
            contextCount[parser.id] = max(0, (contextCount[parser.id] ?? 1) - 1)
            BuiltinParserLogStore.shared.append(parser.id, "执行超时（\(Int(timeout))s），已丢弃该 JSContext")
        } else {
            releaseContext(ctx, parserID: parser.id)
        }
        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: 上下文池

    private func leaseContext(parser: InstalledBuiltinParser, prelude: String, script: String) async throws -> JSContext {
        if var pool = contextPool[parser.id], let ctx = pool.popLast() {
            contextPool[parser.id] = pool
            return ctx
        }
        let created = contextCount[parser.id] ?? 0
        if created < maxContextsPerParser {
            contextCount[parser.id] = created + 1
            if let ctx = Self.makeContext(parser: parser, prelude: prelude, script: script) {
                return ctx
            }
            contextCount[parser.id] = created
            BuiltinParserLogStore.shared.append(parser.id, "创建 JSContext 失败")
            throw BuiltinParserError.scriptInvalid("创建 JSContext 失败")
        }
        // 池已满：等待别人归还
        let ctx = await withCheckedContinuation { (continuation: CheckedContinuation<JSContext, Never>) in
            var waiters = contextWaiters[parser.id] ?? []
            waiters.append(continuation)
            contextWaiters[parser.id] = waiters
        }
        return ctx
    }

    private func releaseContext(_ ctx: JSContext, parserID: String) {
        if var waiters = contextWaiters[parserID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            contextWaiters[parserID] = waiters.isEmpty ? nil : waiters
            next.resume(returning: ctx)
            return
        }
        var pool = contextPool[parserID] ?? []
        pool.append(ctx)
        contextPool[parserID] = pool
    }

    private static func makeContext(parser: InstalledBuiltinParser, prelude: String, script: String) -> JSContext? {
        let ctx = JSContext(virtualMachine: JSVirtualMachine())
        guard let ctx else { return nil }
        ctx.exceptionHandler = { _, exception in
            BuiltinParserLogStore.shared.append(parser.id, "JS 异常：\(exception?.toString() ?? "unknown")")
        }
        JsHostBridge.installParserNative(into: ctx, parserID: parser.id, parserName: parser.meta.name)
        ctx.evaluateScript(prelude)
        ctx.evaluateScript(script, withSourceURL: URL(string: "parser://\(parser.id)/\(parser.fileName)"))
        if let exception = ctx.exception {
            BuiltinParserLogStore.shared.append(parser.id, "脚本加载失败：\(exception.toString() ?? "unknown")")
            return nil
        }
        return ctx
    }

    private func releaseSlot() {
        if let next = slotWaiters.first {
            slotWaiters.removeFirst()
            next.resume()
        } else {
            activeSlots -= 1
        }
    }

    private func acquireSlot() async {
        if activeSlots < maxConcurrentResolves {
            activeSlots += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            slotWaiters.append(continuation)
        }
        activeSlots += 1
    }

    // MARK: 工具

    private func cacheKey(parser: InstalledBuiltinParser, episodeURL: String, forDownload: Bool) throws -> String {
        let cookieSource = configValue(parserID: parser.id, key: "cookieSource") ?? "user"
        let remote = configValue(parserID: parser.id, key: "allowRemoteCookie") ?? "false"
        let quality = configValue(parserID: parser.id, key: "quality") ?? "M4A_128"
        let cookieHeader = CookieSync.cookieHeader(for: URL(string: Self.ximalayaCookieProbe)!)
        let fingerprint = BuiltinParserStore.sha256Hex(Data(cookieHeader.utf8)).prefix(8)
        return "\(parser.id)|\(episodeURL)|\(quality)|\(cookieSource)|\(remote)|\(fingerprint)"
    }

    static func extractTrackID(from episodeURL: String) -> String? {
        let patterns = ["xm:(\\d+)", "trackId=(\\d+)", "track[Ii]d[\"'=:]+(\\d+)", "/(\\d+)/ts-", "^(\\d+)$"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: episodeURL, range: NSRange(episodeURL.startIndex..., in: episodeURL)),
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

// MARK: - 单次续体守护（防止超时与正常返回竞争导致重复 resume）

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
