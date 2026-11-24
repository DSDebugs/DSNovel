import DSCore
import Foundation
import JavaScriptCore

/// 内置解析器引擎（独立于书源、成对原子写入/回滚 script.js + meta.json、强制 hosts 白名单与固定串行队列池）
public actor BuiltinParserEngine {
    internal let preludeParserScript: String
    internal let storageDir: URL
    internal let httpClient: HostHTTPClient
    internal let cookieVault: CookieVault
    internal let logger: DSDiagnosticLogStore
    internal let webViewService: HeadlessWebViewService
    internal let pool: JSContextPool
    internal let playbackPool = JSContextPool(maxSlots: 1, labelPrefix: "com.dsnovel.v3.parser.playback")

    internal var installedParsers: [String: BuiltinParserMetaDTO] = [:]
    internal var cachedScriptBodies: [String: String] = [:]
    internal struct EngineLogItem: Sendable {
        let timestamp: Date
        let text: String
    }
    internal var incrementalLogs: [EngineLogItem] = []
    internal var logsClearedAt: Date?

    public init(
        preludeParserScript: String,
        storageDir: URL,
        httpClient: HostHTTPClient,
        cookieVault: CookieVault,
        logger: DSDiagnosticLogStore,
        webViewService: HeadlessWebViewService = HeadlessWebViewService(),
        pool: JSContextPool = JSContextPool(maxSlots: 2, labelPrefix: "com.dsnovel.v3.parser.js")
    ) {
        self.preludeParserScript = preludeParserScript
        self.storageDir = storageDir
        self.httpClient = httpClient
        self.cookieVault = cookieVault
        self.logger = logger
        self.webViewService = webViewService
        self.pool = pool
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    /// 原子安装或升级内置解析器（固定串行队列池 + prelude 后立即删除 __bridge + 5s 可取消超时）
    public func installParser(scriptBody: String) async throws -> BuiltinParserMetaDTO {
        let lease = try await pool.acquireLease()
        let prelude = preludeParserScript
        let client = httpClient
        let vault = cookieVault
        let previewCacheRoot = FileManager.default.temporaryDirectory
        let logStore = logger
        let wv = webViewService
        let slotPool = pool
        let cancelToken = SandboxCancellationToken()

        let metaJSON: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let gate = OneShotTimeoutGate(cont)
                let timeoutTask = Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .seconds(5.0))
                    guard !Task.isCancelled else { return }
                    gate.resume(throwing: PluginSecurityError.timeout(seconds: 5.0))
                    cancelToken.cancel()
                }
                cancelToken.onCancel {
                    timeoutTask.cancel()
                    gate.resume(throwing: CancellationError())
                }
                lease.queue.async {
                    defer {
                        timeoutTask.cancel()
                        Task { await slotPool.releaseLease(lease) }
                    }
                    guard !cancelToken.isCancelled else {
                        gate.resume(throwing: CancellationError())
                        return
                    }
                    guard let ctx = JSContext() else {
                        gate.resume(throwing: PluginSecurityError.scriptError("无法创建内置解析器 JSContext"))
                        return
                    }
                    var jsErr: String?
                    ctx.exceptionHandler = { _, exc in jsErr = exc?.toString() }
                    let previewFactory = HostBridgeFactoryJS(
                        fixedOwnerID: "parser-preview",
                        policyProvider: { owner in SourcePermissionPolicy(ownerID: owner, isBuiltinParser: true, allowNetwork: false) },
                        httpClient: client,
                        cookieVault: vault,
                        cacheRoot: previewCacheRoot,
                        logger: logStore,
                        webViewService: wv,
                        cancellationToken: cancelToken
                    )
                    ctx.setObject(previewFactory, forKeyedSubscript: "__bridge" as NSString)
                    ctx.evaluateScript(prelude)
                    ctx.evaluateScript("delete this.__bridge;")
                    ctx.evaluateScript(scriptBody)
                    if cancelToken.isCancelled {
                        gate.resume(throwing: CancellationError())
                        return
                    }
                    if let err = jsErr {
                        gate.resume(throwing: PluginSecurityError.scriptError("解析器脚本校验失败：\(err)"))
                        return
                    }
                    let val = ctx.objectForKeyedSubscript("__metaParser")?.call(withArguments: [])
                    let out = (val != nil && val?.isNull == false && val?.isUndefined == false) ? (val?.toString() ?? "[]") : "[]"
                    if let err = jsErr {
                        gate.resume(throwing: PluginSecurityError.scriptError("解析器脚本校验失败：\(err)"))
                        return
                    }
                    gate.resume(returning: out)
                }
            }
        } onCancel: {
            cancelToken.cancel()
        }

        guard let data = metaJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let id = first["id"] as? String,
              let name = first["name"] as? String else {
            throw PluginSecurityError.scriptError("脚本未调用 registerBuiltinParser 注册解析器")
        }

        let hosts = (first["hosts"] as? [String]) ?? []
        let networkHosts = (first["networkHosts"] as? [String]) ?? []
        let sourceIDs = (first["sourceIDs"] as? [String]) ?? []
        let rawQualities = (first["qualities"] as? [String]) ?? []
        var qualities: [AudioQualityTier] = []
        for token in rawQualities {
            if let tier = AudioQualityTier.fromParserToken(token), !qualities.contains(tier) {
                qualities.append(tier)
            }
        }
        let meta = BuiltinParserMetaDTO(
            id: id,
            name: name,
            version: (first["version"] as? String) ?? "1.0.0",
            author: (first["author"] as? String) ?? "",
            summary: (first["summary"] as? String) ?? "",
            hosts: hosts,
            networkHosts: networkHosts,
            sourceIDs: sourceIDs,
            qualities: qualities.isEmpty ? [.auto, .saver, .standard, .high] : qualities,
            supportsPlayback: (first["supportsPlayback"] as? Bool) ?? true,
            supportsDownload: (first["supportsDownload"] as? Bool) ?? true,
            requiresCookie: (first["requiresCookie"] as? Bool) ?? true,
            sha256: DSCrypto.sha256Hex(scriptBody),
            isEnabled: true,
            healthStatus: .healthy
        )

        try atomicWritePair(id: id, scriptBody: scriptBody, meta: meta)
        installedParsers[id] = meta
        cachedScriptBodies[id] = scriptBody
        appendLog("已安装内置解析器 \(name) v\(meta.version) [sha256:\(meta.sha256.prefix(8))]")
        return meta
    }

    public func tryResolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool,
        bypassCache: Bool = false
    ) async throws -> AudioStreamDTO? {
        guard let matched = matchParser(sourceID: sourceID, chapterURL: chapter.url, forDownload: forDownload) else {
            return nil
        }
        var reqObj: [String: Any] = [
            "sourceID": sourceID,
            "bookID": bookID,
            "chapterID": chapter.id,
            "url": chapter.url,
            "episodeURL": chapter.url,
            "quality": preferredQuality.parserToken,
            "forDownload": forDownload,
            "isVIP": chapter.isVIP,
            "bypassCache": bypassCache
        ]
        if let extractedTrack = Self.extractTrackID(from: chapter.url) {
            reqObj["trackId"] = extractedTrack
        }
        guard let reqData = try? JSONSerialization.data(withJSONObject: [reqObj]),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            markHealth(id: matched.id, status: .failed)
            return nil
        }
        let rawOut = try await executeParserMethod(matched: matched, method: "resolveAudio", argsJSON: reqStr, timeoutSeconds: 30.0, isForegroundPlayback: !forDownload)
        guard let outData = rawOut.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            markHealth(id: matched.id, status: .failed)
            return nil
        }
        if (envelope["c"] as? Bool) == true { throw CancellationError() }
        if let errMsg = envelope["e"] as? String {
            let reason = (envelope["r"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fullMsg = (!reason.isEmpty && !errMsg.contains(reason)) ? "\(errMsg)（\(reason)）" : errMsg
            if Self.businessRejectionReasons.contains(reason) {
                markHealth(id: matched.id, status: .healthy)
                appendLog("[\(matched.name)] 业务拦截：\(fullMsg)")
                throw PluginSecurityError.parserRejected(reason: reason, message: fullMsg)
            }
            markHealth(id: matched.id, status: .degraded)
            appendLog("[\(matched.name)] 解析失败：\(fullMsg)")
            throw PluginSecurityError.scriptError(fullMsg)
        }
        guard let innerStr = envelope["v"] as? String,
              let innerData = innerStr.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let urlStr = (forDownload ? (inner["downloadUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil).flatMap({ $0.isEmpty ? nil : $0 })
                  ?? (inner["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlStr.isEmpty, let url = URL(string: urlStr) else {
            markHealth(id: matched.id, status: .degraded)
            appendLog("[\(matched.name)] 未返回有效直链，已回退书源解析：\(chapter.title)")
            return nil
        }
        // AUD-03：返回 AudioStreamDTO 前强制校验 url 与 downloadUrl 非私网/非法协议
        try SSRFGuard.validatePublicURL(url)
        if let dlRaw = (inner["downloadUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !dlRaw.isEmpty {
            guard let dlURL = URL(string: dlRaw) else { throw PluginSecurityError.invalidURL(dlRaw) }
            try SSRFGuard.validatePublicURL(dlURL)
        }
        if let primaryRaw = (inner["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !primaryRaw.isEmpty {
            guard let primaryURL = URL(string: primaryRaw) else { throw PluginSecurityError.invalidURL(primaryRaw) }
            try SSRFGuard.validatePublicURL(primaryURL)
        }
        markHealth(id: matched.id, status: .healthy)
        var headers: [String: String] = [:]
        if let rawHeaders = inner["headers"] as? [String: Any] {
            for (k, v) in rawHeaders where !(v is NSNull) {
                if let s = v as? String { headers[k] = s }
                else if let n = v as? NSNumber { headers[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue }
                else { headers[k] = "\(v)" }
            }
        }
        let rawBitrate = (inner["bitrate"] as? Int) ?? (inner["measuredKbps"] as? Int)
        let bitrate = (rawBitrate ?? 0) > 0 ? rawBitrate : nil
        let mime = inner["mimeType"] as? String
        let capped = (inner["capped"] as? Bool) ?? (bitrate == 24)
        let isHLS = (inner["isHLS"] as? Bool) ?? (url.pathExtension.lowercased() == "m3u8" || mime?.lowercased().contains("mpegurl") == true)
        let actualTier = Self.resolveActualQualityTier(from: inner, fallback: preferredQuality)
        let isTrial = (inner["isTrial"] as? Bool) ?? false
        logResolveSuccess(parserName: matched.name, chapterTitle: chapter.title, tier: actualTier, bitrate: bitrate, forDownload: forDownload, isTrial: isTrial)
        return AudioStreamDTO(
            url: url,
            headers: headers,
            qualityTier: actualTier,
            bitrateKbps: bitrate,
            isHLS: isHLS,
            isTrial: isTrial,
            isCappedFallback: capped,
            mimeType: mime
        )
    }

    /// 统一执行已安装解析器的方法（AUD-13：固定串行队列池 + prelude 后立即删除 __bridge）
    internal func executeParserMethod(
        matched: BuiltinParserMetaDTO,
        method: String,
        argsJSON: String,
        timeoutSeconds: TimeInterval,
        isForegroundPlayback: Bool = false
    ) async throws -> String {
        let scriptBody: String
        if let cached = cachedScriptBodies[matched.id] {
            scriptBody = cached
        } else {
            let scriptFile = parserDir(for: matched.id).appendingPathComponent("script.js")
            guard let loaded = try? String(contentsOf: scriptFile, encoding: .utf8) else {
                markHealth(id: matched.id, status: .failed)
                throw PluginSecurityError.scriptError("内置解析器脚本文件缺失")
            }
            cachedScriptBodies[matched.id] = loaded
            scriptBody = loaded
        }
        let targetPool = isForegroundPlayback ? playbackPool : pool
        let lease = try await targetPool.acquireLease()
        let prelude = preludeParserScript
        let client = httpClient
        let vault = cookieVault
        let rootDir = storageDir
        let logStore = logger
        let wv = webViewService
        let cancelToken = SandboxCancellationToken()
        let parserID = matched.id

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let gate = OneShotTimeoutGate(cont)
                let timeoutTask = Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    gate.resume(throwing: PluginSecurityError.timeout(seconds: timeoutSeconds))
                    cancelToken.cancel()
                }
                cancelToken.onCancel {
                    timeoutTask.cancel()
                    gate.resume(throwing: CancellationError())
                }
                lease.queue.async {
                    defer {
                        timeoutTask.cancel()
                        Task { await targetPool.releaseLease(lease) }
                    }
                    guard !cancelToken.isCancelled else {
                        gate.resume(throwing: CancellationError())
                        return
                    }
                    guard let ctx = JSContext() else {
                        gate.resume(throwing: PluginSecurityError.scriptError("无法创建内置解析器 JSContext"))
                        return
                    }
                    var jsErr: String?
                    ctx.exceptionHandler = { _, exc in
                        let msg = exc?.toString() ?? "Unknown JS exception"
                        jsErr = msg
                        Task { await logStore.record(category: .plugin, level: "ERROR", message: "[\(parserID)] JS异常：\(msg)") }
                    }
                    let factory = HostBridgeFactoryJS(
                        fixedOwnerID: matched.id,
                        policyProvider: { owner in
                            SourcePermissionPolicy(
                                ownerID: owner,
                                isBuiltinParser: true,
                                permissionMode: .declaredHosts,
                                declaredHosts: matched.hosts + matched.networkHosts,
                                allowNetwork: true
                            )
                        },
                        httpClient: client,
                        cookieVault: vault,
                        cacheRoot: rootDir,
                        logger: logStore,
                        webViewService: wv,
                        cancellationToken: cancelToken
                    )
                    ctx.setObject(factory, forKeyedSubscript: "__bridge" as NSString)
                    ctx.evaluateScript(prelude)
                    ctx.evaluateScript("delete this.__bridge;")
                    ctx.evaluateScript(scriptBody)
                    if cancelToken.isCancelled { gate.resume(throwing: CancellationError()); return }
                    if let err = jsErr { gate.resume(throwing: PluginSecurityError.scriptError(err)); return }
                    let val = ctx.objectForKeyedSubscript("__invokeParserSafe")?.call(withArguments: [0, method, argsJSON])
                    let out = (val != nil && val?.isNull == false && val?.isUndefined == false) ? (val?.toString() ?? "") : ""
                    if cancelToken.isCancelled { gate.resume(throwing: CancellationError()); return }
                    if let err = jsErr { gate.resume(throwing: PluginSecurityError.scriptError(err)); return }
                    gate.resume(returning: out)
                }
            }
        } onCancel: {
            cancelToken.cancel()
        }
    }

    private static let businessRejectionReasons: Set<String> = ["trial_only", "not_vip", "no_cookie"]
}
