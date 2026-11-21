import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore

@objc protocol JsHostBridgeExports: JSExport {
    func getSourceId() -> String
    @objc(userAgent:) func userAgent(_ desktop: Bool) -> String
    func webViewUA() -> String
    @objc(request::) func request(_ url: String, _ optionsJson: JSValue?) -> String
    @objc(requestAll:::) func requestAll(_ urlsJson: String, _ optionsJson: JSValue?, _ concurrency: Int) -> String
    @objc(finalUrl::) func finalUrl(_ url: String, _ optionsJson: JSValue?) -> String
    @objc(fetch::) func fetch(_ url: String, _ optionsJson: JSValue?) -> String
    @objc(status::) func status(_ url: String, _ optionsJson: JSValue?) -> String
    @objc(parseHtml::) func parseHtml(_ html: String, _ baseUrl: JSValue?) -> JsElement
    @objc(render:::) func render(_ url: String, _ optionsJson: JSValue?, _ parseFn: JSValue?) -> String
    @objc(sniff:::) func sniff(_ url: String, _ optionsJson: JSValue?, _ validateFn: JSValue?) -> String
    @objc(cookies:) func cookies(_ url: String) -> String
    @objc(getPref:) func getPref(_ key: String) -> Any
    @objc(setPref::) func setPref(_ key: String, _ value: JSValue?)
    @objc(toast:) func toast(_ message: String)
    @objc(log:) func log(_ message: String)
    @objc(progress:) func progress(_ info: JSValue?)
    @objc(sleep:) func sleep(_ ms: Int)
    @objc(readCache:) func readCache(_ name: String) -> Any
    @objc(writeCache::) func writeCache(_ name: String, _ text: String)
    @objc(cacheAge:) func cacheAge(_ name: String) -> Double
    @objc(base64Decode:) func base64Decode(_ input: String) -> String
    @objc(base64Encode:) func base64Encode(_ input: String) -> String
    @objc(md5:) func md5(_ input: String) -> String
    @objc(sha256:) func sha256(_ input: String) -> String
    @objc(aesEcbDecrypt::) func aesEcbDecrypt(_ base64Data: String, _ keyHex: String) -> String
    func uuid() -> String
    @objc(htmlDecode:) func htmlDecode(_ input: String) -> String
}

@objc protocol JsRootBridgeExports: JSExport {
    @objc(host::) func host(_ sourceId: String, _ sourceName: String) -> JsHostBridge
}

@objc final class JsRootBridge: NSObject, JsRootBridgeExports {
    let packageID: String

    init(packageID: String) {
        self.packageID = packageID
        super.init()
    }

    func host(_ sourceId: String, _ sourceName: String) -> JsHostBridge {
        JsHostBridge(packageID: packageID, sourceId: sourceId, sourceName: sourceName)
    }
}

/// 插件宿主桥接实现：严格对齐 ssts 原生块桥接签名，消除 JS null/undefined 桥接歧义，支持 UTF-8/GBK 自动识别与同步并发请求
@objc final class JsHostBridge: NSObject, JsHostBridgeExports {
    let packageID: String
    let sourceId: String
    let sourceName: String

    /// 书源作用域：plugin_pref_<sourceID>.<key>；内置解析作用域：parser_pref_<parserID>.<key>
    var prefPrefix: String = "plugin_pref_"
    /// 缓存命名空间；nil 表示沿用 sourceId（书源行为完全不变），内置解析为 "Parser/<parserID>"
    var cacheNamespace: String?
    /// 是否允许网络与持久化读写（预览校验阶段为 false，隔离 pref/cache 写入与跨源读取）
    var allowNetwork: Bool = true
    /// 非 nil 时，host.log 写入内置解析日志环形缓冲（供「查看日志」展示）
    var parserLogID: String?
    /// 内置解析器允许访问的域名白名单（非空时同时用于 302 重定向逐跳校验）
    var allowedHosts: [String]?
    var extraNetworkHosts: [String] = []

    private let activeTasksLock = NSLock()
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    private static let contextBridgesLock = NSLock()
    private static nonisolated(unsafe) let contextBridges = NSMapTable<JSContext, JsHostBridge>.weakToStrongObjects()

    static let sniffMediaRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https?://[^\\s\"'<>\\\\]+\\.(?:m4a|mp3|m3u8|aac|flac|ogg|wav)(?:\\?[^\\s\"'<>\\\\]*)?",
        options: .caseInsensitive
    )

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    func registerActiveTask(_ task: URLSessionDataTask) {
        activeTasksLock.lock()
        activeTasks[ObjectIdentifier(task)] = task
        activeTasksLock.unlock()
    }

    func unregisterActiveTask(_ task: URLSessionDataTask) {
        activeTasksLock.lock()
        activeTasks.removeValue(forKey: ObjectIdentifier(task))
        activeTasksLock.unlock()
    }

    func cancelActiveTasks() {
        activeTasksLock.lock()
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        activeTasksLock.unlock()
        for t in tasks {
            t.cancel()
        }
    }

    /// 通知与指定 JSContext 绑定的 JsHostBridge 取消当前正在阻塞的所有 URLSessionDataTask
    static func cancelActiveTasks(for ctx: JSContext) {
        contextBridgesLock.lock()
        let bridge = contextBridges.object(forKey: ctx)
        contextBridgesLock.unlock()
        bridge?.cancelActiveTasks()
    }

    init(packageID: String, sourceId: String, sourceName: String) {
        CookieSync.bootstrap()
        self.packageID = packageID
        self.sourceId = sourceId
        self.sourceName = sourceName
        super.init()
    }

    /// 抽取 JSValue 中的可选字符串，避免 JavaScriptCore 将 null/undefined 强转为 "null"/"undefined"
    static func optionalString(from jsValue: JSValue?) -> String? {
        guard let jsValue, !jsValue.isNull, !jsValue.isUndefined else {
            return nil
        }
        guard let str = jsValue.toString(), str != "null", str != "undefined" else {
            return nil
        }
        return str
    }

    /// 将原生块函数与 __bridge / __invokeSafe 注入到指定 JSContext（100% 匹配 ssts PluginEngine.installNative）
    static func installNative(into ctx: JSContext, packageID: String, allowNetwork: Bool = true) {
        installNative(into: ctx,
                      ownerID: packageID,
                      ownerName: packageID,
                      prefPrefix: "plugin_pref_",
                      parserLogID: nil,
                      cacheNamespace: nil,
                      allowNetwork: allowNetwork)
    }

    private static func errorEnvelope(_ message: String) -> String {
        let payload: [String: Any] = ["e": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{\"e\":\"request blocked\"}"
    }

    /// H2：判断目标主机名是否为回环、链路本地或 RFC1918/ULA 私网地址（防止第三方书源 SSRF / 局域网探测）
    static func isPrivateOrLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zoneIdx = host.firstIndex(of: "%") {
            host = String(host[..<zoneIdx])
        }
        guard !host.isEmpty else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0" || host == "::1" || host == "::" {
            return true
        }
        // IPv6 ULA (fc00::/7) / link-local (fe80::/10) / IPv4-mapped (::ffff:...)
        if host.contains(":") {
            if host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") {
                return true
            }
            if host.hasPrefix("::ffff:") {
                let mapped = String(host.dropFirst("::ffff:".count))
                return isPrivateOrLocalHost(mapped)
            }
            return false
        }
        // IPv4 dotted quad
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, let o0 = UInt8(parts[0]), let o1 = UInt8(parts[1]), UInt8(parts[2]) != nil, UInt8(parts[3]) != nil {
            if o0 == 0 || o0 == 10 || o0 == 127 { return true }
            if o0 == 169 && o1 == 254 { return true }
            if o0 == 172 && (16...31).contains(o1) { return true }
            if o0 == 192 && o1 == 168 { return true }
            if o0 == 100 && (64...127).contains(o1) { return true } // CGNAT 100.64.0.0/10
        }
        return false
    }

    static func isPrivateOrLocalURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        return isPrivateOrLocalHost(host)
    }

    /// 校验目标 URL 是否落在允许的域名白名单内（强制仅允许 http/https 协议，精确本域或 `.domain` 子域；H-06 / M-P0-7）
    static func isHostAllowed(_ urlString: String, allowedHosts: [String], extraHosts: [String] = []) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let combined = allowedHosts + extraHosts
        if combined.isEmpty { return false }
        return combined.contains { raw in
            let p = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !p.isEmpty else { return false }
            return host == p || host.hasSuffix("." + p)
        }
    }

    /// 内置解析专用：pref 走 Keychain(parser_pref_)、缓存走 Parser/<parserID>、日志进解析日志缓冲、按声明域名收敛权限（H-06）
    static func installParserNative(
        into ctx: JSContext,
        parserID: String,
        parserName: String,
        allowedHosts: [String] = [],
        allowNetwork: Bool = true
    ) {
        installNative(into: ctx,
                      ownerID: parserID,
                      ownerName: parserName,
                      prefPrefix: "parser_pref_",
                      parserLogID: parserID,
                      cacheNamespace: "Parser/\(parserID)",
                      allowedHosts: allowedHosts,
                      allowNetwork: allowNetwork)
    }

    private static func installNative(
        into ctx: JSContext,
        ownerID: String,
        ownerName: String,
        prefPrefix: String,
        parserLogID: String?,
        cacheNamespace: String?,
        allowedHosts: [String]? = nil,
        allowNetwork: Bool = true
    ) {
        let helper = JsHostBridge(packageID: ownerID, sourceId: ownerID, sourceName: ownerName)
        helper.prefPrefix = prefPrefix
        helper.parserLogID = parserLogID
        helper.cacheNamespace = cacheNamespace
        helper.allowNetwork = allowNetwork
        let isParserMode = (parserLogID != nil)
        let extraNetworkHosts = isParserMode ? ["raw.githubusercontent.com"] : []
        helper.allowedHosts = allowedHosts
        helper.extraNetworkHosts = extraNetworkHosts
        // M-P0-7：在 Swift 闭包内硬绑定当前插件 ownerID 与 cacheNamespace，绝不信任 JS 传入的 fullKey 或 srcId
        let boundOwnerID = Self.sanitizeStorageIdentifier(ownerID)
        let boundCacheNamespace = cacheNamespace ?? boundOwnerID
        contextBridgesLock.lock()
        contextBridges.setObject(helper, forKey: ctx)
        contextBridgesLock.unlock()

        let nUserAgent: @convention(block) (Bool) -> String = { desktop in
            desktop ? Self.desktopUA : Self.mobileUA
        }
        let nWebViewUA: @convention(block) () -> String = {
            Self.mobileUA
        }
        let nRequest: @convention(block) (String, JSValue) -> String = { url, opts in
            if !allowNetwork {
                return Self.errorEnvelope("预览校验阶段禁止网络请求")
            }
            if Self.isPrivateOrLocalURL(url) {
                return Self.errorEnvelope("安全策略禁止访问本机或局域网地址：\(url)")
            }
            if let allowedHosts,
               !Self.isHostAllowed(url, allowedHosts: allowedHosts, extraHosts: extraNetworkHosts) {
                return Self.errorEnvelope("内置解析器禁止访问未声明域名：\(url)")
            }
            return helper.performRequest(url, optionsJson: Self.optionalString(from: opts))
        }
        let nRequestAll: @convention(block) (String, JSValue, Int) -> String = { urlsJson, opts, concurrency in
            if !allowNetwork {
                return Self.errorEnvelope("预览校验阶段禁止网络请求")
            }
            return helper.performRequestAll(urlsJson, optionsJson: Self.optionalString(from: opts), concurrency: concurrency)
        }
        let nFinalUrl: @convention(block) (String, JSValue) -> String = { url, opts in
            if !allowNetwork {
                return Self.errorEnvelope("预览校验阶段禁止网络请求")
            }
            if Self.isPrivateOrLocalURL(url) {
                return Self.errorEnvelope("安全策略禁止访问本机或局域网地址：\(url)")
            }
            if let allowedHosts,
               !Self.isHostAllowed(url, allowedHosts: allowedHosts, extraHosts: extraNetworkHosts) {
                return Self.errorEnvelope("内置解析器禁止访问未声明域名：\(url)")
            }
            return helper.performFinalUrl(url, optionsJson: Self.optionalString(from: opts))
        }
        let nStatus: @convention(block) (String, JSValue) -> String = { url, opts in
            if !allowNetwork {
                return Self.errorEnvelope("预览校验阶段禁止网络请求")
            }
            if Self.isPrivateOrLocalURL(url) {
                return Self.errorEnvelope("安全策略禁止访问本机或局域网地址：\(url)")
            }
            if let allowedHosts,
               !Self.isHostAllowed(url, allowedHosts: allowedHosts, extraHosts: extraNetworkHosts) {
                return Self.errorEnvelope("内置解析器禁止访问未声明域名：\(url)")
            }
            return helper.performStatus(url, optionsJson: Self.optionalString(from: opts))
        }
        let nFetch: @convention(block) (String, JSValue) -> String = { url, opts in
            if !allowNetwork {
                return Self.errorEnvelope("预览校验阶段禁止网络请求")
            }
            if Self.isPrivateOrLocalURL(url) {
                return Self.errorEnvelope("安全策略禁止访问本机或局域网地址：\(url)")
            }
            if let allowedHosts,
               !Self.isHostAllowed(url, allowedHosts: allowedHosts, extraHosts: extraNetworkHosts) {
                return Self.errorEnvelope("内置解析器禁止访问未声明域名：\(url)")
            }
            return helper.performFetch(url, optionsJson: Self.optionalString(from: opts))
        }
        let nParseHtml: @convention(block) (String, JSValue) -> JsElement = { html, baseVal in
            let base = Self.optionalString(from: baseVal) ?? ""
            return JsElement.parse(html: html, baseURL: base)
        }
        let nRender: @convention(block) (String, JSValue, JSValue) -> String = { url, opts, parseFn in
            if !allowNetwork {
                return Self.errorEnvelope("预览校验阶段禁止网络请求")
            }
            return helper.performRender(url, optionsJson: Self.optionalString(from: opts), parseFn: parseFn)
        }
        let nSniff: @convention(block) (String, JSValue, JSValue) -> String = { url, opts, validateFn in
            if !allowNetwork {
                return Self.errorEnvelope("预览校验阶段禁止网络请求")
            }
            if Self.isPrivateOrLocalURL(url) {
                return Self.errorEnvelope("安全策略禁止访问本机或局域网地址：\(url)")
            }
            return helper.performSniff(url, optionsJson: Self.optionalString(from: opts), validateFn: validateFn)
        }
        let nCookies: @convention(block) (String) -> String = { url in
            if !allowNetwork { return "" }
            if let allowedHosts,
               !Self.isHostAllowed(url, allowedHosts: allowedHosts) {
                return ""
            }
            return helper.cookies(url)
        }
        let nGetPref: @convention(block) (String) -> Any = { rawKey in
            // M-P0-7：预览态（allowNetwork == false）隔离 pref 跨源读取
            guard allowNetwork else { return NSNull() }
            let cleanKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanKey.isEmpty else { return NSNull() }
            let storageKey = "\(prefPrefix)\(boundOwnerID).\(cleanKey)"
            if prefPrefix == "parser_pref_" {
                return BuiltinParserKeychain.string(forKey: storageKey) ?? NSNull()
            }
            if let val = UserDefaults.standard.string(forKey: storageKey) {
                return val
            }
            return NSNull()
        }
        let nSetPref: @convention(block) (String, JSValue) -> Void = { rawKey, val in
            // M-P0-7：预览态（allowNetwork == false）禁止 pref 写入
            guard allowNetwork else { return }
            let cleanKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanKey.isEmpty else { return }
            let storageKey = "\(prefPrefix)\(boundOwnerID).\(cleanKey)"
            let strVal = Self.optionalString(from: val)
            if prefPrefix == "parser_pref_" {
                BuiltinParserKeychain.set(strVal, forKey: storageKey)
                return
            }
            if let s = strVal {
                UserDefaults.standard.set(s, forKey: storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storageKey)
            }
        }
        let nToast: @convention(block) (String) -> Void = { msg in
            helper.toast(msg)
        }
        let nLog: @convention(block) (String) -> Void = { msg in
            helper.log(msg)
        }
        let nProgress: @convention(block) (String, JSValue) -> Void = { _, _ in }
        let nSleep: @convention(block) (Int) -> Any = { ms in
            let maxMs = isParserMode ? 500 : 5000
            let clamped = min(max(ms, 0), maxMs)
            if clamped > 0 {
                Thread.sleep(forTimeInterval: Double(clamped) / 1000.0)
            }
            return NSNull()
        }
        let nReadCache: @convention(block) (String) -> Any = { name in
            // M-P0-7：预览态隔离缓存读取，且硬绑定 boundCacheNamespace 防路径穿越
            guard allowNetwork,
                  let url = Self.safeCacheFileURL(namespace: boundCacheNamespace, name: name, createDirectory: false) else {
                return NSNull()
            }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            return NSNull()
        }
        let nWriteCache: @convention(block) (String, String) -> Void = { name, text in
            // M-P0-7：预览态禁止缓存写入，且硬绑定 boundCacheNamespace 防路径穿越
            guard allowNetwork,
                  let url = Self.safeCacheFileURL(namespace: boundCacheNamespace, name: name, createDirectory: true) else {
                return
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let nCacheAge: @convention(block) (String) -> Double = { name in
            guard allowNetwork,
                  let url = Self.safeCacheFileURL(namespace: boundCacheNamespace, name: name, createDirectory: false) else {
                return -1
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date else {
                return -1
            }
            return Date().timeIntervalSince(modDate) * 1000.0
        }
        let nBase64Decode: @convention(block) (String) -> String = { helper.base64Decode($0) }
        let nBase64Encode: @convention(block) (String) -> String = { helper.base64Encode($0) }
        let nMd5: @convention(block) (String) -> String = { Self.md5Hex($0) }
        let nSha256: @convention(block) (String) -> String = { helper.sha256($0) }
        let nAesEcbDecrypt: @convention(block) (String, String) -> String = { helper.aesEcbDecrypt($0, $1) }
        let nUuid: @convention(block) () -> String = { helper.uuid() }
        let nHtmlDecode: @convention(block) (String) -> String = { helper.htmlDecode($0) }

        ctx.setObject(nUserAgent, forKeyedSubscript: "__n_userAgent" as NSString)
        ctx.setObject(nWebViewUA, forKeyedSubscript: "__n_webViewUA" as NSString)
        ctx.setObject(nRequest, forKeyedSubscript: "__n_request" as NSString)
        ctx.setObject(nFinalUrl, forKeyedSubscript: "__n_finalUrl" as NSString)
        ctx.setObject(nStatus, forKeyedSubscript: "__n_status" as NSString)
        ctx.setObject(nFetch, forKeyedSubscript: "__n_fetch" as NSString)
        ctx.setObject(nParseHtml, forKeyedSubscript: "__n_parseHtml" as NSString)
        ctx.setObject(nCookies, forKeyedSubscript: "__n_cookies" as NSString)
        ctx.setObject(nGetPref, forKeyedSubscript: "__n_getPref" as NSString)
        ctx.setObject(nSetPref, forKeyedSubscript: "__n_setPref" as NSString)
        ctx.setObject(nLog, forKeyedSubscript: "__n_log" as NSString)
        ctx.setObject(nSleep, forKeyedSubscript: "__n_sleep" as NSString)
        ctx.setObject(nReadCache, forKeyedSubscript: "__n_readCache" as NSString)
        ctx.setObject(nWriteCache, forKeyedSubscript: "__n_writeCache" as NSString)
        ctx.setObject(nCacheAge, forKeyedSubscript: "__n_cacheAge" as NSString)
        ctx.setObject(nBase64Decode, forKeyedSubscript: "__n_base64Decode" as NSString)
        ctx.setObject(nBase64Encode, forKeyedSubscript: "__n_base64Encode" as NSString)
        ctx.setObject(nMd5, forKeyedSubscript: "__n_md5" as NSString)
        ctx.setObject(nSha256, forKeyedSubscript: "__n_sha256" as NSString)
        ctx.setObject(nAesEcbDecrypt, forKeyedSubscript: "__n_aesEcbDecrypt" as NSString)
        ctx.setObject(nUuid, forKeyedSubscript: "__n_uuid" as NSString)
        ctx.setObject(nHtmlDecode, forKeyedSubscript: "__n_htmlDecode" as NSString)

        // 安全白名单：内置解析器模式禁止注入未授权的高危/UI 函数
        if !isParserMode {
            ctx.setObject(nRequestAll, forKeyedSubscript: "__n_requestAll" as NSString)
            ctx.setObject(nRender, forKeyedSubscript: "__n_render" as NSString)
            ctx.setObject(nSniff, forKeyedSubscript: "__n_sniff" as NSString)
            ctx.setObject(nToast, forKeyedSubscript: "__n_toast" as NSString)
            ctx.setObject(nProgress, forKeyedSubscript: "__n_progress" as NSString)
        }

        let extraCaptureLines = isParserMode ? "" : """
          var _requestAll = g.__n_requestAll;
          var _render = g.__n_render;
          var _sniff = g.__n_sniff;
          var _toast = g.__n_toast;
          var _progress = g.__n_progress;
        """
        let extraBridgeMethods = isParserMode ? "" : """
          requestAll: function (u, o, c) { return _requestAll(u, o, c); },
          render: function (u, o, f) { return _render(u, o, f); },
          sniff: function (u, o, f) { return _sniff(u, o, f); },
          toast: function (m) { _toast(m); },
          progress: function (i) { _progress(id, i); },
        """
        let bridgeScript = """
        (function (g) {
          var _userAgent = g.__n_userAgent;
          var _webViewUA = g.__n_webViewUA;
          var _request = g.__n_request;
          var _finalUrl = g.__n_finalUrl;
          var _status = g.__n_status;
          var _fetch = g.__n_fetch;
          var _parseHtml = g.__n_parseHtml;
          var _cookies = g.__n_cookies;
          var _getPref = g.__n_getPref;
          var _setPref = g.__n_setPref;
          var _log = g.__n_log;
          var _sleep = g.__n_sleep;
          var _readCache = g.__n_readCache;
          var _writeCache = g.__n_writeCache;
          var _cacheAge = g.__n_cacheAge;
          var _base64Decode = g.__n_base64Decode;
          var _base64Encode = g.__n_base64Encode;
          var _md5 = g.__n_md5;
          var _sha256 = g.__n_sha256;
          var _aesEcbDecrypt = g.__n_aesEcbDecrypt;
          var _uuid = g.__n_uuid;
          var _htmlDecode = g.__n_htmlDecode;
          \(extraCaptureLines)
          var _internalSymbols = [
            '__n_userAgent', '__n_webViewUA', '__n_request', '__n_requestAll',
            '__n_finalUrl', '__n_status', '__n_fetch', '__n_parseHtml',
            '__n_render', '__n_sniff', '__n_cookies', '__n_getPref', '__n_setPref',
            '__n_toast', '__n_log', '__n_progress', '__n_sleep',
            '__n_readCache', '__n_writeCache', '__n_cacheAge',
            '__n_base64Decode', '__n_base64Encode', '__n_md5', '__n_sha256',
            '__n_aesEcbDecrypt', '__n_uuid', '__n_htmlDecode'
          ];
          for (var i = 0; i < _internalSymbols.length; i++) {
            try { delete g[_internalSymbols[i]]; } catch (e) {}
          }
          g.__bridge = { host: function (id, name) { return {
            getSourceId: function () { return id; },
            userAgent: function (d) { return _userAgent(!!d); },
            webViewUA: function () { return _webViewUA(); },
            request: function (u, o) { return _request(u, o); },
            \(extraBridgeMethods)
            finalUrl: function (u, o) { return _finalUrl(u, o); },
            status: function (u, o) { return _status(u, o); },
            fetch: function (u, o) { return _fetch(u, o); },
            parseHtml: function (h, b) { return _parseHtml(h, b); },
            cookies: function (u) { return _cookies(u); },
            getPref: function (k) { return _getPref(String(k == null ? '' : k)); },
            setPref: function (k, v) { _setPref(String(k == null ? '' : k), v); },
            log: function (m) { _log('[' + name + '] ' + m); },
            sleep: function (ms) { var e = _sleep(ms); if (e) { var err = new Error(e); err.cancelled = true; throw err; } },
            readCache: function (n) { return _readCache(String(n == null ? '' : n)); },
            writeCache: function (n, t) { _writeCache(String(n == null ? '' : n), String(t == null ? '' : t)); },
            cacheAge: function (n) { return _cacheAge(String(n == null ? '' : n)); },
            base64Decode: function (v) { return _base64Decode(v); },
            base64Encode: function (v) { return _base64Encode(v); },
            md5: function (v) { return _md5(v); },
            sha256: function (v) { return _sha256(v); },
            aesEcbDecrypt: function (d, k) { return _aesEcbDecrypt(d, k); },
            uuid: function () { return _uuid(); },
            htmlDecode: function (v) { return _htmlDecode(v); }
          }; } };
        })(this);
        function __invokeSafe(i, n, a) {
          try { return JSON.stringify({ v: __invoke(i, n, a) }); }
          catch (e) { return JSON.stringify({ e: String((e && e.message) || e), c: !!(e && e.cancelled) }); }
        }
        """
        ctx.evaluateScript(bridgeScript)
    }

    // MARK: - JSExport 兼容方法

    func getSourceId() -> String { sourceId }

    func userAgent(_ desktop: Bool) -> String {
        desktop ? Self.desktopUA : Self.mobileUA
    }

    func webViewUA() -> String {
        Self.mobileUA
    }

    func request(_ url: String, _ optionsJson: JSValue?) -> String {
        performRequest(url, optionsJson: Self.optionalString(from: optionsJson))
    }

    func requestAll(_ urlsJson: String, _ optionsJson: JSValue?, _ concurrency: Int) -> String {
        performRequestAll(urlsJson, optionsJson: Self.optionalString(from: optionsJson), concurrency: concurrency)
    }

    func finalUrl(_ url: String, _ optionsJson: JSValue?) -> String {
        performFinalUrl(url, optionsJson: Self.optionalString(from: optionsJson))
    }

    func fetch(_ url: String, _ optionsJson: JSValue?) -> String {
        performFetch(url, optionsJson: Self.optionalString(from: optionsJson))
    }

    func status(_ url: String, _ optionsJson: JSValue?) -> String {
        performStatus(url, optionsJson: Self.optionalString(from: optionsJson))
    }

    func parseHtml(_ html: String, _ baseUrl: JSValue?) -> JsElement {
        JsElement.parse(html: html, baseURL: Self.optionalString(from: baseUrl) ?? "")
    }

    func render(_ url: String, _ optionsJson: JSValue?, _ parseFn: JSValue?) -> String {
        performRender(url, optionsJson: Self.optionalString(from: optionsJson), parseFn: parseFn)
    }

    func sniff(_ url: String, _ optionsJson: JSValue?, _ validateFn: JSValue?) -> String {
        performSniff(url, optionsJson: Self.optionalString(from: optionsJson), validateFn: validateFn)
    }

    // MARK: - 偏好、缓存、编解码与密码学工具方法

    /// 获取指定 URL 的 Cookie 字符串（支持跨子域与同根域匹配，对齐 ssts Http.cookies(for:)）
    func cookies(_ url: String) -> String {
        guard let targetURL = Self.makeRequestURL(from: url) else {
            return ""
        }
        return CookieSync.cookieHeader(for: targetURL)
    }

    func getPref(_ key: String) -> Any {
        guard allowNetwork else { return NSNull() }
        let boundOwner = Self.sanitizeStorageIdentifier(sourceId)
        let storageKey = "\(prefPrefix)\(boundOwner).\(key)"
        if prefPrefix == "parser_pref_" {
            return BuiltinParserKeychain.string(forKey: storageKey) ?? NSNull()
        }
        if let v = UserDefaults.standard.string(forKey: storageKey) ??
                   UserDefaults.standard.string(forKey: "\(prefPrefix)\(boundOwner)_\(key)") {
            return v
        }
        return NSNull()
    }

    func setPref(_ key: String, _ value: JSValue?) {
        guard allowNetwork else { return }
        let boundOwner = Self.sanitizeStorageIdentifier(sourceId)
        let storageKey = "\(prefPrefix)\(boundOwner).\(key)"
        let strVal = Self.optionalString(from: value)
        if prefPrefix == "parser_pref_" {
            BuiltinParserKeychain.set(strVal, forKey: storageKey)
            return
        }
        if let s = strVal {
            UserDefaults.standard.set(s, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    func toast(_ message: String) {
        Task { @MainActor in
            ToastManager.shared.show(message)
        }
    }

    func log(_ message: String) {
        if let parserLogID {
            BuiltinParserLogStore.shared.append(parserLogID, message)
            return
        }
        #if DEBUG
        print("[Plugin] \(message)")
        #endif
    }

    func progress(_ info: JSValue?) {}

    func sleep(_ ms: Int) {
        let clamped = min(max(ms, 0), 5000)
        if clamped > 0 {
            Thread.sleep(forTimeInterval: Double(clamped) / 1000.0)
        }
    }

    func readCache(_ name: String) -> Any {
        guard allowNetwork,
              let url = Self.safeCacheFileURL(namespace: cacheNamespace ?? sourceId, name: name, createDirectory: false) else {
            return NSNull()
        }
        if let str = try? String(contentsOf: url, encoding: .utf8) {
            return str
        }
        return NSNull()
    }

    func writeCache(_ name: String, _ text: String) {
        guard allowNetwork,
              let url = Self.safeCacheFileURL(namespace: cacheNamespace ?? sourceId, name: name, createDirectory: true) else {
            return
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cacheAge(_ name: String) -> Double {
        guard allowNetwork,
              let url = Self.safeCacheFileURL(namespace: cacheNamespace ?? sourceId, name: name, createDirectory: false) else {
            return -1
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return -1
        }
        return Date().timeIntervalSince(modDate) * 1000.0
    }

    /// 兼容标准 Base64 与 URL-Safe Base64（将 '-' 转为 '+'、'_' 转为 '/' 并自动补齐 '=' 填充，100% 对齐 ssts 实现）
    static func decodeBase64Flexible(_ raw: String) -> Data? {
        var s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !s.isEmpty else { return nil }
        let rem = s.count % 4
        if rem > 0 {
            s += String(repeating: "=", count: 4 - rem)
        }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    func base64Decode(_ input: String) -> String {
        guard let data = Self.decodeBase64Flexible(input) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    func md5(_ input: String) -> String {
        Self.md5Hex(input)
    }

    static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-ECB 解密（支持喜马拉雅等站点的 URL-Safe Base64 无填充密文与 Hex/UTF-8 密钥，100% 对齐 ssts __n_aesEcbDecrypt）
    func aesEcbDecrypt(_ base64Data: String, _ keyHex: String) -> String {
        guard let cipherData = Self.decodeBase64Flexible(base64Data), !cipherData.isEmpty else {
            return ""
        }
        let cleanKey = keyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyData: Data
        if let hexKey = Self.dataFromHex(cleanKey),
           [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(hexKey.count) {
            keyData = hexKey
        } else {
            let utf8Key = Data(cleanKey.utf8)
            guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(utf8Key.count) else {
                return ""
            }
            keyData = utf8Key
        }

        let outLength = cipherData.count + kCCBlockSizeAES128
        var outBuffer = [UInt8](repeating: 0, count: outLength)
        var numBytesDecrypted: size_t = 0

        var status = cipherData.withUnsafeBytes { cipherPtr in
            keyData.withUnsafeBytes { keyPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    keyPtr.baseAddress,
                    keyData.count,
                    nil,
                    cipherPtr.baseAddress,
                    cipherData.count,
                    &outBuffer,
                    outLength,
                    &numBytesDecrypted
                )
            }
        }

        // 若站点采用 Zero Padding 而非 PKCS7 Padding，自动回退无填充 ECB 解密并剥离末尾空字节
        if status != kCCSuccess && cipherData.count % kCCBlockSizeAES128 == 0 {
            numBytesDecrypted = 0
            status = cipherData.withUnsafeBytes { cipherPtr in
                keyData.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        keyData.count,
                        nil,
                        cipherPtr.baseAddress,
                        cipherData.count,
                        &outBuffer,
                        outLength,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess, numBytesDecrypted > 0 else { return "" }
        var plainSlice = Array(outBuffer.prefix(numBytesDecrypted))
        while let last = plainSlice.last, last == 0 || last < 0x20 {
            plainSlice.removeLast()
        }
        let plainData = Data(plainSlice)
        let str = String(data: plainData, encoding: .utf8) ?? String(decoding: plainData, as: UTF8.self)
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    func htmlDecode(_ input: String) -> String {
        HTMLTokenizer.decodeHTMLEntities(input)
    }

    // MARK: - 内部辅助方法

    /// 白名单净化单段存储标识（消除路径分隔符、`..` 与控制字符）
    static func sanitizeStorageIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ._-")
        var out = ""
        out.reserveCapacity(trimmed.count)
        for scalar in trimmed.unicodeScalars {
            out.unicodeScalars.append(allowed.contains(scalar) ? scalar : "_")
        }
        while out.hasPrefix(".") || out.hasPrefix("_") {
            out.removeFirst()
        }
        if out.isEmpty || out == "." || out == ".." {
            return "default"
        }
        if out.count > 80 {
            out = String(out.prefix(80))
        }
        return out
    }

    /// M-P0-7：安全构造缓存文件路径，逐段清洗命名空间并强制校验 standardizedFileURL.path.hasPrefix(cacheRootPrefix)
    static func safeCacheFileURL(namespace: String, name: String, createDirectory: Bool = true) -> URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheRoot = caches.appendingPathComponent("PluginCache", isDirectory: true).standardizedFileURL
        let cacheRootPrefix = cacheRoot.path.hasSuffix("/") ? cacheRoot.path : cacheRoot.path + "/"

        let rawSegments = namespace.split(separator: "/").map(String.init)
        guard !rawSegments.isEmpty else { return nil }
        for seg in rawSegments {
            if seg == "." || seg == ".." || seg.contains("\\") {
                return nil
            }
        }
        let safeSegments = rawSegments.map { sanitizeStorageIdentifier($0) }
        var dir = cacheRoot
        for seg in safeSegments {
            dir = dir.appendingPathComponent(seg, isDirectory: true)
        }
        let standardizedDir = dir.standardizedFileURL
        guard standardizedDir.path.hasPrefix(cacheRootPrefix), standardizedDir.path != cacheRoot.path else {
            return nil
        }
        let safeName = md5Hex(name)
        let fileURL = standardizedDir.appendingPathComponent(safeName + ".txt").standardizedFileURL
        guard fileURL.path.hasPrefix(cacheRootPrefix) else {
            return nil
        }
        if createDirectory {
            try? FileManager.default.createDirectory(at: standardizedDir, withIntermediateDirectories: true)
        }
        return fileURL
    }

    static func dataFromHex(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }
}
