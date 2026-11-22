import DSCore
import Foundation
import JavaScriptCore

/// 暴露给 prelude.js / prelude_parser.js 的单源宿主对象协议（强绑定 ownerID，禁止跨源访问）
@objc public protocol HostHandleJSExport: JSExport {
    func getSourceId() -> String
    func userAgent(_ desktop: Bool) -> String
    func webViewUA() -> String
    func request(_ url: String, _ optionsJSON: String?) -> String
    func requestAll(_ urlsJSON: String, _ optionsJSON: String?, _ concurrency: Int) -> String
    func finalUrl(_ url: String, _ optionsJSON: String?) -> String
    func fetch(_ url: String, _ optionsJSON: String?) -> String
    func status(_ url: String, _ optionsJSON: String?) -> String
    func parseHtml(_ html: String, _ baseURL: String?) -> HTMLDocumentNode
    func render(_ url: String, _ optionsJSON: String?, _ parseFn: JSValue?) -> String
    func sniff(_ url: String, _ optionsJSON: String?, _ validateFn: JSValue?) -> String
    func cookies(_ url: String) -> String
    func getPref(_ key: String) -> String?
    func setPref(_ key: String, _ value: String?)
    func toast(_ message: String)
    func log(_ message: String)
    func progress(_ info: String?)
    func sleep(_ ms: Int)
    func readCache(_ name: String) -> String?
    func writeCache(_ name: String, _ text: String)
    func cacheAge(_ name: String) -> Int
    func base64Decode(_ value: String) -> String
    func base64Encode(_ value: String) -> String
    func md5(_ value: String) -> String
    func sha256(_ value: String) -> String
    func aesEcbDecrypt(_ data: String, _ key: String) -> String
    func uuid() -> String
    func htmlDecode(_ value: String) -> String
}

/// 暴露给 prelude.js 的工厂对象（prelude 初始化捕获后即 delete this.__bridge，杜绝伪造）
@objc public protocol HostBridgeFactoryJSExport: JSExport {
    func host(_ sourceID: String, _ sourceName: String) -> HostHandleJS
}

@objc public final class HostBridgeFactoryJS: NSObject, HostBridgeFactoryJSExport, @unchecked Sendable {
    private let fixedOwnerID: String?
    private let policyProvider: @Sendable (String) -> SourcePermissionPolicy
    private let httpClient: HostHTTPClient
    private let cookieVault: CookieVault
    private let cacheRoot: URL
    private let logger: DSDiagnosticLogStore
    private let webViewService: HeadlessWebViewService
    private let cancellationToken: SandboxCancellationToken

    public init(
        fixedOwnerID: String?,
        policyProvider: @escaping @Sendable (String) -> SourcePermissionPolicy,
        httpClient: HostHTTPClient,
        cookieVault: CookieVault,
        cacheRoot: URL,
        logger: DSDiagnosticLogStore,
        webViewService: HeadlessWebViewService = HeadlessWebViewService(),
        cancellationToken: SandboxCancellationToken = SandboxCancellationToken()
    ) {
        self.fixedOwnerID = fixedOwnerID
        self.policyProvider = policyProvider
        self.httpClient = httpClient
        self.cookieVault = cookieVault
        self.cacheRoot = cacheRoot
        self.logger = logger
        self.webViewService = webViewService
        self.cancellationToken = cancellationToken
    }

    public func host(_ sourceID: String, _ sourceName: String) -> HostHandleJS {
        let boundOwner = fixedOwnerID ?? sourceID
        let policy = policyProvider(boundOwner)
        return HostHandleJS(
            ownerID: boundOwner,
            policy: policy,
            httpClient: httpClient,
            cookieVault: cookieVault,
            cacheRoot: cacheRoot,
            logger: logger,
            webViewService: webViewService,
            cancellationToken: cancellationToken
        )
    }
}

/// 仅限同步同线程回调使用的 JSValue Sendable 包装（sniffMediaURL 在当前 JS 线程同步调用 validator）
private final class SameThreadJSValueBox: @unchecked Sendable {
    let value: JSValue
    init(_ value: JSValue) { self.value = value }
}

@objc public final class HostHandleJS: NSObject, HostHandleJSExport, @unchecked Sendable {
    internal let ownerID: String
    internal let policy: SourcePermissionPolicy
    internal let httpClient: HostHTTPClient
    internal let cookieVault: CookieVault
    internal let ownerCacheDir: URL
    internal let logger: DSDiagnosticLogStore
    internal let webViewService: HeadlessWebViewService
    internal let cancellationToken: SandboxCancellationToken

    public init(
        ownerID: String,
        policy: SourcePermissionPolicy,
        httpClient: HostHTTPClient,
        cookieVault: CookieVault,
        cacheRoot: URL,
        logger: DSDiagnosticLogStore,
        webViewService: HeadlessWebViewService = HeadlessWebViewService(),
        cancellationToken: SandboxCancellationToken = SandboxCancellationToken()
    ) {
        self.ownerID = ownerID
        self.policy = policy
        self.httpClient = httpClient
        self.cookieVault = cookieVault
        self.ownerCacheDir = cacheRoot.appendingPathComponent(DSCrypto.sha256Hex(ownerID), isDirectory: true)
        self.logger = logger
        self.webViewService = webViewService
        self.cancellationToken = cancellationToken
        try? FileManager.default.createDirectory(at: self.ownerCacheDir, withIntermediateDirectories: true)
    }

    public func getSourceId() -> String { ownerID }
    public func userAgent(_ desktop: Bool) -> String {
        desktop ? HostHTTPClient.desktopUserAgent : HostHTTPClient.mobileUserAgent
    }
    public func webViewUA() -> String { HostHTTPClient.mobileUserAgent }

    public func request(_ url: String, _ optionsJSON: String?) -> String {
        performHTTP(url: url, optionsJSON: optionsJSON) { resp in
            if resp.statusCode >= 400 {
                return Self.encodeError("HTTP \(resp.statusCode)")
            }
            return Self.encodeValue(resp.bodyString)
        }
    }

    public func requestAll(_ urlsJSON: String, _ optionsJSON: String?, _ concurrency: Int) -> String {
        performRequestAll(urlsJSON: urlsJSON, optionsJSON: optionsJSON, concurrency: concurrency)
    }

    public func finalUrl(_ url: String, _ optionsJSON: String?) -> String {
        performHTTP(url: url, optionsJSON: optionsJSON) { resp in
            Self.encodeValue(resp.finalURL.absoluteString)
        }
    }

    public func fetch(_ url: String, _ optionsJSON: String?) -> String {
        performHTTP(url: url, optionsJSON: optionsJSON) { resp in
            let payload: [String: Any] = [
                "status": resp.statusCode,
                "url": resp.finalURL.absoluteString,
                "headers": resp.headers,
                "body": resp.bodyString
            ]
            return Self.encodeValue(payload)
        }
    }

    public func status(_ url: String, _ optionsJSON: String?) -> String {
        performHTTP(url: url, optionsJSON: optionsJSON) { resp in
            Self.encodeValue(resp.statusCode)
        }
    }

    public func parseHtml(_ html: String, _ baseURL: String?) -> HTMLDocumentNode {
        HTMLDocumentNode.parse(html: html, baseURL: baseURL ?? "")
    }

    public func render(_ url: String, _ optionsJSON: String?, _ parseFn: JSValue?) -> String {
        guard !cancellationToken.isCancelled else {
            return Self.encodeError("请求已取消", cancelled: true)
        }
        guard let parsedURL = URL(string: url) else {
            return Self.encodeError("Invalid URL: \(url)")
        }
        let (desktop, timeout) = Self.parseWebViewOptions(optionsJSON, defaultTimeout: 10.0)
        do {
            try policy.validate(url: parsedURL)
            let cookies = syncBridge(fallback: [HTTPCookie]()) { await self.cookieVault.matchingCookies(for: parsedURL) }
            let ua = desktop ? HostHTTPClient.desktopUserAgent : HostHTTPClient.mobileUserAgent
            let html = try webViewService.renderHTML(
                url: parsedURL,
                userAgent: ua,
                cookies: cookies,
                timeoutSeconds: timeout,
                policy: policy,
                desktop: desktop,
                cancellationToken: cancellationToken
            )
            if let fn = parseFn, !fn.isUndefined, !fn.isNull {
                let ctx = fn.context
                ctx?.exception = nil
                let parsed = fn.call(withArguments: [html])
                if let exc = ctx?.exception {
                    let msg = exc.toString() ?? "render parse callback error"
                    ctx?.exception = nil
                    return Self.encodeError(msg)
                }
                if let parsed, !parsed.isUndefined, !parsed.isNull {
                    if let obj = parsed.toObject(), JSONSerialization.isValidJSONObject(["v": obj]) {
                        return Self.encodeValue(obj)
                    }
                    if let jsonStr = ctx?.objectForKeyedSubscript("JSON")?
                        .invokeMethod("stringify", withArguments: [parsed])?.toString(),
                       let data = jsonStr.data(using: .utf8),
                       let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                        return Self.encodeValue(decoded)
                    }
                    return Self.encodeValue(parsed.toString() ?? html)
                }
            }
            return Self.encodeValue(html)
        } catch is CancellationError {
            return Self.encodeError("请求已取消", cancelled: true)
        } catch {
            return Self.encodeError(error.localizedDescription)
        }
    }

    public func sniff(_ url: String, _ optionsJSON: String?, _ validateFn: JSValue?) -> String {
        guard !cancellationToken.isCancelled else {
            return Self.encodeError("请求已取消", cancelled: true)
        }
        guard let parsedURL = URL(string: url) else {
            return Self.encodeError("Invalid URL: \(url)")
        }
        let (desktop, timeout) = Self.parseWebViewOptions(optionsJSON, defaultTimeout: 15.0)
        do {
            try policy.validate(url: parsedURL)
            let cookies = syncBridge(fallback: [HTTPCookie]()) { await self.cookieVault.matchingCookies(for: parsedURL) }
            let ua = desktop ? HostHTTPClient.desktopUserAgent : HostHTTPClient.mobileUserAgent
            let customValidator: SameThreadJSValueBox? = {
                guard let fn = validateFn, !fn.isUndefined, !fn.isNull else { return nil }
                return SameThreadJSValueBox(fn)
            }()
            let found = try webViewService.sniffMediaURL(
                url: parsedURL,
                userAgent: ua,
                cookies: cookies,
                timeoutSeconds: timeout,
                policy: policy,
                desktop: desktop,
                cancellationToken: cancellationToken
            ) { candidate in
                if let box = customValidator {
                    let ctx = box.value.context
                    ctx?.exception = nil
                    let res = box.value.call(withArguments: [candidate])
                    if let exc = ctx?.exception {
                        let msg = exc.toString() ?? "sniff validate callback error"
                        ctx?.exception = nil
                        self.log("sniff 校验回调异常：\(msg)")
                        return false
                    }
                    return res?.toBool() == true
                }
                let lower = candidate.lowercased()
                return lower.contains(".mp3") || lower.contains(".m4a") || lower.contains(".m3u8") || lower.contains(".aac") || lower.contains("audio")
            }
            return Self.encodeValue(found)
        } catch is CancellationError {
            return Self.encodeError("请求已取消", cancelled: true)
        } catch {
            return Self.encodeError(error.localizedDescription)
        }
    }

    public func cookies(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return "" }
        do {
            try policy.validate(url: parsed)
        } catch {
            return ""
        }
        let pol = policy
        return syncBridge(fallback: "") {
            (try? await self.cookieVault.authorizedCookieHeader(for: parsed, policy: pol)) ?? ""
        }
    }

    public func getPref(_ key: String) -> String? {
        syncBridge(fallback: nil) { await self.cookieVault.getSecret(ownerID: self.ownerID, key: key) }
    }

    public func setPref(_ key: String, _ value: String?) {
        syncBridge(fallback: ()) { await self.cookieVault.setSecret(value, ownerID: self.ownerID, key: key) }
    }

    public func toast(_ message: String) { log("TOAST: \(message)") }

    public func log(_ message: String) {
        let cat: DSLogCategory = .plugin
        let owner = ownerID
        let store = logger
        Task { await store.record(category: cat, level: "INFO", message: "[\(owner)] \(message)") }
    }

    public func progress(_ info: String?) {}

    public func sleep(_ ms: Int) {
        let clamped = max(0, min(ms, 5_000))
        guard clamped > 0, !cancellationToken.isCancelled else { return }
        let sem = DispatchSemaphore(value: 0)
        let tokenID = cancellationToken.onCancel { sem.signal() }
        defer { cancellationToken.removeCancelHandler(tokenID) }
        _ = sem.wait(timeout: .now() + .milliseconds(clamped))
    }

    public func readCache(_ name: String) -> String? {
        try? String(contentsOf: safeCacheFileURL(name: name), encoding: .utf8)
    }

    public func writeCache(_ name: String, _ text: String) {
        try? Data(text.utf8).write(to: safeCacheFileURL(name: name), options: [.atomic])
    }

    public func cacheAge(_ name: String) -> Int {
        let file = safeCacheFileURL(name: name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let mod = attrs[.modificationDate] as? Date else { return -1 }
        return max(0, Int(Date().timeIntervalSince(mod)))
    }

    public func base64Decode(_ value: String) -> String { DSCrypto.base64Decode(value) }
    public func base64Encode(_ value: String) -> String { DSCrypto.base64Encode(value) }
    public func md5(_ value: String) -> String { DSCrypto.md5Hex(value) }
    public func sha256(_ value: String) -> String { DSCrypto.sha256Hex(value) }
    public func aesEcbDecrypt(_ data: String, _ key: String) -> String {
        DSCrypto.aesEcbDecrypt(base64OrHexData: data, key: key)
    }
    public func uuid() -> String { UUID().uuidString.lowercased() }
    public func htmlDecode(_ value: String) -> String { DSCrypto.htmlDecode(value) }

    /// 缓存键强制 SHA-256 映射到 owner 专属目录，数学上杜绝 ../ 目录穿越
    private func safeCacheFileURL(name: String) -> URL {
        ownerCacheDir.appendingPathComponent("\(DSCrypto.sha256Hex(name)).cache")
    }

    private static func parseWebViewOptions(_ optionsJSON: String?, defaultTimeout: TimeInterval) -> (desktop: Bool, timeout: TimeInterval) {
        var desktop = false
        var timeout = defaultTimeout
        if let raw = optionsJSON,
           let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = dict["desktop"] as? Bool { desktop = d }
            if let t = (dict["timeout"] as? Double) ?? (dict["timeout"] as? Int).map(Double.init), t > 0 {
                timeout = t > 100 ? t / 1000.0 : t
            }
        }
        return (desktop, timeout)
    }
}
