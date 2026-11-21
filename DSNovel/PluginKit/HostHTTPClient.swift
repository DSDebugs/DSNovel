import Foundation
import JavaScriptCore

/// 仅获取响应头即取消传输的 Delegate（对齐 ssts HeaderOnlyDelegate，避免服务端拒绝 HEAD 请求返回 403/405，并支持内置解析器重定向白名单校验）
private final class HeaderOnlySessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let redirectValidator: ((String) -> Bool)?
    private(set) var httpResponse: HTTPURLResponse?
    private(set) var completionError: Error?
    private(set) var blockedRedirectURL: String?

    init(redirectValidator: ((String) -> Bool)? = nil) {
        self.redirectValidator = redirectValidator
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let target = request.url?.absoluteString, JsHostBridge.isPrivateOrLocalURL(target) {
            lock.lock()
            self.blockedRedirectURL = target
            lock.unlock()
            task.cancel()
            completionHandler(nil)
            return
        }
        if let validator = redirectValidator, let target = request.url?.absoluteString, !validator(target) {
            lock.lock()
            self.blockedRedirectURL = target
            lock.unlock()
            task.cancel()
            completionHandler(nil)
            return
        }
        let sanitized = JsHostBridge.sanitizedRedirectRequest(request, from: response.url ?? task.originalRequest?.url)
        completionHandler(sanitized)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.httpResponse = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let blocked = blockedRedirectURL {
            self.completionError = NSError(
                domain: "JsHostBridge",
                code: -403,
                userInfo: [NSLocalizedDescriptionKey: "内置解析器禁止重定向至未声明域名：\(blocked)"]
            )
        } else if let nsErr = error as NSError?, nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled && httpResponse != nil {
            self.completionError = nil
        } else {
            self.completionError = error
        }
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

/// 重定向白名单与跨域 Cookie 清洗守护 Delegate：逐跳校验目标主机（如启用白名单），并在 302 跨域重定向时剥离原手动 Cookie 头
final class ParserRedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let allowedHosts: [String]?
    private let extraHosts: [String]
    private(set) var blockedRedirectURL: String?

    init(allowedHosts: [String]?, extraHosts: [String] = []) {
        self.allowedHosts = allowedHosts
        self.extraHosts = extraHosts
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let target = request.url?.absoluteString, JsHostBridge.isPrivateOrLocalURL(target) {
            lock.lock()
            self.blockedRedirectURL = target
            lock.unlock()
            task.cancel()
            completionHandler(nil)
            return
        }
        if let allowedHosts {
            guard let target = request.url?.absoluteString,
                  JsHostBridge.isHostAllowed(target, allowedHosts: allowedHosts, extraHosts: extraHosts) else {
                let blocked = request.url?.absoluteString ?? ""
                lock.lock()
                self.blockedRedirectURL = blocked
                lock.unlock()
                task.cancel()
                completionHandler(nil)
                return
            }
        }
        let sanitized = JsHostBridge.sanitizedRedirectRequest(request, from: response.url ?? task.originalRequest?.url)
        completionHandler(sanitized)
    }

    var blockedURL: String? {
        lock.lock()
        defer { lock.unlock() }
        return blockedRedirectURL
    }
}

/// 共享短生命周期 HTTP 连接池：复用单一 URLSession（连接与 TLS 会话复用），按请求通过 iOS 15+ `task.delegate` 挂载守卫/Header 代理（P7）
private enum HostHTTPSessionPool {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpCookieStorage = .shared
        return URLSession(configuration: config)
    }()
}

// MARK: - JsHostBridge 网络请求、重定向守护、并发请求与响应解码扩展

extension JsHostBridge {
    func performRequest(_ url: String, optionsJson: String?) -> String {
        do {
            let (statusCode, body, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: false)
            guard (200..<300).contains(statusCode) else {
                return wrapError("HTTP \(statusCode)")
            }
            return wrapValue(body)
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func performRequestAll(_ urlsJson: String, optionsJson: String?, concurrency: Int) -> String {
        guard let data = urlsJson.data(using: .utf8),
              let urls = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return wrapValue([Any]())
        }
        if urls.isEmpty { return wrapValue([Any]()) }

        var optionsArray: [[String: Any]?] = Array(repeating: nil, count: urls.count)
        if let optionsJson, let optData = optionsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: optData) {
            if let arr = parsed as? [[String: Any]?] {
                for i in 0..<min(urls.count, arr.count) {
                    optionsArray[i] = arr[i]
                }
            } else if let dict = parsed as? [String: Any] {
                optionsArray = Array(repeating: dict, count: urls.count)
            }
        }

        let maxConcurrent = min(max(concurrency, 1), 8)
        let workerCount = min(maxConcurrent, urls.count)
        let serializedOptions: [String?] = optionsArray.map { dict in
            guard let dict,
                  let d = try? JSONSerialization.data(withJSONObject: dict),
                  let s = String(data: d, encoding: .utf8) else {
                return nil
            }
            return s
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var nextIndex = 0
        var results: [Any] = Array(repeating: NSNull(), count: urls.count)
        var spawnedTasks: [URLSessionDataTask] = []
        var didTimeOut = false

        // S2：仅启动 min(maxConcurrent, urls.count) 个固定并发 Worker 从共享索引领取任务，消除无界 GCD 线程派发
        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while true {
                    lock.lock()
                    if didTimeOut || nextIndex >= urls.count {
                        lock.unlock()
                        return
                    }
                    let idx = nextIndex
                    nextIndex += 1
                    lock.unlock()

                    let u = urls[idx]
                    let singleOptJson = serializedOptions[idx]
                    if let (code, body, _) = try? self.performSyncHTTP(
                        url: u,
                        optionsJson: singleOptJson,
                        headOnly: false,
                        onTaskCreated: { task in
                            lock.lock()
                            let expired = didTimeOut
                            if !expired {
                                spawnedTasks.append(task)
                            }
                            lock.unlock()
                            if expired {
                                task.cancel()
                            }
                        }
                    ), (200..<300).contains(code) {
                        lock.lock()
                        if !didTimeOut {
                            results[idx] = body
                        }
                        lock.unlock()
                    }
                }
            }
        }
        let waitResult = group.wait(timeout: .now() + 25)
        lock.lock()
        if waitResult == .timedOut {
            didTimeOut = true
        }
        let tasksToCancel = (waitResult == .timedOut) ? spawnedTasks : []
        let snapshot = results
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
        return wrapValue(snapshot)
    }

    func performFinalUrl(_ url: String, optionsJson: String?) -> String {
        do {
            let (_, _, resolved) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: true, defaultRangeZero: true)
            return wrapValue(resolved)
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func performFetch(_ url: String, optionsJson: String?) -> String {
        do {
            let (statusCode, body, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: false)
            return wrapValue(["status": statusCode, "body": body])
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func performStatus(_ url: String, optionsJson: String?) -> String {
        do {
            let (statusCode, _, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: true)
            return wrapValue(statusCode)
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func performRender(_ url: String, optionsJson: String?, parseFn: JSValue?) -> String {
        var opts: [String: Any] = [:]
        if let optionsJson, let d = optionsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            opts = parsed
        }
        let desktop = (opts["desktop"] as? Bool) ?? false
        let script = opts["script"] as? String
        let timeoutMs = (opts["timeout"] as? Int) ?? 25000
        let hasValidParseFn = (parseFn != nil && !parseFn!.isUndefined && !parseFn!.isNull)

        // 若处于主应用进程（存在窗口场景），优先使用 WKWebView 真实渲染以支持动态 JS 章节与人机验证后 DOM
        if HeadlessWebViewService.shared.canUseWebView {
            if let rendered = try? HeadlessWebViewService.shared.render(
                url: url,
                desktop: desktop,
                script: script,
                timeoutMs: timeoutMs,
                accept: { candidateHTML in
                    if hasValidParseFn, let fn = parseFn {
                        if let parsed = fn.call(withArguments: [candidateHTML]),
                           !parsed.isUndefined, !parsed.isNull,
                           let str = parsed.toString(), !str.isEmpty, str != "false", str != "null" {
                            return str
                        }
                        return nil
                    }
                    return candidateHTML.isEmpty ? nil : candidateHTML
                }
            ) {
                return wrapValue(rendered)
            }
        }

        // 无头环境或 WebView 渲染未命中时回退至 HTTP 请求 + parse(html)
        do {
            let (_, html, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: false)
            if hasValidParseFn, let fn = parseFn {
                if let parsed = fn.call(withArguments: [html]),
                   !parsed.isUndefined, !parsed.isNull {
                    if let str = parsed.toString(), !str.isEmpty, str != "false", str != "null" {
                        return wrapValue(parsed.toObject() ?? str)
                    }
                }
            }
            return wrapValue(html)
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func performSniff(_ url: String, optionsJson: String?, validateFn: JSValue?) -> String {
        var opts: [String: Any] = [:]
        if let optionsJson, let d = optionsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            opts = parsed
        }
        let desktop = (opts["desktop"] as? Bool) ?? false
        let script = opts["script"] as? String
        let timeoutMs = (opts["timeout"] as? Int) ?? 25000
        let hasCustomValidate = (validateFn != nil && !validateFn!.isUndefined && !validateFn!.isNull)

        if HeadlessWebViewService.shared.canUseWebView {
            if let sniffed = try? HeadlessWebViewService.shared.sniff(
                url: url,
                desktop: desktop,
                script: script,
                timeoutMs: timeoutMs,
                accept: { candidate, isElement in
                    if hasCustomValidate, let fn = validateFn {
                        return fn.call(withArguments: [candidate])?.toBool() == true
                    }
                    return isElement || Self.isLikelyMediaURL(candidate)
                }
            ) {
                return wrapValue(sniffed)
            }
        }

        do {
            let (_, body, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: false)
            if let regex = Self.sniffMediaRegex {
                let ns = body as NSString
                let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    let candidate = ns.substring(with: m.range)
                    if hasCustomValidate, let fn = validateFn {
                        if let ok = fn.call(withArguments: [candidate]), ok.toBool() {
                            return wrapValue(candidate)
                        }
                    } else {
                        return wrapValue(candidate)
                    }
                }
            }
            return wrapError("没有嗅探到音频地址（可能需要登录或网站已失效）")
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    static func isLikelyMediaURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        let exts = [".mp3", ".m4a", ".m3u8", ".aac", ".flac", ".ogg", ".wav", ".mp4", ".wma"]
        return exts.contains { lower.contains($0) }
    }

    static func makeRequestURL(from raw: String, relativeTo baseURLString: String? = nil) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            trimmed = "https:" + trimmed
        } else if !trimmed.lowercased().hasPrefix("http://"),
                  !trimmed.lowercased().hasPrefix("https://"),
                  let baseStr = baseURLString,
                  let baseURL = makeRequestURL(from: baseStr) {
            if let rel = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                return rel
            }
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
               let rel = URL(string: encoded, relativeTo: baseURL)?.absoluteURL {
                return rel
            }
        }
        if let u = URL(string: trimmed) {
            return u
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let u = URL(string: encoded) {
            return u
        }
        return nil
    }

    func performSyncHTTP(
        url: String,
        optionsJson: String?,
        headOnly: Bool,
        defaultRangeZero: Bool = false,
        onTaskCreated: ((URLSessionDataTask) -> Void)? = nil
    ) throws -> (Int, String, String) {
        guard let requestURL = Self.makeRequestURL(from: url) else {
            throw URLError(.badURL)
        }
        var opts: [String: Any] = [:]
        if let optionsJson, !optionsJson.isEmpty, optionsJson != "null",
           let d = optionsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            opts = parsed
        }

        var req = URLRequest(url: requestURL, timeoutInterval: 10)
        let desktop = (opts["desktop"] as? Bool) ?? false
        req.setValue(userAgent(desktop), forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/json,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        if let method = opts["method"] as? String, !method.isEmpty {
            req.httpMethod = method.uppercased()
        }

        if let headers = opts["headers"] as? [String: Any] {
            for (k, v) in headers {
                if let s = v as? String {
                    req.setValue(s, forHTTPHeaderField: k)
                } else if let n = v as? NSNumber {
                    req.setValue(n.stringValue, forHTTPHeaderField: k)
                }
            }
        }

        if defaultRangeZero && req.value(forHTTPHeaderField: "Range") == nil {
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }

        // 合并全局跨子域 Cookie（对齐 ssts Http.cookieHeaderIfNeeded）
        let storedCookies = CookieSync.cookies(for: requestURL)
        if !storedCookies.isEmpty {
            if let existingCookie = req.value(forHTTPHeaderField: "Cookie"), !existingCookie.isEmpty {
                let existingNames = Set(
                    existingCookie.split(separator: ";").compactMap { part -> String? in
                        let kv = part.split(separator: "=", maxSplits: 1)
                        return kv.first.map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                )
                let extra = storedCookies
                    .filter { !existingNames.contains($0.name) }
                    .map { "\($0.name)=\($0.value)" }
                if !extra.isEmpty {
                    req.setValue(([existingCookie] + extra).joined(separator: "; "), forHTTPHeaderField: "Cookie")
                }
            } else {
                let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }

        let explicitEncoding = opts["encoding"] as? String
        if let bodyStr = opts["body"] as? String {
            if req.httpMethod == "GET" || req.httpMethod == nil {
                req.httpMethod = "POST"
            }
            if let exp = explicitEncoding?.lowercased(), exp.contains("gb") {
                let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                req.httpBody = bodyStr.data(using: String.Encoding(rawValue: gbk)) ?? bodyStr.data(using: .utf8)
            } else {
                req.httpBody = bodyStr.data(using: .utf8)
            }
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                let cType = (opts["contentType"] as? String) ?? "application/x-www-form-urlencoded; charset=UTF-8"
                req.setValue(cType, forHTTPHeaderField: "Content-Type")
            }
        } else if let contentType = opts["contentType"] as? String, !contentType.isEmpty {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let enforceHosts = allowedHosts

        let sharedSession = HostHTTPSessionPool.shared

        if headOnly {
            let redirectValidator: ((String) -> Bool)? = enforceHosts.map { hosts in
                let extras = self.extraNetworkHosts
                return { target in
                    JsHostBridge.isHostAllowed(target, allowedHosts: hosts, extraHosts: extras)
                }
            }
            let delegate = HeaderOnlySessionDelegate(redirectValidator: redirectValidator)
            let task = sharedSession.dataTask(with: req)
            task.delegate = delegate
            registerActiveTask(task)
            onTaskCreated?(task)
            defer { unregisterActiveTask(task) }
            task.resume()
            if !delegate.wait(timeout: 10) {
                task.cancel()
                throw URLError(.timedOut)
            }
            if let err = delegate.completionError {
                throw err
            }
            let statusCode = delegate.httpResponse?.statusCode ?? 200
            let finalURL = delegate.httpResponse?.url?.absoluteString ?? url
            Self.persistResponseCookies(delegate.httpResponse, fallbackURL: requestURL)
            return (statusCode, "", finalURL)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpResponse: HTTPURLResponse?
        var requestError: Error?

        // M-P0-8：所有请求均挂载重定向守护代理，确保 302 跨域重定向时剥离原手动 Cookie 头并按目标域重新匹配
        let redirectGuard = ParserRedirectGuardDelegate(
            allowedHosts: enforceHosts,
            extraHosts: extraNetworkHosts
        )

        let task = sharedSession.dataTask(with: req) { data, resp, err in
            responseData = data
            httpResponse = resp as? HTTPURLResponse
            requestError = err
            semaphore.signal()
        }
        task.delegate = redirectGuard
        registerActiveTask(task)
        onTaskCreated?(task)
        defer { unregisterActiveTask(task) }
        task.resume()

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        if let blocked = redirectGuard.blockedURL {
            throw NSError(
                domain: "JsHostBridge",
                code: -403,
                userInfo: [NSLocalizedDescriptionKey: "内置解析器禁止重定向至未声明域名：\(blocked)"]
            )
        }
        if let requestError {
            throw requestError
        }
        Self.persistResponseCookies(httpResponse, fallbackURL: requestURL)
        let statusCode = httpResponse?.statusCode ?? 200
        let finalURL = httpResponse?.url?.absoluteString ?? url
        let rawData = responseData ?? Data()
        let text = Self.decodeText(data: rawData, response: httpResponse, explicitEncoding: explicitEncoding)
        return (statusCode, text, finalURL)
    }

    /// M-P0-8：302 跨域（或协议降级）重定向时剥离原手动 Cookie 请求头，并按重定向目标域重新匹配注入（无匹配则彻底移除）
    static func sanitizedRedirectRequest(_ request: URLRequest, from originalURL: URL?) -> URLRequest {
        guard let targetURL = request.url else { return request }
        let origHost = originalURL?.host?.lowercased()
        let targetHost = targetURL.host?.lowercased()
        let origScheme = originalURL?.scheme?.lowercased()
        let targetScheme = targetURL.scheme?.lowercased()
        let isCrossDomainOrSchemeChange = (origHost != targetHost) || (origScheme != targetScheme)
        guard isCrossDomainOrSchemeChange else { return request }

        var updated = request
        if let headers = updated.allHTTPHeaderFields {
            for key in headers.keys where key.lowercased() == "cookie" {
                updated.setValue(nil, forHTTPHeaderField: key)
            }
        }
        updated.setValue(nil, forHTTPHeaderField: "Cookie")
        let targetCookieHeader = CookieSync.cookieHeader(for: targetURL)
        if !targetCookieHeader.isEmpty {
            updated.setValue(targetCookieHeader, forHTTPHeaderField: "Cookie")
        }
        return updated
    }

    static func persistResponseCookies(_ response: HTTPURLResponse?, fallbackURL: URL) {
        guard let response,
              let headerFields = response.allHeaderFields as? [String: String] else { return }
        let url = response.url ?? fallbackURL
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        if !cookies.isEmpty {
            for c in cookies {
                CookieSync.storeCookie(c)
            }
            CookieSync.persistToDefaults()
        }
    }

    static func decodeText(data: Data, response: HTTPURLResponse?, explicitEncoding: String?) -> String {
        guard !data.isEmpty else { return "" }
        let gbkEnc = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        var decoded: String?
        if let exp = explicitEncoding?.lowercased(), (exp.contains("gb") || exp.contains("936")) {
            decoded = String(data: data, encoding: gbkEnc)
        }
        if decoded == nil,
           let respEncoding = response?.textEncodingName?.lowercased(),
           (respEncoding.contains("gb") || respEncoding.contains("936")) {
            decoded = String(data: data, encoding: gbkEnc)
        }
        if decoded == nil, let utf8 = String(data: data, encoding: .utf8) {
            let prefixSample = String(utf8.prefix(2048)).lowercased()
            if prefixSample.contains("charset=gb") || prefixSample.contains("charset=\"gb") || prefixSample.contains("charset='gb") {
                decoded = String(data: data, encoding: gbkEnc) ?? utf8
            } else {
                decoded = utf8
            }
        }
        if decoded == nil {
            decoded = String(data: data, encoding: gbkEnc) ?? String(decoding: data, as: UTF8.self)
        }
        var result = decoded ?? ""
        if result.first == "\u{FEFF}" {
            result.removeFirst()
        }
        return result
    }

    func wrapValue(_ value: Any) -> String {
        let payload: [String: Any] = ["v": value]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"v\":null}"
        }
        return str
    }

    func wrapError(_ message: String) -> String {
        let payload: [String: Any] = ["e": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"e\":\"Error\"}"
        }
        return str
    }
}
