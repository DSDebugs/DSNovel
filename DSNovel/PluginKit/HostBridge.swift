import Foundation
import JavaScriptCore
import CryptoKit
import CommonCrypto
import WebKit
import UIKit

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

/// 仅获取响应头即取消传输的 Delegate（对齐 ssts HeaderOnlyDelegate，避免服务端拒绝 HEAD 请求返回 403/405）
private final class HeaderOnlySessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var httpResponse: HTTPURLResponse?
    private(set) var completionError: Error?

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
        if let nsErr = error as NSError?, nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled && httpResponse != nil {
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

/// 线程安全阻塞队列：供主线程 WKWebView 与后台 JSContext 线程安全传递 HTML 快照或嗅探到的媒体候选 URL
private final class BlockingCandidateQueue<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [Element] = []

    func push(_ item: Element) {
        condition.lock()
        items.append(item)
        condition.signal()
        condition.unlock()
    }

    func poll(until deadline: Date) -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty {
            if Date() >= deadline {
                return nil
            }
            if !condition.wait(until: deadline) && items.isEmpty {
                return nil
            }
        }
        return items.removeFirst()
    }
}

/// 后台 WebView 渲染与媒体嗅探服务（100% 复刻 ssts WebViewService：用于动态 DOM 章节渲染与网页音频嗅探）
final class HeadlessWebViewService: NSObject, WKNavigationDelegate, WKScriptMessageHandler, @unchecked Sendable {
    static let shared = HeadlessWebViewService()

    private let gate = DispatchSemaphore(value: 1)
    private var webView: WKWebView?
    private var onSniffCandidate: ((String, Bool) -> Void)?

    private static let sniffHookScript = """
    (function(){
      if (window.__tsSniff) return; window.__tsSniff = 1;
      var seen = {};
      function report(u, el) {
        if (!u || typeof u !== 'string' || u.indexOf('http') !== 0 || seen[u]) return;
        seen[u] = 1;
        try { webkit.messageHandlers.tsSniff.postMessage((el ? 'E' : 'R') + u); } catch (e) {}
      }
      function abs(u) { try { return new URL(u, location.href).href; } catch (e) { return ''; } }
      try {
        var play = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function () { try { this.muted = true; report(this.currentSrc || this.src, true); } catch (e) {} return play.apply(this, arguments); };
        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (d && d.set) Object.defineProperty(HTMLMediaElement.prototype, 'src', { get: d.get, configurable: true,
          set: function (v) { try { this.muted = true; report(abs(v), true); } catch (e) {} d.set.call(this, v); } });
        var open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (m, u) { report(abs(u), false); return open.apply(this, arguments); };
        var f = window.fetch;
        if (f) window.fetch = function (i) { try { report(abs(typeof i === 'string' ? i : i.url), false); } catch (e) {} return f.apply(this, arguments); };
      } catch (e) {}
      setInterval(function () {
        try { var es = performance.getEntriesByType('resource'); for (var i = 0; i < es.length; i++) report(es[i].name, false); } catch (e) {}
        try { var ms = document.querySelectorAll('audio,video'); for (var j = 0; j < ms.length; j++) { ms[j].muted = true; report(ms[j].currentSrc || ms[j].src, true); } } catch (e) {}
      }, 400);
    })();
    """

    private static let autoClickAndMediaScript = """
    (function(){if(!window.__tsClicked){window.__tsClicked=1;var b=document.querySelector('.jp-play,.aplayer-play,.aplayer-button,.vjs-play-control,#play,.play-btn,.btn-play,.playbtn');if(b){try{b.click();}catch(e){}}}var m=document.querySelector('audio,video');if(!m)return '';try{m.muted=true;m.play();}catch(e){}return m.currentSrc||m.src||'';})();
    """

    var canUseWebView: Bool {
        if Thread.isMainThread { return false }
        var hasWindow = false
        DispatchQueue.main.sync {
            hasWindow = !UIApplication.shared.connectedScenes.isEmpty
        }
        return hasWindow
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "tsSniff", let raw = message.body as? String, raw.count > 1 else { return }
        let isElement = raw.hasPrefix("E")
        let url = String(raw.dropFirst())
        onSniffCandidate?(url, isElement)
    }

    @MainActor
    private func obtainWebView(desktop: Bool) -> WKWebView {
        let wv: WKWebView
        if let existing = webView {
            wv = existing
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            let ucc = WKUserContentController()
            ucc.add(self, name: "tsSniff")
            ucc.addUserScript(
                WKUserScript(
                    source: Self.sniffHookScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
            config.userContentController = ucc
            wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            self.webView = wv
        }
        wv.customUserAgent = desktop ? JsHostBridge.desktopUA : JsHostBridge.mobileUA
        return wv
    }

    @MainActor
    private func finishSession() {
        onSniffCandidate = nil
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for c in cookies {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
    }

    func render(
        url: String,
        desktop: Bool,
        script: String?,
        timeoutMs: Int,
        accept: (String) -> String?
    ) throws -> String {
        guard let targetURL = JsHostBridge.makeRequestURL(from: url) else {
            throw URLError(.badURL)
        }
        guard gate.wait(timeout: .now() + 20) == .success else {
            throw URLError(.timedOut)
        }
        defer {
            DispatchQueue.main.async { self.finishSession() }
            gate.signal()
        }

        let queue = BlockingCandidateQueue<String>()
        let clampedMs = min(max(timeoutMs, 3000), 45000)
        let deadline = Date().addingTimeInterval(Double(clampedMs) / 1000.0)
        var isActive = true
        let activeLock = NSLock()

        func checkActive() -> Bool {
            activeLock.lock()
            defer { activeLock.unlock() }
            return isActive
        }

        @MainActor
        func pollDOM(in wv: WKWebView) {
            guard checkActive() else { return }
            wv.evaluateJavaScript("(location.href.indexOf('about:')===0||document.readyState==='loading')?0:1") { readyVal, _ in
                guard checkActive() else { return }
                let ready = (readyVal as? Int) == 1 || (readyVal as? NSNumber)?.intValue == 1
                guard ready else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pollDOM(in: wv) }
                    return
                }
                let jsToRun: String
                if let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    jsToRun = script
                } else {
                    jsToRun = "(function(){return '<html>'+document.documentElement.innerHTML+'</html>';})();"
                }
                wv.evaluateJavaScript(jsToRun) { res, _ in
                    guard checkActive() else { return }
                    if let s = res as? String, !s.isEmpty {
                        queue.push(s)
                    } else {
                        wv.evaluateJavaScript("(function(){return '<html>'+document.documentElement.innerHTML+'</html>';})();") { htmlRes, _ in
                            if let h = htmlRes as? String, !h.isEmpty {
                                queue.push(h)
                            }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pollDOM(in: wv) }
                }
            }
        }

        DispatchQueue.main.async {
            let wv = self.obtainWebView(desktop: desktop)
            if let sharedCookies = HTTPCookieStorage.shared.cookies {
                for c in sharedCookies {
                    wv.configuration.websiteDataStore.httpCookieStore.setCookie(c)
                }
            }
            wv.load(URLRequest(url: targetURL))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pollDOM(in: wv)
            }
        }

        defer {
            activeLock.lock()
            isActive = false
            activeLock.unlock()
        }

        while Date() < deadline {
            guard let candidateHTML = queue.poll(until: deadline) else {
                break
            }
            if let accepted = accept(candidateHTML), !accepted.isEmpty {
                return accepted
            }
        }
        throw NSError(domain: "HeadlessWebViewService", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView 加载超时：\(url)"])
    }

    func sniff(
        url: String,
        desktop: Bool,
        script: String?,
        timeoutMs: Int,
        accept: (String, Bool) -> Bool
    ) throws -> String {
        guard let targetURL = JsHostBridge.makeRequestURL(from: url) else {
            throw URLError(.badURL)
        }
        guard gate.wait(timeout: .now() + 20) == .success else {
            throw URLError(.timedOut)
        }
        defer {
            DispatchQueue.main.async { self.finishSession() }
            gate.signal()
        }

        let queue = BlockingCandidateQueue<(String, Bool)>()
        let clampedMs = min(max(timeoutMs, 3000), 45000)
        let deadline = Date().addingTimeInterval(Double(clampedMs) / 1000.0)
        var isActive = true
        let activeLock = NSLock()

        func checkActive() -> Bool {
            activeLock.lock()
            defer { activeLock.unlock() }
            return isActive
        }

        @MainActor
        func pollMedia(in wv: WKWebView) {
            guard checkActive() else { return }
            wv.evaluateJavaScript("(location.href.indexOf('about:')===0||document.readyState==='loading')?0:1") { readyVal, _ in
                guard checkActive() else { return }
                let ready = (readyVal as? Int) == 1 || (readyVal as? NSNumber)?.intValue == 1
                if ready {
                    if let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        wv.evaluateJavaScript(script, completionHandler: nil)
                    }
                    wv.evaluateJavaScript(Self.autoClickAndMediaScript) { mediaRes, _ in
                        if let m = mediaRes as? String, m.hasPrefix("http") {
                            queue.push((m, true))
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pollMedia(in: wv) }
            }
        }

        DispatchQueue.main.async {
            self.onSniffCandidate = { candidate, isEl in
                queue.push((candidate, isEl))
            }
            let wv = self.obtainWebView(desktop: desktop)
            if let sharedCookies = HTTPCookieStorage.shared.cookies {
                for c in sharedCookies {
                    wv.configuration.websiteDataStore.httpCookieStore.setCookie(c)
                }
            }
            wv.load(URLRequest(url: targetURL))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pollMedia(in: wv)
            }
        }

        defer {
            activeLock.lock()
            isActive = false
            activeLock.unlock()
        }

        while Date() < deadline {
            guard let (candidate, isEl) = queue.poll(until: deadline) else {
                break
            }
            if accept(candidate, isEl) {
                return candidate
            }
        }
        throw NSError(domain: "HeadlessWebViewService", code: -2, userInfo: [NSLocalizedDescriptionKey: "没有嗅探到音频地址（可能需要登录或网站已失效）"])
    }
}

/// 插件宿主桥接实现：严格对齐 ssts 原生块桥接签名，消除 JS null/undefined 桥接歧义，支持 UTF-8/GBK 自动识别与同步并发请求
@objc final class JsHostBridge: NSObject, JsHostBridgeExports {
    let packageID: String
    let sourceId: String
    let sourceName: String

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    init(packageID: String, sourceId: String, sourceName: String) {
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
    static func installNative(into ctx: JSContext, packageID: String) {
        let helper = JsHostBridge(packageID: packageID, sourceId: packageID, sourceName: packageID)

        let nUserAgent: @convention(block) (Bool) -> String = { desktop in
            desktop ? Self.desktopUA : Self.mobileUA
        }
        let nWebViewUA: @convention(block) () -> String = {
            Self.mobileUA
        }
        let nRequest: @convention(block) (String, JSValue) -> String = { url, opts in
            helper.performRequest(url, optionsJson: Self.optionalString(from: opts))
        }
        let nRequestAll: @convention(block) (String, JSValue, Int) -> String = { urlsJson, opts, concurrency in
            helper.performRequestAll(urlsJson, optionsJson: Self.optionalString(from: opts), concurrency: concurrency)
        }
        let nFinalUrl: @convention(block) (String, JSValue) -> String = { url, opts in
            helper.performFinalUrl(url, optionsJson: Self.optionalString(from: opts))
        }
        let nStatus: @convention(block) (String, JSValue) -> String = { url, opts in
            helper.performStatus(url, optionsJson: Self.optionalString(from: opts))
        }
        let nFetch: @convention(block) (String, JSValue) -> String = { url, opts in
            helper.performFetch(url, optionsJson: Self.optionalString(from: opts))
        }
        let nParseHtml: @convention(block) (String, JSValue) -> JsElement = { html, baseVal in
            let base = Self.optionalString(from: baseVal) ?? ""
            return JsElement.parse(html: html, baseURL: base)
        }
        let nRender: @convention(block) (String, JSValue, JSValue) -> String = { url, opts, parseFn in
            helper.performRender(url, optionsJson: Self.optionalString(from: opts), parseFn: parseFn)
        }
        let nSniff: @convention(block) (String, JSValue, JSValue) -> String = { url, opts, validateFn in
            helper.performSniff(url, optionsJson: Self.optionalString(from: opts), validateFn: validateFn)
        }
        let nCookies: @convention(block) (String) -> String = { url in
            helper.cookies(url)
        }
        let nGetPref: @convention(block) (String) -> Any = { fullKey in
            if let val = UserDefaults.standard.string(forKey: "plugin_pref_\(fullKey)") {
                return val
            }
            return NSNull()
        }
        let nSetPref: @convention(block) (String, JSValue) -> Void = { fullKey, val in
            let storageKey = "plugin_pref_\(fullKey)"
            if let s = Self.optionalString(from: val) {
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
            let clamped = min(max(ms, 0), 5000)
            if clamped > 0 {
                Thread.sleep(forTimeInterval: Double(clamped) / 1000.0)
            }
            return NSNull()
        }
        let nReadCache: @convention(block) (String, String) -> Any = { srcId, name in
            let url = Self.cacheFileURL(sourceId: srcId, name: name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            return NSNull()
        }
        let nWriteCache: @convention(block) (String, String, String) -> Void = { srcId, name, text in
            let url = Self.cacheFileURL(sourceId: srcId, name: name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let nCacheAge: @convention(block) (String, String) -> Double = { srcId, name in
            let url = Self.cacheFileURL(sourceId: srcId, name: name)
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
        ctx.setObject(nRequestAll, forKeyedSubscript: "__n_requestAll" as NSString)
        ctx.setObject(nFinalUrl, forKeyedSubscript: "__n_finalUrl" as NSString)
        ctx.setObject(nStatus, forKeyedSubscript: "__n_status" as NSString)
        ctx.setObject(nFetch, forKeyedSubscript: "__n_fetch" as NSString)
        ctx.setObject(nParseHtml, forKeyedSubscript: "__n_parseHtml" as NSString)
        ctx.setObject(nRender, forKeyedSubscript: "__n_render" as NSString)
        ctx.setObject(nSniff, forKeyedSubscript: "__n_sniff" as NSString)
        ctx.setObject(nCookies, forKeyedSubscript: "__n_cookies" as NSString)
        ctx.setObject(nGetPref, forKeyedSubscript: "__n_getPref" as NSString)
        ctx.setObject(nSetPref, forKeyedSubscript: "__n_setPref" as NSString)
        ctx.setObject(nToast, forKeyedSubscript: "__n_toast" as NSString)
        ctx.setObject(nLog, forKeyedSubscript: "__n_log" as NSString)
        ctx.setObject(nProgress, forKeyedSubscript: "__n_progress" as NSString)
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

        let bridgeScript = """
        var __bridge = { host: function (id, name) { return {
          getSourceId: function () { return id; },
          userAgent: function (d) { return __n_userAgent(!!d); },
          webViewUA: function () { return __n_webViewUA(); },
          request: function (u, o) { return __n_request(u, o); },
          requestAll: function (u, o, c) { return __n_requestAll(u, o, c); },
          finalUrl: function (u, o) { return __n_finalUrl(u, o); },
          status: function (u, o) { return __n_status(u, o); },
          fetch: function (u, o) { return __n_fetch(u, o); },
          parseHtml: function (h, b) { return __n_parseHtml(h, b); },
          render: function (u, o, f) { return __n_render(u, o, f); },
          sniff: function (u, o, f) { return __n_sniff(u, o, f); },
          cookies: function (u) { return __n_cookies(u); },
          getPref: function (k) { return __n_getPref(id + '.' + k); },
          setPref: function (k, v) { __n_setPref(id + '.' + k, v); },
          toast: function (m) { __n_toast(m); },
          log: function (m) { __n_log('[' + name + '] ' + m); },
          progress: function (i) { __n_progress(id, i); },
          sleep: function (ms) { var e = __n_sleep(ms); if (e) { var err = new Error(e); err.cancelled = true; throw err; } },
          readCache: function (n) { return __n_readCache(id, n); },
          writeCache: function (n, t) { __n_writeCache(id, n, t); },
          cacheAge: function (n) { return __n_cacheAge(id, n); },
          base64Decode: function (v) { return __n_base64Decode(v); },
          base64Encode: function (v) { return __n_base64Encode(v); },
          md5: function (v) { return __n_md5(v); },
          sha256: function (v) { return __n_sha256(v); },
          aesEcbDecrypt: function (d, k) { return __n_aesEcbDecrypt(d, k); },
          uuid: function () { return __n_uuid(); },
          htmlDecode: function (v) { return __n_htmlDecode(v); }
        }; } };
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

    // MARK: - 核心实现

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
        let semaphore = DispatchSemaphore(value: maxConcurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Any] = Array(repeating: NSNull(), count: urls.count)

        for (idx, u) in urls.enumerated() {
            group.enter()
            let singleOptJson: String?
            if let dict = optionsArray[idx],
               let d = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: d, encoding: .utf8) {
                singleOptJson = s
            } else {
                singleOptJson = nil
            }
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()
                defer {
                    semaphore.signal()
                    group.leave()
                }
                if let (code, body, _) = try? self.performSyncHTTP(url: u, optionsJson: singleOptJson, headOnly: false),
                   (200..<300).contains(code) {
                    lock.lock()
                    results[idx] = body
                    lock.unlock()
                }
            }
        }
        _ = group.wait(timeout: .now() + 25)
        return wrapValue(results)
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
            let pattern = "https?://[^\\s\"'<>\\\\]+\\.(?:m4a|mp3|m3u8|aac|flac|ogg|wav)(?:\\?[^\\s\"'<>\\\\]*)?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
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

    private static func isLikelyMediaURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        let exts = [".mp3", ".m4a", ".m3u8", ".aac", ".flac", ".ogg", ".wav", ".mp4", ".wma"]
        return exts.contains { lower.contains($0) }
    }

    func cookies(_ url: String) -> String {
        guard let targetURL = Self.makeRequestURL(from: url),
              let items = HTTPCookieStorage.shared.cookies(for: targetURL) else {
            return ""
        }
        return items.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func getPref(_ key: String) -> Any {
        if let v = UserDefaults.standard.string(forKey: "plugin_pref_\(sourceId).\(key)") ??
                   UserDefaults.standard.string(forKey: "plugin_pref_\(sourceId)_\(key)") {
            return v
        }
        return NSNull()
    }

    func setPref(_ key: String, _ value: JSValue?) {
        let storageKey = "plugin_pref_\(sourceId).\(key)"
        if let s = Self.optionalString(from: value) {
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
        let url = Self.cacheFileURL(sourceId: sourceId, name: name)
        if let str = try? String(contentsOf: url, encoding: .utf8) {
            return str
        }
        return NSNull()
    }

    func writeCache(_ name: String, _ text: String) {
        let url = Self.cacheFileURL(sourceId: sourceId, name: name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cacheAge(_ name: String) -> Double {
        let url = Self.cacheFileURL(sourceId: sourceId, name: name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return -1
        }
        return Date().timeIntervalSince(modDate) * 1000.0
    }

    func base64Decode(_ input: String) -> String {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: clean, options: .ignoreUnknownCharacters) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        let rem = clean.count % 4
        if rem > 0 {
            let padded = clean + String(repeating: "=", count: 4 - rem)
            if let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) {
                return String(data: data, encoding: .utf8) ?? ""
            }
        }
        return ""
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

    func aesEcbDecrypt(_ base64Data: String, _ keyHex: String) -> String {
        let cleanB64 = base64Data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cipherData = Data(base64Encoded: cleanB64, options: .ignoreUnknownCharacters),
              let keyData = Self.dataFromHex(keyHex),
              [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(keyData.count) else {
            return ""
        }
        let outLength = cipherData.count + kCCBlockSizeAES128
        var outBuffer = [UInt8](repeating: 0, count: outLength)
        var numBytesDecrypted: size_t = 0

        let status = cipherData.withUnsafeBytes { cipherPtr in
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
        guard status == kCCSuccess else { return "" }
        let plainData = Data(outBuffer.prefix(numBytesDecrypted))
        return String(data: plainData, encoding: .utf8) ?? ""
    }

    func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    func htmlDecode(_ input: String) -> String {
        HTMLTokenizer.decodeHTMLEntities(input)
    }

    // MARK: - 内部辅助方法

    private static func cacheFileURL(sourceId: String, name: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("PluginCache/\(sourceId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = md5Hex(name)
        return dir.appendingPathComponent(safeName + ".txt")
    }

    static func makeRequestURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed) {
            return u
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let u = URL(string: encoded) {
            return u
        }
        return nil
    }

    private func performSyncHTTP(
        url: String,
        optionsJson: String?,
        headOnly: Bool,
        defaultRangeZero: Bool = false
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

        // 合并共享 HTTPCookieStorage 的 Cookie（对齐 ssts Http.cookieHeaderIfNeeded）
        if let storedCookies = HTTPCookieStorage.shared.cookies(for: requestURL), !storedCookies.isEmpty {
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

        if headOnly {
            let delegate = HeaderOnlySessionDelegate()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.httpCookieStorage = .shared
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = session.dataTask(with: req)
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

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            responseData = data
            httpResponse = resp as? HTTPURLResponse
            requestError = err
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
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

    private static func persistResponseCookies(_ response: HTTPURLResponse?, fallbackURL: URL) {
        guard let response,
              let headerFields = response.allHeaderFields as? [String: String] else { return }
        let url = response.url ?? fallbackURL
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        if !cookies.isEmpty {
            HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: nil)
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

    private func wrapValue(_ value: Any) -> String {
        let payload: [String: Any] = ["v": value]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"v\":null}"
        }
        return str
    }

    private func wrapError(_ message: String) -> String {
        let payload: [String: Any] = ["e": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"e\":\"Error\"}"
        }
        return str
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
