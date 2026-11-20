import Foundation
import UIKit
import WebKit

/// 线程安全阻塞队列（容量为 2 的覆盖式最新快照队列）：供主线程 WKWebView 与后台 JSContext 线程安全传递 HTML 快照或嗅探到的媒体候选 URL
private final class BlockingCandidateQueue<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private let maxCapacity: Int
    private var items: [Element] = []

    init(maxCapacity: Int = 2) {
        self.maxCapacity = max(1, maxCapacity)
    }

    func push(_ item: Element) {
        condition.lock()
        if items.count >= maxCapacity {
            items.removeFirst(items.count - maxCapacity + 1)
        }
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

    private let windowStateLock = NSLock()
    private var cachedHasWindow = true

    func refreshWindowAvailability() {
        DispatchQueue.main.async { [weak self] in
            let available = !UIApplication.shared.connectedScenes.isEmpty
            self?.windowStateLock.lock()
            self?.cachedHasWindow = available
            self?.windowStateLock.unlock()
        }
    }

    /// P-15 修复：消除后台线程 DispatchQueue.main.sync 死锁风险，改用异步刷新的缓存状态
    var canUseWebView: Bool {
        if Thread.isMainThread { return false }
        refreshWindowAvailability()
        windowStateLock.lock()
        let available = cachedHasWindow
        windowStateLock.unlock()
        return available
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
                CookieSync.storeCookie(c)
            }
            if !cookies.isEmpty {
                CookieSync.persistToDefaults()
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
            DispatchQueue.main.async {
                self.finishSession()
                self.gate.signal()
            }
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

        Task { @MainActor in
            guard checkActive() else { return }
            let wv = self.obtainWebView(desktop: desktop)
            let domainCookies = CookieSync.cookies(for: targetURL)
            let cookieStore = wv.configuration.websiteDataStore.httpCookieStore
            for c in domainCookies {
                await cookieStore.setCookie(c)
            }
            guard checkActive() else { return }
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
            DispatchQueue.main.async {
                self.finishSession()
                self.gate.signal()
            }
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

        Task { @MainActor in
            guard checkActive() else { return }
            self.onSniffCandidate = { candidate, isEl in
                queue.push((candidate, isEl))
            }
            let wv = self.obtainWebView(desktop: desktop)
            let domainCookies = CookieSync.cookies(for: targetURL)
            let cookieStore = wv.configuration.websiteDataStore.httpCookieStore
            for c in domainCookies {
                await cookieStore.setCookie(c)
            }
            guard checkActive() else { return }
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
