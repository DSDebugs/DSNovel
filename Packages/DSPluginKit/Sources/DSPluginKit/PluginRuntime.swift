import DSCore
import Foundation
import JavaScriptCore

/// 沙箱指令枚举（ARC-07：替代 @Sendable (JSContext) -> String 闭包，彻底消除 Swift 6 严格并发诊断）
internal enum SandboxCommand: Sendable {
    case meta
    case invoke(method: String, argsJSON: String)
}

/// 书源导入预览结果（用于 Q5 未声明 hosts 风险弹窗判断）
public struct SourcePreviewResult: Sendable, Equatable {
    public let sources: [SourceMetaDTO]
    public let scriptBody: String
    public let undeclaredHostSourceIDs: [String]

    public var requiresCompatConfirmation: Bool { !undeclaredHostSourceIDs.isEmpty }

    public init(sources: [SourceMetaDTO], scriptBody: String, undeclaredHostSourceIDs: [String]) {
        self.sources = sources
        self.scriptBody = scriptBody
        self.undeclaredHostSourceIDs = undeclaredHostSourceIDs
    }
}

/// ES5 书源运行时引擎（AUD-13：固定串行队列池 + prelude 后立即删除 __bridge；ARC-04：单实例 HeadlessWebViewService）
public actor PluginRuntime: AudioResolving {
    internal let preludeScript: String
    internal let httpClient: HostHTTPClient
    internal let cookieVault: CookieVault
    internal let pool: JSContextPool
    internal let cacheRoot: URL
    internal let logger: DSDiagnosticLogStore
    internal let builtinParser: BuiltinParserEngine?
    internal let webViewService: HeadlessWebViewService

    internal var registeredScripts: [String: (meta: SourceMetaDTO, script: String)] = [:]
    internal var consecutiveTimeoutCounts: [String: Int] = [:]
    internal var circuitBreakerUntil: [String: Date] = [:]

    public init(
        preludeScript: String,
        httpClient: HostHTTPClient,
        cookieVault: CookieVault,
        pool: JSContextPool = JSContextPool(maxSlots: 4, labelPrefix: "com.dsnovel.app.plugin.js"),
        cacheRoot: URL? = nil,
        logger: DSDiagnosticLogStore,
        builtinParser: BuiltinParserEngine? = nil,
        webViewService: HeadlessWebViewService = HeadlessWebViewService()
    ) {
        self.preludeScript = preludeScript
        self.httpClient = httpClient
        self.cookieVault = cookieVault
        self.pool = pool
        self.cacheRoot = cacheRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("DSPluginCache", isDirectory: true)
        self.logger = logger
        self.builtinParser = builtinParser
        self.webViewService = webViewService
    }

    public func registerSources(_ items: [(meta: SourceMetaDTO, scriptBody: String)]) {
        registeredScripts.removeAll()
        consecutiveTimeoutCounts.removeAll()
        circuitBreakerUntil.removeAll()
        for item in items {
            registeredScripts[item.meta.id] = (item.meta, item.scriptBody)
        }
    }

    internal func checkCircuitBreaker(ownerID: String?) throws {
        guard let ownerID, !ownerID.hasPrefix("preview-"),
              let until = circuitBreakerUntil[ownerID] else { return }
        if Date() < until {
            throw PluginSecurityError.scriptError("书源连续超时已临时熔断，请稍后重试")
        }
        circuitBreakerUntil.removeValue(forKey: ownerID)
        consecutiveTimeoutCounts.removeValue(forKey: ownerID)
    }

    internal func recordExecutionSuccess(ownerID: String?) {
        guard let ownerID, !ownerID.hasPrefix("preview-") else { return }
        consecutiveTimeoutCounts.removeValue(forKey: ownerID)
        circuitBreakerUntil.removeValue(forKey: ownerID)
    }

    internal func recordExecutionTimeout(ownerID: String?) {
        guard let ownerID, !ownerID.hasPrefix("preview-") else { return }
        let next = (consecutiveTimeoutCounts[ownerID] ?? 0) + 1
        consecutiveTimeoutCounts[ownerID] = next
        if next >= 2 {
            circuitBreakerUntil[ownerID] = Date().addingTimeInterval(60)
        }
    }

    /// 安全预览导入脚本（强制 allowNetwork = false + 5s 看门狗超时）
    public func previewSources(scriptBody: String, timeoutSeconds: TimeInterval = 5.0) async throws -> SourcePreviewResult {
        let previewOwner = "preview-\(UUID().uuidString)"
        let metaJSON = try await evaluateInSandbox(
            scriptBody: scriptBody,
            fixedOwnerID: previewOwner,
            allowNetwork: false,
            timeoutSeconds: timeoutSeconds,
            command: .meta
        )
        let parsed = Self.decodeMetaList(metaJSON)
        let undeclared = parsed.filter { !$0.hasDeclaredHosts }.map(\.id)
        return SourcePreviewResult(
            sources: parsed,
            scriptBody: scriptBody,
            undeclaredHostSourceIDs: undeclared
        )
    }

    public func search(sourceID: String, keyword: String, page: Int = 1) async throws -> [BookSummaryDTO] {
        try await searchPage(sourceID: sourceID, keyword: keyword, page: page).books
    }

    public func searchPage(sourceID: String, keyword: String, page: Int = 1) async throws -> SourceContractAdapter.DiscoverPageResult {
        guard let entry = registeredScripts[sourceID] else {
            throw PluginSecurityError.scriptError("未找到书源：\(sourceID)")
        }
        let method = SourceContractAdapter.resolveMethodName(requested: "search", available: entry.meta.methods)
        let args = try Self.encodeJSON([keyword, page])
        let raw = try await invokeMethod(entry: entry, method: method, argsJSON: args)
        try SourceContractAdapter.checkMissingMethodSentinel(raw)
        return SourceContractAdapter.decodeDiscoverPage(
            raw,
            sourceID: entry.meta.id,
            sourceName: entry.meta.name,
            requestedURL: "",
            requestedPage: page
        )
    }

    public func discoverCategories(sourceID: String) async throws -> [DiscoverCategoryDTO] {
        guard let entry = registeredScripts[sourceID] else { return [] }
        let method = SourceContractAdapter.resolveMethodName(requested: "discoverCategories", available: entry.meta.methods)
        let raw = try await invokeMethod(entry: entry, method: method, argsJSON: "[]")
        try SourceContractAdapter.checkMissingMethodSentinel(raw)
        return SourceContractAdapter.decodeCategories(raw, sourceID: sourceID)
    }

    public func discoverBooks(sourceID: String, categoryURL: String, page: Int = 1) async throws -> [BookSummaryDTO] {
        try await discoverPage(sourceID: sourceID, categoryURL: categoryURL, page: page).books
    }

    public func discoverPage(sourceID: String, categoryURL: String, page: Int = 1) async throws -> SourceContractAdapter.DiscoverPageResult {
        guard let entry = registeredScripts[sourceID] else {
            throw PluginSecurityError.scriptError("未找到书源：\(sourceID)")
        }
        let method = SourceContractAdapter.resolveMethodName(requested: "discover", available: entry.meta.methods)
        let args = try Self.encodeJSON([categoryURL, page])
        let raw = try await invokeMethod(entry: entry, method: method, argsJSON: args)
        try SourceContractAdapter.checkMissingMethodSentinel(raw)
        return SourceContractAdapter.decodeDiscoverPage(
            raw,
            sourceID: entry.meta.id,
            sourceName: entry.meta.name,
            requestedURL: categoryURL,
            requestedPage: page
        )
    }

    public func bookDetail(sourceID: String, book: BookSummaryDTO, loadFullPages: Bool = true) async throws -> BookDetailDTO {
        guard let entry = registeredScripts[sourceID] else {
            throw PluginSecurityError.scriptError("未找到书源：\(sourceID)")
        }
        let method = SourceContractAdapter.resolveMethodName(requested: "detail", available: entry.meta.methods)
        let args = try Self.encodeJSON([book.bookURL, true, loadFullPages])
        let raw = try await invokeMethod(entry: entry, method: method, argsJSON: args)
        try SourceContractAdapter.checkMissingMethodSentinel(raw)
        return SourceContractAdapter.decodeBookDetail(raw, fallback: book)
    }

    public func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool
    ) async throws -> AudioStreamDTO {
        try await resolveAudio(
            sourceID: sourceID,
            bookID: bookID,
            chapter: chapter,
            preferredQuality: preferredQuality,
            forDownload: forDownload,
            bypassCache: false
        )
    }

    public func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool,
        bypassCache: Bool
    ) async throws -> AudioStreamDTO {
        if let parser = builtinParser {
            do {
                if let resolved = try await parser.tryResolveAudio(
                    sourceID: sourceID,
                    bookID: bookID,
                    chapter: chapter,
                    preferredQuality: preferredQuality,
                    forDownload: forDownload,
                    bypassCache: bypassCache
                ) {
                    return resolved
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let secErr as PluginSecurityError {
                if case .parserRejected = secErr { throw secErr }
            } catch {
                // 内置解析器非取消/非业务拒绝失败时回退到书源自身音频解析
            }
        }
        guard let entry = registeredScripts[sourceID] else {
            throw PluginSecurityError.scriptError("书源已移除或禁用：\(sourceID)")
        }
        if !entry.meta.methods.contains("audio"),
           let directURL = URL(string: chapter.url),
           let scheme = directURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            try SSRFGuard.validatePublicURL(directURL)
            let isHLS = directURL.pathExtension.lowercased() == "m3u8"
            return AudioStreamDTO(url: directURL, qualityTier: preferredQuality, isHLS: isHLS)
        }
        let method = SourceContractAdapter.resolveMethodName(requested: "audio", available: entry.meta.methods)
        let qualityArg = SourceContractAdapter.qualityArgument(for: preferredQuality)
        let args = try Self.encodeJSON([chapter.url, qualityArg])
        let raw = try await invokeMethod(entry: entry, method: method, argsJSON: args)
        try SourceContractAdapter.checkMissingMethodSentinel(raw)
        return try SourceContractAdapter.decodeAudioStream(raw, fallbackQuality: preferredQuality)
    }

    /// B13-03：调用书源 checkLogin() 校验当前 Cookie 登录态并返回账号昵称
    public func checkLogin(sourceID: String) async throws -> String {
        guard let entry = registeredScripts[sourceID] else {
            throw PluginSecurityError.scriptError("未找到书源：\(sourceID)")
        }
        let raw = try await invokeMethod(entry: entry, method: "checkLogin", argsJSON: "[]")
        try SourceContractAdapter.checkMissingMethodSentinel(raw)
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRaw.isEmpty || trimmedRaw.lowercased() == "null" {
            return ""
        }
        if let data = trimmedRaw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            if decoded is NSNull { return "" }
            if let str = decoded as? String {
                let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.lowercased() == "null" ? "" : clean
            }
        }
        let clean = trimmedRaw.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return clean.lowercased() == "null" ? "" : clean
    }

    private func invokeMethod(
        entry: (meta: SourceMetaDTO, script: String),
        method: String,
        argsJSON: String
    ) async throws -> String {
        try await evaluateInSandbox(
            scriptBody: entry.script,
            fixedOwnerID: entry.meta.id,
            allowNetwork: true,
            timeoutSeconds: 20.0,
            command: .invoke(method: method, argsJSON: argsJSON)
        )
    }
}
