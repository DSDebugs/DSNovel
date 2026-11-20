import Foundation
import CryptoKit
import JavaScriptCore

enum SourceLoginVerifyResult: Sendable, Equatable {
    case verified(nickname: String)
    case notLoggedIn(reason: String)
    case noCheckMethod
}

enum PluginError: LocalizedError, Equatable, Sendable {
    case needLogin(sourceID: String, loginURL: String)
    case needVerify(sourceID: String, verifyURL: String)
    case rateLimited
    case parseFailed(String)
    case timeout
    case network(String)
    /// 书源明确答复「需要会员/购买」——由内置解析回退链处理
    case vipRequired(sourceID: String)
    /// VIP 章节但没有可用的内置解析脚本（UI 唯一提示出口：去导入）
    case builtinParserMissing(sourceID: String)
    /// 已安装内置解析，但解析失败
    case builtinParserFailed(sourceID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .needLogin: return "该书源需要登录账号后才能访问"
        case .needVerify: return "该书源触发了安全验证，请完成验证后重试"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .parseFailed(let detail): return "解析内容失败：\(detail)"
        case .timeout: return "书源响应超时"
        case .network(let msg): return "网络请求异常：\(msg)"
        case .vipRequired: return BuiltinParserStrings.vipNeedsParser
        case .builtinParserMissing: return BuiltinParserStrings.vipNeedsParser
        case .builtinParserFailed(_, let reason):
            return reason.isEmpty ? "VIP 章节解析失败" : "VIP 章节解析失败：\(reason)"
        }
    }

    /// 是否属于「需要内置解析」的 VIP 类错误（决定 UI 是否显示跳转按钮）
    var isVIPRelated: Bool {
        switch self {
        case .vipRequired, .builtinParserMissing, .builtinParserFailed: return true
        default: return false
        }
    }

    /// 该错误对应的跳转按钮标题（唯一提示出口）
    var builtinParserJumpTitle: String? {
        switch self {
        case .builtinParserMissing, .vipRequired: return BuiltinParserStrings.jumpToImport
        case .builtinParserFailed: return BuiltinParserStrings.jumpToInspect
        default: return nil
        }
    }
}

struct PluginPackageManifest: Codable, Sendable {
    var name: String
    var version: String
    var author: String?
    var description: String?
    var scripts: [String]
}

struct ParsedSourceMeta: Hashable, Codable, Sendable {
    var index: Int
    var id: String
    var name: String
    var url: String
    var summary: String
    var group: String
    var searchable: Bool
    var discoverable: Bool
    var multipleEpisodePages: Bool
    var enabledByDefault: Bool
    var loginURL: String
    var loginDesktop: Bool = false
    var loginScript: String = ""
    var loginAltURL: String = ""
    var hasCheckLogin: Bool = false
    var hasSearchVerification: Bool
    var searchVerificationDesktop: Bool
    var searchDelaySeconds: Int
    var methods: Set<String>
    var config: [SourceConfigItem]
}

struct PluginImportPreview: Identifiable, Sendable {
    var id: String { packageID }
    var packageID: String
    var name: String
    var version: String
    var author: String
    var description: String
    var sources: [ParsedSourceMeta]
    var domains: [String]
    var extractedFiles: [String: Data]
}


/// 线程安全的插件包 JSContext 池：每个 JSContext 拥有独立 JSVirtualMachine，严格保证同一 JSContext 绝不被多线程并发调用
final class PackageContextPool: @unchecked Sendable {
    let packageID: String
    let manifest: PluginPackageManifest
    let scriptFiles: [String: Data]
    let sources: [ParsedSourceMeta]

    private let condition = NSCondition()
    private var idleContexts: [JSContext] = []
    private var activeCount: Int = 0
    private let maxPoolSize: Int = 6
    private var isInvalidated: Bool = false
    var lastUsedAt: Date = .now

    init(
        packageID: String,
        manifest: PluginPackageManifest,
        scriptFiles: [String: Data],
        initialContext: JSContext,
        sources: [ParsedSourceMeta]
    ) {
        self.packageID = packageID
        self.manifest = manifest
        self.scriptFiles = scriptFiles
        self.sources = sources
        self.idleContexts = [initialContext]
    }

    func checkoutContext(maxWaitSeconds: TimeInterval = 12.0) throws -> JSContext {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        condition.lock()
        while true {
            if isInvalidated {
                condition.unlock()
                throw PluginError.parseFailed("书源上下文已重置")
            }
            if let ctx = idleContexts.popLast() {
                activeCount += 1
                lastUsedAt = .now
                condition.unlock()
                return ctx
            }
            if activeCount < maxPoolSize {
                activeCount += 1
                lastUsedAt = .now
                condition.unlock()
                do {
                    let (newCtx, _) = try PluginRuntime.createIsolatedContext(
                        packageID: packageID,
                        manifest: manifest,
                        scriptFiles: scriptFiles
                    )
                    return newCtx
                } catch {
                    condition.lock()
                    activeCount = max(0, activeCount - 1)
                    condition.broadcast()
                    condition.unlock()
                    throw error
                }
            }
            if Date() >= deadline {
                condition.unlock()
                throw PluginError.timeout
            }
            _ = condition.wait(until: min(deadline, Date(timeIntervalSinceNow: 0.2)))
        }
    }

    func checkinContext(_ ctx: JSContext, discard: Bool = false) {
        condition.lock()
        activeCount = max(0, activeCount - 1)
        lastUsedAt = .now
        if !discard && !isInvalidated && idleContexts.count < 4 {
            idleContexts.append(ctx)
        }
        condition.broadcast()
        condition.unlock()
    }

    func invalidate() {
        condition.lock()
        isInvalidated = true
        idleContexts.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

/// 并发安全的单次恢复门栓与取消/超时协调器：
/// 防止超时任务、Task 取消与 GCD JS 执行回调重复 resume，并在超时/取消时通知 JsHostBridge 取消阻塞的网络任务
private final class PluginExecutionControl<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var aborted = false
    private var activeContext: JSContext?

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if aborted {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    /// 绑定当前检出的 JSContext；若此前已取消/超时则立即触发网络任务取消并返回 false
    @discardableResult
    func attachContext(_ ctx: JSContext) -> Bool {
        lock.lock()
        activeContext = ctx
        let alreadyAborted = aborted
        lock.unlock()
        if alreadyAborted {
            JsHostBridge.cancelActiveTasks(for: ctx)
            return false
        }
        return true
    }

    func detachContext() {
        lock.lock()
        activeContext = nil
        lock.unlock()
    }

    func abort(with error: Error) {
        lock.lock()
        aborted = true
        let cont = continuation
        continuation = nil
        let ctx = activeContext
        lock.unlock()
        if let ctx {
            JsHostBridge.cancelActiveTasks(for: ctx)
        }
        cont?.resume(throwing: error)
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}

/// 插件运行时 Actor：使用独立 GCD 并发队列执行同步 JSContext，彻底避免阻塞 Swift Concurrency 协作线程池导致多源搜索超时无内容
actor PluginRuntime {
    static let shared = PluginRuntime()

    /// 独立 GCD 并发队列：专用于同步 JSContext 与阻塞式 HTTP 桥接调用，绝不占用 Swift Concurrency 6 核协作线程
    private static let jsExecutionQueue = DispatchQueue(
        label: "com.dsnovel.plugin.jsruntime",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// 是否已经从磁盘扫描过已安装书源包（避免路由未命中时反复全量重建 JSContext）
    private var hasScannedDisk = false

    private var activePools: [String: PackageContextPool] = [:]
    private var sourceRouting: [String: (packageID: String, sourceIndex: Int, meta: ParsedSourceMeta)] = [:]
    private let idleLimitSeconds: TimeInterval = 300 // 空闲 5 分钟回收

    var pluginsRootDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 插件包解析与导入预览（4.2.1 & 4.2.7）

    func prepareImportPreview(from zipData: Data) throws -> PluginImportPreview {
        guard !zipData.isEmpty else {
            throw PluginError.parseFailed("文件为空，请确认选择的是书源包")
        }
        let files: [String: Data]
        if zipData.starts(with: [0x50, 0x4B]) {
            files = try ZIPArchiveReader.extractAll(from: zipData)
        } else if let text = Self.decodeScriptText(zipData), text.contains("registerSource") {
            // 直接导入单个 .js 书源脚本
            files = ["source.js": zipData]
        } else {
            throw PluginError.parseFailed("不是有效的书源包：请选择 .zip 书源包或包含 registerSource 的 .js 脚本")
        }

        let manifest: PluginPackageManifest
        if let manifestData = files["manifest.json"],
           let decoded = try? JSONDecoder().decode(PluginPackageManifest.self, from: manifestData) {
            manifest = decoded
        } else {
            // McpGuide.md 第 1 节：没有 manifest.json 时，按文件名顺序执行包里的所有 .js
            let jsFiles = files.keys.filter { $0.lowercased().hasSuffix(".js") }.sorted()
            guard !jsFiles.isEmpty else {
                throw PluginError.parseFailed("插件包里没有找到脚本（需要 manifest.json 或 .js 文件）")
            }
            // 用脚本内容摘要生成唯一包名，避免不同书源包都叫 ImportedPlugin 而互相覆盖
            var hasher = SHA256()
            for name in jsFiles { hasher.update(data: files[name] ?? Data()) }
            let digest = hasher.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
            manifest = PluginPackageManifest(
                name: "Imported-\(digest)",
                version: "1.0.0",
                author: nil,
                description: nil,
                scripts: jsFiles
            )
        }

        let packageID = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, metas) = try Self.createIsolatedContext(
            packageID: packageID,
            manifest: manifest,
            scriptFiles: files
        )
        guard !metas.isEmpty else {
            throw PluginError.parseFailed("插件没有注册任何书源（registerSource）")
        }

        let domains = Array(
            Set(
                metas.compactMap { URL(string: $0.url)?.host }.filter { !$0.isEmpty }
            )
        ).sorted()

        return PluginImportPreview(
            packageID: packageID,
            name: manifest.name,
            version: manifest.version,
            author: manifest.author ?? "",
            description: manifest.description ?? "",
            sources: metas,
            domains: domains,
            extractedFiles: files
        )
    }

    func installPackage(_ preview: PluginImportPreview) throws -> [ParsedSourceMeta] {
        let pkgDir = pluginsRootDirectory.appendingPathComponent(preview.packageID, isDirectory: true)
        try? FileManager.default.removeItem(at: pkgDir)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        for (fileName, data) in preview.extractedFiles {
            let cleanName = (fileName as NSString).lastPathComponent
            guard !cleanName.isEmpty else { continue }
            let fileURL = pkgDir.appendingPathComponent(cleanName)
            try data.write(to: fileURL, options: .atomic)
        }

        if preview.extractedFiles["manifest.json"] == nil {
            let fallbackManifest = PluginPackageManifest(
                name: preview.name,
                version: preview.version,
                author: preview.author,
                description: preview.description,
                scripts: preview.extractedFiles.keys
                    .map { ($0 as NSString).lastPathComponent }
                    .filter { $0.lowercased().hasSuffix(".js") }
                    .sorted()
            )
            if let data = try? JSONEncoder().encode(fallbackManifest) {
                try? data.write(to: pkgDir.appendingPathComponent("manifest.json"), options: .atomic)
            }
        }

        if let metaData = try? JSONEncoder().encode(preview.sources) {
            try? metaData.write(to: pkgDir.appendingPathComponent("sources_meta.json"), options: .atomic)
        }

        if let oldPool = activePools.removeValue(forKey: preview.packageID) {
            oldPool.invalidate()
        }
        // 清除该包旧版本遗留的路由（新版本已删除的书源不应继续可调用）
        sourceRouting = sourceRouting.filter { $0.value.packageID != preview.packageID }
        for meta in preview.sources {
            sourceRouting[meta.id] = (preview.packageID, meta.index, meta)
        }
        return preview.sources
    }

    func removeSourceFilesAndCache(sourceID: String, packageID: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = caches.appendingPathComponent("PluginCache/\(sourceID)", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        sourceRouting.removeValue(forKey: sourceID)

        // 若该 package 下已无任何注册源，连同磁盘目录与连接池一并清理
        let remainingInPackage = sourceRouting.values.contains { $0.packageID == packageID }
        if !remainingInPackage {
            if let oldPool = activePools.removeValue(forKey: packageID) {
                oldPool.invalidate()
            }
            let pkgDir = pluginsRootDirectory.appendingPathComponent(packageID, isDirectory: true)
            try? FileManager.default.removeItem(at: pkgDir)
        }
    }

    func removeAllPackagesAndCache() {
        for (_, pool) in activePools {
            pool.invalidate()
        }
        activePools.removeAll()
        sourceRouting.removeAll()
        hasScannedDisk = true
        try? FileManager.default.removeItem(at: pluginsRootDirectory)
        try? FileManager.default.createDirectory(at: pluginsRootDirectory, withIntermediateDirectories: true)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("PluginCache", isDirectory: true))
    }

    func reloadInstalledPackages() {
        hasScannedDisk = true
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: pluginsRootDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for dir in dirs where dir.hasDirectoryPath {
            let pkgID = dir.lastPathComponent
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PluginPackageManifest.self, from: manifestData) else {
                continue
            }

            // 冷启动优先读取缓存的 sources_meta.json 构建路由表，JSContext 池按需懒创建
            let metaCacheURL = dir.appendingPathComponent("sources_meta.json")
            if let metaData = try? Data(contentsOf: metaCacheURL),
               let cachedMetas = try? JSONDecoder().decode([ParsedSourceMeta].self, from: metaData),
               !cachedMetas.isEmpty {
                for m in cachedMetas {
                    sourceRouting[m.id] = (pkgID, m.index, m)
                }
                continue
            }

            // 已有活跃池时直接复用其元数据
            if let existingPool = activePools[pkgID] {
                for m in existingPool.sources {
                    sourceRouting[m.id] = (pkgID, m.index, m)
                }
                continue
            }

            // 兼容旧版安装目录（尚无 sources_meta.json）：首次解析一次并落盘元数据缓存，不常驻空闲上下文池
            var files: [String: Data] = ["manifest.json": manifestData]
            for script in manifest.scripts {
                let clean = (script as NSString).lastPathComponent
                let sURL = dir.appendingPathComponent(clean)
                if let d = try? Data(contentsOf: sURL) {
                    files[clean] = d
                }
            }
            if let (_, metas) = try? Self.createIsolatedContext(packageID: pkgID, manifest: manifest, scriptFiles: files) {
                if let encoded = try? JSONEncoder().encode(metas) {
                    try? encoded.write(to: metaCacheURL, options: .atomic)
                }
                for m in metas {
                    sourceRouting[m.id] = (pkgID, m.index, m)
                }
            }
        }
    }

    func supportsMultipleEpisodePages(sourceID: String) -> Bool {
        if let route = try? ensureRoute(for: sourceID) {
            return route.meta.multipleEpisodePages
        }
        return false
    }

    func sourceMeta(for sourceID: String) -> ParsedSourceMeta? {
        try? ensureRoute(for: sourceID)?.meta
    }

    /// 获取书源登录元数据（供 WebAuthSheet 自动应用 loginDesktop、loginScript 与备用登录地址）
    func sourceLoginMeta(sourceID: String) -> (
        loginURL: String,
        siteURL: String,
        loginDesktop: Bool,
        loginScript: String,
        loginAltURL: String,
        hasCheckLogin: Bool
    )? {
        guard let meta = try? ensureRoute(for: sourceID)?.meta else { return nil }
        return (
            loginURL: meta.loginURL,
            siteURL: meta.url,
            loginDesktop: meta.loginDesktop,
            loginScript: meta.loginScript,
            loginAltURL: meta.loginAltURL,
            hasCheckLogin: meta.hasCheckLogin
        )
    }

    /// 调用书源的 checkLogin() 校验登录状态并返回账号昵称/状态说明（对齐 ssts JsSource.checkLogin）
    func checkLogin(sourceID: String) async throws -> String {
        guard let route = try ensureRoute(for: sourceID),
              route.meta.methods.contains("checkLogin") else {
            return ""
        }
        let jsonStr = try await invokeMethod(
            sourceID: sourceID,
            method: "checkLogin",
            args: [],
            timeoutSec: 10.0
        )
        if let data = jsonStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            if let str = obj as? String {
                return str
            }
            if let b = obj as? Bool {
                return b ? "已登录" : ""
            }
            if let dict = obj as? [String: Any] {
                return Self.stringValue(dict["name"]) ?? Self.stringValue(dict["nickname"]) ?? "已登录"
            }
        }
        return jsonStr.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t"))
    }

    /// 严格校验单个书源的真实登录状态：优先调用书源脚本的 checkLogin()，杜绝将站点匿名访客 Set-Cookie 误判为已登录
    func verifyLoginStatus(sourceID: String) async -> SourceLoginVerifyResult {
        guard let route = try? ensureRoute(for: sourceID) else {
            return .noCheckMethod
        }
        guard route.meta.methods.contains("checkLogin") else {
            return .noCheckMethod
        }
        do {
            let nick = try await checkLogin(sourceID: sourceID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !nick.isEmpty && nick != "null" && nick != "undefined" && nick != "false" {
                CookieSync.setVerifiedLogin(sourceID: sourceID, nickname: nick)
                return .verified(nickname: nick)
            } else {
                CookieSync.setVerifiedLogin(sourceID: sourceID, nickname: nil)
                return .notLoggedIn(reason: "未登录")
            }
        } catch {
            CookieSync.setVerifiedLogin(sourceID: sourceID, nickname: nil)
            return .notLoggedIn(reason: error.localizedDescription)
        }
    }

    // MARK: - 书源可用性及延迟检测（支持单源点击检测与批量并发检测）

    func checkSourceHealth(sourceID: String) async -> SourceHealthCheckResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        guard let route = try? ensureRoute(for: sourceID) else {
            return SourceHealthCheckResult(
                sourceID: sourceID,
                state: .unavailable,
                latencyMs: -1,
                message: "未找到书源脚本，请重新导入书源包",
                sampleCount: 0,
                checkedAt: .now
            )
        }

        let meta = route.meta
        do {
            // 1. 优先测试免间隔的搜索接口（能真实反映搜索与网络延迟）
            if meta.searchable && meta.searchDelaySeconds == 0 {
                do {
                    let pageDTO = try await invokeSearchWithTimeout(
                        sourceID: sourceID,
                        keyword: "有声",
                        page: 1,
                        timeoutSec: 10.0
                    )
                    let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
                    if !pageDTO.books.isEmpty {
                        let state: SourceHealthState = elapsedMs <= 1500 ? .healthy : .slow
                        return SourceHealthCheckResult(
                            sourceID: sourceID,
                            state: state,
                            latencyMs: elapsedMs,
                            message: "搜索与解析正常（返回 \(pageDTO.books.count) 条）",
                            sampleCount: pageDTO.books.count,
                            checkedAt: .now
                        )
                    }
                } catch let pErr as PluginError {
                    if case .needLogin = pErr { throw pErr }
                    if case .needVerify = pErr { throw pErr }
                    if !meta.discoverable { throw pErr }
                }
            }

            // 2. 测试发现分类与首个公开分类列表（真实发起网络请求测算延迟）
            if meta.discoverable {
                let menuStart = CFAbsoluteTimeGetCurrent()
                let sections = try await discoverSections(sourceID: sourceID, timeoutSec: 8.0)
                let publicTab = sections
                    .flatMap(\.tabs)
                    .first { tab in
                        let u = tab.url.lowercased()
                        return !u.contains("-my:") && !u.contains("bili-fav:") && !u.contains("dy-live") && !u.contains("dy-mine") && !u.contains("ncm:mine")
                    }

                if let tab = publicTab {
                    let pageDTO = try await discoverList(sourceID: sourceID, tabURL: tab.url, timeoutSec: 10.0)
                    let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - menuStart) * 1000))
                    let state: SourceHealthState = elapsedMs <= 1500 ? .healthy : .slow
                    let count = pageDTO.books.count
                    return SourceHealthCheckResult(
                        sourceID: sourceID,
                        state: state,
                        latencyMs: elapsedMs,
                        message: count > 0 ? "分类列表正常（返回 \(count) 条）" : "分类接口响应正常",
                        sampleCount: count,
                        checkedAt: .now
                    )
                } else if !sections.isEmpty {
                    let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - menuStart) * 1000))
                    return SourceHealthCheckResult(
                        sourceID: sourceID,
                        state: elapsedMs <= 1500 ? .healthy : .slow,
                        latencyMs: elapsedMs,
                        message: "分类菜单正常（共 \(sections.count) 组）",
                        sampleCount: sections.count,
                        checkedAt: .now
                    )
                }
            }

            // 3. 对带有 searchDelaySeconds 的站点执行一次轻量搜索检测
            if meta.searchable {
                let searchStart = CFAbsoluteTimeGetCurrent()
                let pageDTO = try await invokeSearchWithTimeout(
                    sourceID: sourceID,
                    keyword: "小说",
                    page: 1,
                    timeoutSec: 10.0
                )
                let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - searchStart) * 1000))
                let state: SourceHealthState = elapsedMs <= 1500 ? .healthy : .slow
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: state,
                    latencyMs: elapsedMs,
                    message: !pageDTO.books.isEmpty ? "搜索正常（返回 \(pageDTO.books.count) 条）" : "搜索接口响应正常",
                    sampleCount: pageDTO.books.count,
                    checkedAt: .now
                )
            }

            let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
            return SourceHealthCheckResult(
                sourceID: sourceID,
                state: .healthy,
                latencyMs: elapsedMs,
                message: "书源脚本就绪",
                sampleCount: 0,
                checkedAt: .now
            )
        } catch let pErr as PluginError {
            let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
            switch pErr {
            case .needLogin:
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .needAuth,
                    latencyMs: elapsedMs,
                    message: "需要登录账号后使用",
                    sampleCount: 0,
                    checkedAt: .now
                )
            case .needVerify:
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .needAuth,
                    latencyMs: elapsedMs,
                    message: "触发人机验证，需在搜索或发现页验证",
                    sampleCount: 0,
                    checkedAt: .now
                )
            case .rateLimited:
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .slow,
                    latencyMs: elapsedMs,
                    message: "访问频率受限 (429)，请稍后再试",
                    sampleCount: 0,
                    checkedAt: .now
                )
            case .timeout:
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .unavailable,
                    latencyMs: elapsedMs,
                    message: "连接或解析超时 (>10s)",
                    sampleCount: 0,
                    checkedAt: .now
                )
            case .parseFailed(let detail):
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .unavailable,
                    latencyMs: elapsedMs,
                    message: detail,
                    sampleCount: 0,
                    checkedAt: .now
                )
            case .network(let msg):
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .unavailable,
                    latencyMs: elapsedMs,
                    message: Self.compactErrorMessage(msg),
                    sampleCount: 0,
                    checkedAt: .now
                )
            case .vipRequired, .builtinParserMissing:
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .healthy,
                    latencyMs: elapsedMs,
                    message: "书源可连通（部分 VIP 章节需内置解析）",
                    sampleCount: 0,
                    checkedAt: .now
                )
            case .builtinParserFailed(_, let reason):
                return SourceHealthCheckResult(
                    sourceID: sourceID,
                    state: .unavailable,
                    latencyMs: elapsedMs,
                    message: Self.compactErrorMessage(reason),
                    sampleCount: 0,
                    checkedAt: .now
                )
            }
        } catch {
            let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
            return SourceHealthCheckResult(
                sourceID: sourceID,
                state: .unavailable,
                latencyMs: elapsedMs,
                message: Self.compactErrorMessage(error.localizedDescription),
                sampleCount: 0,
                checkedAt: .now
            )
        }
    }

    nonisolated private static func compactErrorMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 48 { return trimmed }
        return String(trimmed.prefix(48)) + "…"
    }

    // MARK: - 统一源协议调用

    func search(sourceID: String, keyword: String, page: Int, timeoutSec: Double = 8.0) async throws -> DiscoverPageDTO {
        try await invokeSearchWithTimeout(sourceID: sourceID, keyword: keyword, page: page, timeoutSec: timeoutSec)
    }

    private func invokeSearchWithTimeout(
        sourceID: String,
        keyword: String,
        page: Int,
        timeoutSec: Double
    ) async throws -> DiscoverPageDTO {
        let jsonStr = try await invokeMethod(
            sourceID: sourceID,
            method: "search",
            args: [keyword, page],
            timeoutSec: timeoutSec
        )
        return try decodeDiscoverPage(from: jsonStr, sourceID: sourceID)
    }

    /// 获取特定关键词的人机验证地址（对齐 ssts searchVerificationUrl(keywords)）
    func searchVerificationURL(sourceID: String, keyword: String) async -> (url: String, desktop: Bool)? {
        guard let route = try? ensureRoute(for: sourceID) else { return nil }
        let desktop = route.meta.searchVerificationDesktop
        if route.meta.methods.contains("searchVerificationUrl") {
            if let raw = try? await invokeMethod(
                sourceID: sourceID,
                method: "searchVerificationUrl",
                args: [keyword],
                timeoutSec: 5.0
            ),
               let data = raw.data(using: .utf8),
               let urlStr = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String,
               !urlStr.isEmpty {
                return (urlStr, desktop)
            }
        }
        if !route.meta.url.isEmpty {
            return (route.meta.url, desktop)
        }
        return nil
    }

    func discoverSections(sourceID: String, timeoutSec: Double = 15.0) async throws -> [DiscoverSectionDTO] {
        guard let route = try ensureRoute(for: sourceID) else {
            return []
        }
        if !route.meta.methods.contains("categoryMenus") {
            return []
        }
        let jsonStr = try await invokeMethod(
            sourceID: sourceID,
            method: "categoryMenus",
            args: [],
            timeoutSec: timeoutSec
        )
        guard let data = jsonStr.data(using: .utf8),
              let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rawArray.compactMap { dict in
            let title = Self.stringValue(dict["title"]) ?? "分类"
            let rawTabs = (dict["tabs"] as? [[String: Any]]) ?? []
            let tabs = rawTabs.compactMap { t -> DiscoverTabDTO? in
                guard let tTitle = Self.stringValue(t["title"]),
                      let tURL = Self.stringValue(t["url"]),
                      !tTitle.isEmpty, !tURL.isEmpty else { return nil }
                return DiscoverTabDTO(title: tTitle, url: tURL)
            }
            return tabs.isEmpty ? nil : DiscoverSectionDTO(title: title, tabs: tabs)
        }
    }

    func discoverList(sourceID: String, tabURL: String, timeoutSec: Double = 16.0) async throws -> DiscoverPageDTO {
        let jsonStr = try await invokeMethod(
            sourceID: sourceID,
            method: "categoryPage",
            args: [tabURL],
            timeoutSec: timeoutSec
        )
        return try decodeDiscoverPage(from: jsonStr, sourceID: sourceID)
    }

    /// 获取书籍详情与章节目录：严格按照 SSTS 协议传入 (bookURL, loadEpisodes, loadFullPages) 三个参数！
    func bookDetail(
        sourceID: String,
        bookURL: String,
        loadEpisodes: Bool = true,
        loadFullPages: Bool = true
    ) async throws -> BookDetailDTO {
        let timeout: Double = (loadEpisodes && loadFullPages) ? 45.0 : 20.0
        let jsonStr = try await invokeMethod(
            sourceID: sourceID,
            method: "bookDetail",
            args: [bookURL, loadEpisodes, loadFullPages],
            timeoutSec: timeout
        )
        return try decodeBookDetail(from: jsonStr, sourceID: sourceID, bookURL: bookURL)
    }

    /// 增量更新章节（McpGuide.md 第 6 节 updateEpisodes(bookUrl, known)）
    func updateEpisodes(sourceID: String, bookURL: String, knownChapters: [ChapterDTO]) async throws -> BookDetailDTO? {
        guard let route = try ensureRoute(for: sourceID),
              route.meta.methods.contains("updateEpisodes"),
              !knownChapters.isEmpty else {
            return nil
        }
        let knownPayload: [[String: Any]] = knownChapters.map { ch in
            ["title": ch.title, "url": ch.url]
        }
        guard let jsonStr = try? await invokeMethod(
            sourceID: sourceID,
            method: "updateEpisodes",
            args: [bookURL, knownPayload],
            timeoutSec: 25.0
        ), !jsonStr.isEmpty, jsonStr != "null" else {
            return nil
        }
        return try? decodeBookDetail(from: jsonStr, sourceID: sourceID, bookURL: bookURL)
    }

    /// 解析章节播放流地址与请求头（100% 对齐 ssts JsSource.audio + Player.resolveAsset）
    func resolvePlayURL(sourceID: String, episodeURL: String, qualityCode: String = "M4A_128") async throws -> PlayStreamInfo {
        guard let route = try ensureRoute(for: sourceID) else {
            throw PluginError.parseFailed("未找到书源: \(sourceID)")
        }

        var urlString = ""
        var headers: [String: String] = [:]
        var explicitKind: StreamKind?

        // McpGuide.md 第 2/3 节：不写 audio 方法时，表示章节地址本身就是音频地址
        if !route.meta.methods.contains("audio") {
            urlString = episodeURL
        } else {
            let jsonStr = try await invokeMethod(
                sourceID: sourceID,
                method: "audio",
                args: [episodeURL, qualityCode],
                timeoutSec: 25.0
            )
            let trimmed = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                if let str = obj as? String {
                    urlString = str
                } else if let dict = obj as? [String: Any] {
                    urlString = Self.stringValue(dict["url"])
                        ?? Self.stringValue(dict["audioUrl"])
                        ?? Self.stringValue(dict["playUrl"])
                        ?? Self.stringValue(dict["src"])
                        ?? ""
                    if let rawHeaders = (dict["headers"] ?? dict["header"]) as? [String: Any] {
                        for (k, v) in rawHeaders {
                            if let s = Self.stringValue(v), !s.isEmpty {
                                headers[k] = s
                            }
                        }
                    }
                    if (dict["isLive"] as? Bool) == true {
                        explicitKind = .live
                    } else if let kStr = Self.stringValue(dict["kind"] ?? dict["type"])?.lowercased() {
                        if kStr.contains("hls") || kStr.contains("m3u8") {
                            explicitKind = .hls
                        } else if kStr.contains("live") {
                            explicitKind = .live
                        }
                    }
                }
            } else if trimmed.hasPrefix("http") || trimmed.hasPrefix("//") || trimmed.hasPrefix("/") {
                urlString = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else {
            throw PluginError.parseFailed("没有解析到音频地址")
        }

        // 将协议相对路径 // 或站内相对路径 / 解析为完整绝对地址
        let baseForRelative = episodeURL.lowercased().hasPrefix("http") ? episodeURL : route.meta.url
        if let resolvedURL = JsHostBridge.makeRequestURL(from: urlString, relativeTo: baseForRelative) {
            urlString = resolvedURL.absoluteString
        }

        // 若插件实现了 audioHeaders(audioUrl)，合并其返回的请求头（McpGuide.md 第 5 节）
        if route.meta.methods.contains("audioHeaders") {
            if let hJson = try? await invokeMethod(
                sourceID: sourceID,
                method: "audioHeaders",
                args: [urlString],
                timeoutSec: 8.0
            ),
               let hData = hJson.data(using: .utf8),
               let rawH = try? JSONSerialization.jsonObject(with: hData) as? [String: Any] {
                for (k, v) in rawH where headers[k] == nil {
                    if let s = Self.stringValue(v), !s.isEmpty {
                        headers[k] = s
                    }
                }
            }
        }

        // 提取并移除内部提示头 X-Media-Type（对齐 ssts Player.resolveAsset）
        var mediaTypeHint: String?
        for key in Array(headers.keys) where key.lowercased() == "x-media-type" {
            mediaTypeHint = headers.removeValue(forKey: key)?.lowercased()
        }

        // 确保 User-Agent 与跨子域 Cookie 自动注入到播放请求头中
        let hasUA = headers.keys.contains { $0.lowercased() == "user-agent" }
        if !hasUA {
            headers["User-Agent"] = JsHostBridge.mobileUA
        }
        let hasCookie = headers.keys.contains { $0.lowercased() == "cookie" }
        if !hasCookie, let targetURL = JsHostBridge.makeRequestURL(from: urlString) {
            let cookieStr = CookieSync.cookieHeader(for: targetURL)
            if !cookieStr.isEmpty {
                headers["Cookie"] = cookieStr
            }
        }

        let lower = urlString.lowercased()
        let kind: StreamKind
        if let explicitKind {
            kind = explicitKind
        } else if mediaTypeHint == "live" {
            kind = .live
        } else if mediaTypeHint == "hls" || lower.contains(".m3u8") {
            kind = .hls
        } else {
            kind = .onDemand
        }
        return PlayStreamInfo(url: urlString, headers: headers, kind: kind)
    }

    /// 播放/下载统一解析入口（推荐调用点：PlayerEngine / DownloadManager）
    ///
    /// 链路（已定：**固定策略，界面不再提供"解析策略"设置**）：
    ///  0. 命中已启用的内置解析器 → **解析器优先**（音质档由 `QualityPolicy` 算好后作为参数传入，不再写配置）
    ///  1. 解析器失败（**任何失败**）→ 回落官方书源通道（两链各取各的音质码）
    ///  2. 官方通道失败：
    ///       - VIP 类错误且**没有**可用解析器 → `.builtinParserMissing`（唯一提示出口：去编辑脚本）
    ///       - VIP 类错误且**有**解析器（两边都不行）→ `.builtinParserFailed`（去查看解析日志）
    ///       - 其它错误（needLogin / needVerify / network / timeout…）原样抛出
    ///
    /// 每个分支都写一条决策日志，便于用「查看日志」回答"为什么走了/没走内置解析"。
    func resolvePlayStream(
        sourceID: String,
        episodeURL: String,
        forDownload: Bool = false,
        tier: AudioQualityTier? = nil,
        expectedDurationSec: Double? = nil
    ) async throws -> PlayStreamInfo {
        let context = await MainActor.run {
            (
                tier ?? AppSettingsStore.shared.audioQualityTier.normalizedForSelection,
                DownloadManager.shared.isOnWiFi
            )
        }
        let resolvedTier = context.0
        let isOnWiFi = context.1

        let route = try? ensureRoute(for: sourceID)
        let sourceURL = route?.meta.url ?? ""
        let parser = await BuiltinParserRuntime.shared.parser(forSourceID: sourceID, sourceURL: sourceURL)

        // ① 解析器优先
        var lastParserError: String?
        if let parser {
            let parserCode = QualityPolicy.code(for: resolvedTier, chain: .builtinParser, isOnWiFi: isOnWiFi)
            var note = "档位 \(resolvedTier.title) → 解析器码 \(parserCode)"
            if QualityPolicy.didFallback(resolvedTier, chain: .builtinParser) {
                note += "（该档位解析器链不原生支持，已回落）"
            }
            BuiltinParserLogStore.shared.append(parser.id, "尝试内置解析：\(note)\(forDownload ? " · 下载" : "")")
            do {
                let stream = try await BuiltinParserRuntime.shared.resolve(
                    parser: parser,
                    sourceID: sourceID,
                    episodeURL: episodeURL,
                    forDownload: forDownload,
                    qualityCode: parserCode
                )
                if stream.isTrial {
                    BuiltinParserLogStore.shared.append(parser.id, "解析器返回试听标记（isTrial=true），回落官方通道")
                    await BuiltinParserRuntime.shared.invalidateCache(parserID: parser.id, episodeURL: episodeURL)
                    throw PluginError.builtinParserFailed(sourceID: sourceID, reason: "trial_only: 该章节仅提供试听")
                }
                if let expected = expectedDurationSec, expected > 60,
                   let got = stream.durationSec, got > 0,
                   got < expected * 0.6 {
                    BuiltinParserLogStore.shared.append(
                        parser.id,
                        "解析器返回时长 \(Int(got))s 明显短于章节 \(Int(expected))s，判定为试听片段并回落官方通道"
                    )
                    await BuiltinParserRuntime.shared.invalidateCache(parserID: parser.id, episodeURL: episodeURL)
                    throw PluginError.builtinParserFailed(sourceID: sourceID, reason: "trial_only: 内置解析仅返回试听片段")
                }
                return Self.fillDefaultHeaders(stream, episodeURL: episodeURL)
            } catch {
                let reason = Self.describe(error)
                lastParserError = reason
                BuiltinParserLogStore.shared.append(
                    parser.id,
                    "内置解析未命中，回落官方通道：\(reason)"
                )
            }
        }

        // ② 官方书源通道
        let bookCode = QualityPolicy.code(for: resolvedTier, chain: .bookSource, isOnWiFi: isOnWiFi)
        do {
            return try await resolvePlayURL(sourceID: sourceID, episodeURL: episodeURL, qualityCode: bookCode)
        } catch let error as PluginError {
            switch error {
            case .vipRequired:
                if parser == nil {
                    throw PluginError.builtinParserMissing(sourceID: sourceID)
                }
                let reason = lastParserError ?? "内置解析与官方通道都未能取得可用地址"
                if let parser {
                    BuiltinParserLogStore.shared.append(parser.id, "回落官方通道仍受 VIP 限制，透传失败原因：\(reason)")
                }
                throw PluginError.builtinParserFailed(sourceID: sourceID, reason: reason)
            default:
                throw error
            }
        }
    }

    /// 把解析器/脚本抛出的错误转成一句可读原因（写入决策日志用）
    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? BuiltinParserError {
            if case .rejected(let code, let msg) = e {
                return msg.isEmpty ? code : "\(code): \(msg)"
            }
            return e.errorDescription ?? "\(e)"
        }
        // 避免内置解析内部抛出的 builtinParserFailed 在回落官方通道后再被 LocalizedError 二次包装，
        // 导致 "VIP 章节解析失败：" 前缀吞掉 "trial_only:" 原始错误码。
        if let e = error as? PluginError, case .builtinParserFailed(_, let reason) = e {
            return reason
        }
        if let e = error as? LocalizedError, let d = e.errorDescription {
            return d
        }
        return "\(error)"
    }

    /// 补齐内置解析返回流缺失的 User-Agent 与跨子域 Cookie（脚本已给出则不覆盖）
    nonisolated private static func fillDefaultHeaders(_ stream: PlayStreamInfo, episodeURL: String) -> PlayStreamInfo {
        var result = stream
        let hasUA = result.headers.keys.contains { $0.lowercased() == "user-agent" }
        if !hasUA {
            result.headers["User-Agent"] = JsHostBridge.mobileUA
        }
        let hasCookie = result.headers.keys.contains { $0.lowercased() == "cookie" }
        if !hasCookie, let url = JsHostBridge.makeRequestURL(from: result.url, relativeTo: episodeURL) {
            let cookie = CookieSync.cookieHeader(for: url)
            if !cookie.isEmpty {
                result.headers["Cookie"] = cookie
            }
        }
        return result
    }

    func coverHeaders(sourceID: String, coverURL: String) async -> [String: String] {
        guard !coverURL.isEmpty,
              let route = try? ensureRoute(for: sourceID),
              route.meta.methods.contains("coverHeaders"),
              let jsonStr = try? await invokeMethod(sourceID: sourceID, method: "coverHeaders", args: [coverURL], timeoutSec: 5.0),
              let data = jsonStr.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var headers: [String: String] = [:]
        for (k, v) in raw {
            if let s = Self.stringValue(v) {
                headers[k] = s
            }
        }
        return headers
    }

    // MARK: - 内部线程安全 JSContext 池调用与解码（独立 GCD 并发队列 + 检出后计时）

    private func invokeMethod(
        sourceID: String,
        method: String,
        args: [Any],
        timeoutSec: Double = 18.0
    ) async throws -> String {
        reclaimIdlePools()
        guard let route = try ensureRoute(for: sourceID) else {
            throw PluginError.parseFailed("未找到书源: \(sourceID)")
        }
        let pool = try ensureContextPool(for: route.packageID)
        let argsData = try JSONSerialization.data(withJSONObject: args)
        let argsJson = String(data: argsData, encoding: .utf8) ?? "[]"
        let sourceIdx = route.sourceIndex
        let loginURL = route.meta.loginURL
        let siteURL = route.meta.url
        let hasVerify = route.meta.hasSearchVerification

        let control = PluginExecutionControl<String>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                control.setContinuation(continuation)
                if Task.isCancelled {
                    control.abort(with: CancellationError())
                    return
                }

                Self.jsExecutionQueue.async {
                    guard !control.isAborted else { return }

                    let ctx: JSContext
                    do {
                        ctx = try pool.checkoutContext(maxWaitSeconds: min(timeoutSec, 12.0))
                    } catch {
                        control.resume(with: .failure(error))
                        return
                    }

                    guard control.attachContext(ctx) else {
                        pool.checkinContext(ctx, discard: true)
                        return
                    }

                    // 检出 JSContext 后再启动该次方法执行的精确超时门栓
                    let timeoutWork = DispatchWorkItem {
                        control.abort(with: PluginError.timeout)
                    }
                    Self.jsExecutionQueue.asyncAfter(deadline: .now() + timeoutSec, execute: timeoutWork)

                    var shouldDiscard = false
                    defer {
                        timeoutWork.cancel()
                        control.detachContext()
                        if control.isAborted {
                            shouldDiscard = true
                        }
                        pool.checkinContext(ctx, discard: shouldDiscard)
                    }

                    // 优先调用 ssts 标准 __invokeSafe(i, n, a)
                    if let invokeSafeFn = ctx.objectForKeyedSubscript("__invokeSafe"), !invokeSafeFn.isUndefined {
                        guard let safeRes = invokeSafeFn.call(withArguments: [sourceIdx, method, argsJson]),
                              let envelopeStr = safeRes.toString(),
                              let envData = envelopeStr.data(using: .utf8),
                              let env = try? JSONSerialization.jsonObject(with: envData) as? [String: Any] else {
                            shouldDiscard = true
                            control.resume(with: .failure(PluginError.parseFailed("调用书源方法 \(method) 失败")))
                            return
                        }
                        if let errMsg = env["e"] as? String {
                            let mapped = Self.mapJSException(
                                errMsg,
                                sourceID: sourceID,
                                loginURL: loginURL,
                                siteURL: siteURL,
                                hasSearchVerification: hasVerify,
                                method: method
                            )
                            control.resume(with: .failure(mapped))
                            return
                        }
                        if let val = env["v"] as? String {
                            control.resume(with: .success(val))
                            return
                        }
                        control.resume(with: .failure(PluginError.parseFailed("脚本没有返回结果")))
                        return
                    }

                    guard let invokeFn = ctx.objectForKeyedSubscript("__invoke"),
                          let res = invokeFn.call(withArguments: [sourceIdx, method, argsJson]) else {
                        shouldDiscard = true
                        control.resume(with: .failure(PluginError.parseFailed("调用书源方法 \(method) 失败")))
                        return
                    }
                    if let exc = ctx.exception {
                        let excMsg = exc.toString() ?? "JS Exception"
                        ctx.exception = nil
                        let mapped = Self.mapJSException(
                            excMsg,
                            sourceID: sourceID,
                            loginURL: loginURL,
                            siteURL: siteURL,
                            hasSearchVerification: hasVerify,
                            method: method
                        )
                        control.resume(with: .failure(mapped))
                        return
                    }
                    guard !res.isNull && !res.isUndefined, let str = res.toString() else {
                        control.resume(with: .failure(PluginError.parseFailed("脚本没有返回结果")))
                        return
                    }
                    control.resume(with: .success(str))
                }
            }
        } onCancel: {
            control.abort(with: CancellationError())
        }
    }

    nonisolated private static func mapJSException(
        _ excMsg: String,
        sourceID: String,
        loginURL: String,
        siteURL: String,
        hasSearchVerification: Bool = false,
        method: String = ""
    ) -> PluginError {
        let targetAuthURL = loginURL.isEmpty ? siteURL : loginURL
        let explicitNeedLogin = excMsg.contains("401")
            || excMsg.contains("请先登录")
            || excMsg.contains("需要登录")
            || excMsg.contains("未登录")
            || excMsg.contains("没有登录")
            || excMsg.contains("尚未登录")
            || excMsg.contains("登录失效")
            || excMsg.contains("请登录")
            || excMsg.contains("登录已过期")
            || excMsg.contains("登录后")

        if explicitNeedLogin {
            return .needLogin(sourceID: sourceID, loginURL: targetAuthURL)
        }
        if excMsg.contains("登录") && !CookieSync.isSourceLoggedIn(sourceID) {
            return .needLogin(sourceID: sourceID, loginURL: targetAuthURL)
        }
        let isVerifyError = excMsg.contains("403")
            || excMsg.contains("503")
            || excMsg.contains("验证")
            || excMsg.lowercased().contains("captcha")
            || (hasSearchVerification && method == "search")
        if isVerifyError {
            return .needVerify(sourceID: sourceID, verifyURL: siteURL)
        }
        if excMsg.contains("429") {
            return .rateLimited
        }
        // VIP / 付费受限：书源明确答复「需要会员或购买」→ 交给内置解析回退链处理
        let vipMarkers = ["会员", "购买", "付费", "试听", "VIP", "vip", "已购"]
        if vipMarkers.contains(where: { excMsg.contains($0) }) {
            return .vipRequired(sourceID: sourceID)
        }
        return .network(excMsg)
    }

    private func decodeDiscoverPage(from jsonStr: String, sourceID: String) throws -> DiscoverPageDTO {
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.parseFailed("列表数据格式错误")
        }
        let siteURL = (try? ensureRoute(for: sourceID)?.meta.url) ?? ""
        let rawBooks = (dict["books"] as? [[String: Any]]) ?? []
        var seenIDs = Set<String>()
        var books: [BookRef] = []

        for b in rawBooks {
            let title = (Self.stringValue(b["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var bookURL = (Self.stringValue(b["bookUrl"]) ?? Self.stringValue(b["url"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty && !bookURL.isEmpty else { continue }
            if bookURL.hasPrefix("//") {
                bookURL = "https:" + bookURL
            } else if bookURL.hasPrefix("/") && !siteURL.isEmpty {
                bookURL = JsElement.resolveAbsoluteURL(raw: bookURL, baseURL: siteURL)
            }

            let rawAuthor = (Self.stringValue(b["author"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawArtist = (Self.stringValue(b["artist"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let author: String
            if !rawAuthor.isEmpty && !rawArtist.isEmpty && rawAuthor != rawArtist {
                author = "\(rawAuthor) · \(rawArtist)"
            } else {
                author = !rawAuthor.isEmpty ? rawAuthor : rawArtist
            }

            var cover = (Self.stringValue(b["coverUrl"]) ?? Self.stringValue(b["cover"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cover.hasPrefix("//") {
                cover = "https:" + cover
            } else if cover.hasPrefix("/") && !siteURL.isEmpty {
                cover = JsElement.resolveAbsoluteURL(raw: cover, baseURL: siteURL)
            }

            let rawIntro = HTMLTokenizer.stripTagsAndDecodeEntities(
                Self.stringValue(b["intro"]) ?? Self.stringValue(b["description"]) ?? ""
            )
            let rawStatus = (Self.stringValue(b["status"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let intro: String
            if !rawStatus.isEmpty && !rawIntro.isEmpty {
                intro = "\(rawStatus) · \(rawIntro)"
            } else {
                intro = !rawIntro.isEmpty ? rawIntro : rawStatus
            }

            // 注意：prelude.js 的 int() 在字段缺失时返回 0，因此列表里的 chapterCount == 0 只代表「未知」，
            // 不能据此过滤；是否可播放以 UnplayableBookStore（详情页确认无章节）为准。
            let chapterCount = Self.intValue(b["chapterCount"]) ?? 0
            let ref = BookRef(
                sourceID: sourceID,
                bookURL: bookURL,
                title: title,
                author: author,
                cover: cover,
                intro: intro,
                chapterCount: chapterCount
            )
            if UnplayableBookStore.shared.contains(ref.id) { continue }
            if !seenIDs.contains(ref.id) {
                seenIDs.insert(ref.id)
                books.append(ref)
            }
        }

        // McpGuide.md 第 2 节：categoryPage 返回字段为 nextUrl（兼容 nextPageUrl）
        let nextPageURL = Self.stringValue(dict["nextUrl"]) ?? Self.stringValue(dict["nextPageUrl"])
        let totalPage = Self.intValue(dict["totalPage"])
        return DiscoverPageDTO(
            books: books,
            nextPageURL: (nextPageURL?.isEmpty == true) ? nil : nextPageURL,
            totalPage: totalPage
        )
    }

    private func decodeBookDetail(from jsonStr: String, sourceID: String, bookURL: String) throws -> BookDetailDTO {
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.parseFailed("书籍详情数据格式无效")
        }
        let siteURL = (try? ensureRoute(for: sourceID)?.meta.url) ?? ""
        let baseForRelative = bookURL.hasPrefix("http") ? bookURL : siteURL

        let title = Self.stringValue(dict["title"]) ?? ""
        let rawAuthor = Self.stringValue(dict["author"]) ?? ""
        let rawArtist = Self.stringValue(dict["artist"]) ?? ""
        let author: String
        if !rawAuthor.isEmpty && !rawArtist.isEmpty && rawAuthor != rawArtist {
            author = "\(rawAuthor) · 演播 \(rawArtist)"
        } else {
            author = !rawAuthor.isEmpty ? rawAuthor : rawArtist
        }
        var coverURL = Self.stringValue(dict["coverUrl"]) ?? Self.stringValue(dict["cover"]) ?? ""
        if coverURL.hasPrefix("//") {
            coverURL = "https:" + coverURL
        } else if coverURL.hasPrefix("/") && !baseForRelative.isEmpty {
            coverURL = JsElement.resolveAbsoluteURL(raw: coverURL, baseURL: baseForRelative)
        }
        let rawIntro = Self.stringValue(dict["intro"]) ?? Self.stringValue(dict["description"]) ?? ""
        let intro = HTMLTokenizer.stripTagsAndDecodeEntities(rawIntro)
        let status = Self.stringValue(dict["status"]) ?? ""

        let rawEpisodes = (dict["episodes"] as? [[String: Any]]) ?? []
        var chapters: [ChapterDTO] = []
        var seenURLs = Set<String>()

        for ep in rawEpisodes {
            let idx = chapters.count
            let rawTitle = (Self.stringValue(ep["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let epTitle = rawTitle.isEmpty ? "第 \(idx + 1) 章" : rawTitle
            var epURL = (Self.stringValue(ep["url"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !epURL.isEmpty else { continue }
            if epURL.hasPrefix("//") {
                epURL = "https:" + epURL
            } else if epURL.hasPrefix("/") && !baseForRelative.isEmpty {
                epURL = JsElement.resolveAbsoluteURL(raw: epURL, baseURL: baseForRelative)
            }
            guard !seenURLs.contains(epURL) else { continue }
            seenURLs.insert(epURL)
            let duration = Self.intValue(ep["duration"])
            chapters.append(ChapterDTO(index: idx, title: epTitle, url: epURL, durationSec: duration))
        }

        return BookDetailDTO(
            title: title,
            author: author,
            coverURL: coverURL,
            intro: intro,
            status: status,
            chapters: chapters
        )
    }

    nonisolated private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            return s
        }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return nil
            }
            return n.stringValue
        }
        return nil
    }

    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private func ensureRoute(for sourceID: String) throws -> (packageID: String, sourceIndex: Int, meta: ParsedSourceMeta)? {
        if let route = sourceRouting[sourceID] {
            return route
        }
        // 仅在尚未扫描过磁盘时才重建；已扫描仍未命中说明书源已被删除，直接返回 nil
        guard !hasScannedDisk else { return nil }
        reloadInstalledPackages()
        return sourceRouting[sourceID]
    }

    private func ensureContextPool(for packageID: String) throws -> PackageContextPool {
        if let existing = activePools[packageID] {
            return existing
        }
        let pkgDir = pluginsRootDirectory.appendingPathComponent(packageID, isDirectory: true)
        let manifestURL = pkgDir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: manifestData)

        var files: [String: Data] = ["manifest.json": manifestData]
        for script in manifest.scripts {
            let clean = (script as NSString).lastPathComponent
            let sURL = pkgDir.appendingPathComponent(clean)
            if let d = try? Data(contentsOf: sURL) {
                files[clean] = d
            }
        }
        let (ctx, metas) = try Self.createIsolatedContext(packageID: packageID, manifest: manifest, scriptFiles: files)
        let pool = PackageContextPool(
            packageID: packageID,
            manifest: manifest,
            scriptFiles: files,
            initialContext: ctx,
            sources: metas
        )
        activePools[packageID] = pool
        return pool
    }

    /// 创建拥有独立 JSVirtualMachine 的隔离 JSContext，并安装原生桥接与插件脚本
    nonisolated static func createIsolatedContext(
        packageID: String,
        manifest: PluginPackageManifest,
        scriptFiles: [String: Data]
    ) throws -> (JSContext, [ParsedSourceMeta]) {
        guard let vm = JSVirtualMachine(),
              let ctx = JSContext(virtualMachine: vm) else {
            throw PluginError.parseFailed("无法初始化 JavaScriptCore 虚拟机")
        }

        var startupError: String?
        ctx.exceptionHandler = { _, exc in
            if let msg = exc?.toString(), startupError == nil {
                startupError = msg
            }
        }

        // 安装 ssts 100% 兼容的原生块函数与 __bridge / __invokeSafe
        JsHostBridge.installNative(into: ctx, packageID: packageID)

        let preludeCode = Self.loadPreludeScript()
        ctx.evaluateScript(preludeCode)
        if let err = startupError {
            throw PluginError.parseFailed("prelude.js 执行错误: \(err)")
        }

        for scriptName in manifest.scripts {
            let cleanName = (scriptName as NSString).lastPathComponent
            guard let scriptData = scriptFiles[scriptName] ?? scriptFiles[cleanName],
                  let scriptText = Self.decodeScriptText(scriptData) else {
                throw PluginError.parseFailed("脚本不存在或文件名无效：\(cleanName)")
            }
            ctx.evaluateScript(scriptText, withSourceURL: URL(string: "plugin://\(packageID)/\(cleanName)"))
            if let err = startupError {
                throw PluginError.parseFailed("脚本 \(cleanName) 执行错误: \(err)")
            }
        }

        ctx.exceptionHandler = nil

        guard let metaFn = ctx.objectForKeyedSubscript("__meta"),
              let metaVal = metaFn.call(withArguments: []),
              let metaJson = metaVal.toString(),
              let metaData = metaJson.data(using: .utf8),
              let rawMetas = try? JSONSerialization.jsonObject(with: metaData) as? [[String: Any]] else {
            throw PluginError.parseFailed("无法读取插件注册的书源元数据")
        }

        let parsed: [ParsedSourceMeta] = rawMetas.enumerated().compactMap { idx, dict in
            guard let id = stringValue(dict["id"]),
                  let name = stringValue(dict["name"]) else { return nil }
            let url = stringValue(dict["url"]) ?? ""
            let summary = stringValue(dict["description"]) ?? stringValue(dict["summary"]) ?? ""
            let group = stringValue(dict["group"]) ?? "听书"
            let methods = Set((dict["methods"] as? [String]) ?? [])
            let searchable = (dict["searchable"] as? Bool) ?? methods.contains("search")
            let discoverable = (dict["discoverable"] as? Bool) ?? methods.contains("categoryMenus")
            let multipleEpisodePages = (dict["multipleEpisodePages"] as? Bool) ?? false
            let enabledByDefault = (dict["enabledByDefault"] as? Bool) ?? true
            let loginURL = stringValue(dict["loginUrl"]) ?? ""
            let loginDesktop = (dict["loginDesktop"] as? Bool) ?? false
            let loginScript = stringValue(dict["loginScript"]) ?? ""
            let loginAltURL = stringValue(dict["loginAltUrl"]) ?? ""
            let hasCheckLogin = methods.contains("checkLogin")
            let hasSearchVerification = methods.contains("searchVerificationUrl")
            let searchVerificationDesktop = (dict["searchVerificationDesktop"] as? Bool) ?? false
            let searchDelaySeconds = intValue(dict["searchDelaySeconds"]) ?? 0

            var configItems: [SourceConfigItem] = []
            if let rawConfig = dict["config"] as? [[String: Any]] {
                configItems = rawConfig.compactMap { c in
                    guard let k = stringValue(c["key"]),
                          let t = stringValue(c["label"]) ?? stringValue(c["title"]) else { return nil }
                    return SourceConfigItem(
                        key: k,
                        title: t,
                        defaultValue: stringValue(c["default"]) ?? "",
                        summary: stringValue(c["summary"]) ?? ""
                    )
                }
            }
            return ParsedSourceMeta(
                index: idx,
                id: id,
                name: name,
                url: url,
                summary: summary,
                group: group,
                searchable: searchable,
                discoverable: discoverable,
                multipleEpisodePages: multipleEpisodePages,
                enabledByDefault: enabledByDefault,
                loginURL: loginURL,
                loginDesktop: loginDesktop,
                loginScript: loginScript,
                loginAltURL: loginAltURL,
                hasCheckLogin: hasCheckLogin,
                hasSearchVerification: hasSearchVerification,
                searchVerificationDesktop: searchVerificationDesktop,
                searchDelaySeconds: searchDelaySeconds,
                methods: methods,
                config: configItems
            )
        }
        return (ctx, parsed)
    }

    private func reclaimIdlePools() {
        let now = Date()
        for (pkgID, pool) in activePools {
            if now.timeIntervalSince(pool.lastUsedAt) > idleLimitSeconds {
                pool.invalidate()
                activePools.removeValue(forKey: pkgID)
            }
        }
    }

    /// 脚本文本解码：兼容 UTF-8（含 BOM）、UTF-16 与 GB18030（国内书源脚本常见），避免「文件不是有效书源」的误判
    nonisolated static func decodeScriptText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }

    private static let cachedPreludeScript: String = {
        if let url = Bundle.main.url(forResource: "prelude", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return fallbackPreludeScript
    }()

    nonisolated static func loadPreludeScript() -> String {
        cachedPreludeScript
    }

    private static let fallbackPreludeScript: String = """
        var __sources = [];
        function at(obj, path) {
          if (obj === null || obj === undefined) return null;
          var parts = String(path).split('.');
          for (var i = 0; i < parts.length; i++) {
            var k = parts[i];
            if (k === '') continue;
            if (obj === null || obj === undefined) return null;
            if (Array.isArray(obj)) {
              var n = parseInt(k, 10);
              if (isNaN(n)) return null;
              if (n < 0) n += obj.length;
              obj = obj[n];
            } else if (typeof obj === 'object') {
              obj = obj[k];
            } else { return null; }
          }
          return obj === undefined ? null : obj;
        }
        function str(obj, path) {
          var v = (path === undefined || path === null) ? obj : at(obj, path);
          if (v === null || v === undefined) return '';
          return typeof v === 'object' ? JSON.stringify(v) : String(v);
        }
        function int(obj, path, def) {
          var n = parseInt(str(obj, path), 10);
          return isNaN(n) ? (def === undefined ? 0 : def) : n;
        }
        function items(obj, path) {
          var v = (path === undefined || path === null) ? obj : at(obj, path);
          return Array.isArray(v) ? v.filter(function (x) { return x !== null && x !== undefined; }) : [];
        }
        function regexInt(input, re, def) {
          var m = re.exec(input || '');
          var n = m ? parseInt(m[1], 10) : NaN;
          return isNaN(n) ? (def === undefined ? 1 : def) : n;
        }
        function parseJson(text) {
          text = String(text).trim();
          var c = text.charAt(0);
          if (c !== '{' && c !== '[') {
            var l = text.search(/[{[]/);
            var r = Math.max(text.lastIndexOf('}'), text.lastIndexOf(']'));
            if (l >= 0 && r > l) text = text.substring(l, r + 1);
          }
          return JSON.parse(text);
        }
        function __makeHost(j) {
          function un(s) {
            var r = JSON.parse(s);
            if (r.e !== undefined) {
              var err = new Error(r.e);
              var m = /^HTTP (\\d+)/.exec(r.e);
              if (m) err.status = parseInt(m[1], 10);
              if (r.c) err.cancelled = true;
              throw err;
            }
            return r.v;
          }
          function opt(o) { return o ? JSON.stringify(o) : null; }
          function fn(o, name) { return o && typeof o[name] === 'function' ? o[name] : null; }
          function s(v) { return v === null || v === undefined ? null : String(v); }
          var h = {
            sourceId: String(j.getSourceId()),
            userAgent: function (desktop) { return j.userAgent(!!desktop); },
            webViewUA: function () { try { return j.webViewUA ? String(j.webViewUA() || '') : ''; } catch (e) { return ''; } },
            getString: function (url, o) { return un(j.request(String(url), opt(o))); },
            getHtml: function (url, o) { return j.parseHtml(h.getString(url, o), String(url)); },
            getJson: function (url, o) { return parseJson(h.getString(url, o)); },
            getStrings: function (urls, o, concurrency) { return un(j.requestAll(JSON.stringify(urls), opt(o), concurrency || 4)); },
            finalUrl: function (url, o) { return un(j.finalUrl(String(url), opt(o))); },
            fetch: function (url, o) { return un(j.fetch(String(url), opt(o))); },
            status: function (url, o) { return un(j.status(String(url), opt(o))); },
            parseHtml: function (html, baseUrl) { return j.parseHtml(String(html), s(baseUrl)); },
            render: function (url, o) { return un(j.render(String(url), opt(o), fn(o, 'parse'))); },
            sniff: function (url, o) { return un(j.sniff(String(url), opt(o), fn(o, 'validate'))); },
            cookies: function (url) { return j.cookies(String(url)); },
            playsAnyDownload: true,
            getPref: function (key, def) {
              var v = j.getPref(String(key));
              return (v === null || v === undefined) ? (def === undefined ? null : def) : v;
            },
            setPref: function (key, value) { j.setPref(String(key), s(value)); },
            toast: function (msg) { j.toast(String(msg)); },
            log: function (msg) { j.log(String(msg)); },
            progress: function (info) { j.progress(s(info)); },
            sleep: function (ms) { j.sleep(Math.max(0, Math.round(ms))); },
            readCache: function (name) {
              var v = j.readCache(String(name));
              return v === undefined ? null : v;
            },
            writeCache: function (name, text) { j.writeCache(String(name), String(text)); },
            cacheAge: function (name) { return j.cacheAge(String(name)); },
            base64Decode: function (v) { return j.base64Decode(String(v)); },
            base64Encode: function (v) { return j.base64Encode(String(v)); },
            md5: function (v) { return j.md5(String(v)); },
            sha256: function (v) { return j.sha256(String(v)); },
            aesEcbDecrypt: function (data, key) { return j.aesEcbDecrypt(String(data), String(key)); },
            uuid: function () { return j.uuid(); },
            htmlDecode: function (v) { return j.htmlDecode(String(v)); }
          };
          return h;
        }
        function registerSource(source) {
          if (!source || !source.id || !source.name) throw new Error('registerSource：缺少 id 或 name');
          source.host = __makeHost(__bridge.host(String(source.id), String(source.name)));
          __sources.push(source);
          return source;
        }
        function __meta() {
          return JSON.stringify(__sources.map(function (src) {
            var meta = { methods: [] };
            for (var k in src) {
              if (k === 'host') continue;
              if (typeof src[k] === 'function') meta.methods.push(k);
              else meta[k] = src[k];
            }
            return meta;
          }));
        }
        function __invoke(index, name, argsJson) {
          var src = __sources[index];
          if (!src) return null;
          var f = src[name];
          if (typeof f !== 'function') return null;
          var r = f.apply(src, JSON.parse(argsJson));
          return (r === undefined || r === null) ? null : JSON.stringify(r);
        }
        """
}
