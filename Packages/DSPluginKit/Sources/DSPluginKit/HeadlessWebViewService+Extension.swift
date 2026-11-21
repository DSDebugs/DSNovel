import DSCore
import Foundation
import UIKit
import WebKit

/// 线程安全有界覆盖队列（支持快速失败唤醒）
internal final class BlockingCandidateQueue<Element: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private let maxCapacity: Int
    private var items: [Element] = []
    private var terminalError: Error?

    init(maxCapacity: Int = 4) { self.maxCapacity = max(1, maxCapacity) }

    func push(_ item: Element) {
        condition.lock()
        if items.count >= maxCapacity { items.removeFirst(items.count - maxCapacity + 1) }
        items.append(item)
        condition.signal()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if terminalError == nil { terminalError = error }
        condition.broadcast()
        condition.unlock()
    }

    func poll(until deadline: Date) throws -> Element? {
        condition.lock(); defer { condition.unlock() }
        while items.isEmpty && terminalError == nil {
            if Date() >= deadline { return nil }
            if !condition.wait(until: deadline) && items.isEmpty && terminalError == nil { return nil }
        }
        if !items.isEmpty { return items.removeFirst() }
        if let err = terminalError { throw err }
        return nil
    }
}

/// 弱引用 @MainActor 代理（打破 WKUserContentController 循环引用，并隔离 WK* 协议的 @MainActor 推断）
@MainActor
internal final class HeadlessWebViewDelegateProxy: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var owner: HeadlessWebViewService?
    init(_ owner: HeadlessWebViewService) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(name: message.name, body: message.body)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.handleNavigationFinished(navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.handleNavigationFailure(navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner?.handleNavigationFailure(navigation: navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.handleWebContentProcessDidTerminate()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(owner?.decideNavigationPolicy(for: navigationAction.request.url) ?? .allow)
    }
}

extension HeadlessWebViewService {
    internal static let sniffHookScript = """
    (function(){
      if (window.__dsSniff) return; window.__dsSniff = 1;
      var seen = {};
      function report(u, el) {
        if (!u || typeof u !== 'string' || u.indexOf('http') !== 0 || seen[u]) return;
        seen[u] = 1;
        try { webkit.messageHandlers.dsSniff.postMessage((el ? 'E' : 'R') + u); } catch (e) {}
      }
      function abs(u) { try { return new URL(u, location.href).href; } catch (e) { return ''; } }
      try {
        var play = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function () { try { this.muted = true; report(this.currentSrc || this.src, true); } catch (e) {} return play.apply(this, arguments); };
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

    internal func acquireGate(until deadline: Date, timeoutSeconds: TimeInterval, cancellationToken: SandboxCancellationToken?) throws {
        let wakeID = cancellationToken?.onCancel { [gateCondition] in
            gateCondition.lock(); gateCondition.broadcast(); gateCondition.unlock()
        }
        defer { if let wakeID { cancellationToken?.removeCancelHandler(wakeID) } }
        gateCondition.lock(); defer { gateCondition.unlock() }
        while isGateBusy {
            if cancellationToken?.isCancelled == true { throw CancellationError() }
            if Date() >= deadline { throw PluginSecurityError.timeout(seconds: timeoutSeconds) }
            _ = gateCondition.wait(until: deadline)
        }
        if cancellationToken?.isCancelled == true { throw CancellationError() }
        isGateBusy = true
    }

    internal func releaseGate() {
        gateCondition.lock(); isGateBusy = false; gateCondition.signal(); gateCondition.unlock()
    }

    internal func beginSession(policy: SourcePermissionPolicy) -> UInt64 {
        lock.withLock {
            currentSessionToken &+= 1
            activePolicy = policy
            return currentSessionToken
        }
    }

    internal func isSessionActive(_ token: UInt64) -> Bool { lock.withLock { currentSessionToken == token } }

    internal func storeSetupTask(_ task: Task<Void, Never>, for token: UInt64) {
        let kept = lock.withLock { () -> Bool in
            guard currentSessionToken == token else { return false }
            setupTask = task
            return true
        }
        if !kept { task.cancel() }
    }

    internal func endSession() {
        let (setup, poll) = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?) in
            currentSessionToken &+= 1
            activePolicy = nil
            activeNavigationID = nil; onNavigationFinished = nil; onNavigationFailed = nil; onSniffCandidate = nil
            let s = setupTask; setupTask = nil
            let p = renderPollTask; renderPollTask = nil
            return (s, p)
        }
        setup?.cancel(); poll?.cancel()
        stopLoadingAndWait()
    }

    internal func handleNavigationFailure(navigation: WKNavigation?, error: Error) {
        guard let navigation else { return }
        let navID = ObjectIdentifier(navigation)
        let failCb = lock.withLock { () -> ((Error) -> Void)? in
            guard activeNavigationID == navID else { return nil }
            activeNavigationID = nil; onNavigationFinished = nil
            let cb = onNavigationFailed; onNavigationFailed = nil
            return cb
        }
        failCb?(error)
    }

    @MainActor
    internal func injectCookiesOnMain(_ cookies: [HTTPCookie], for targetURL: URL, into webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        if let host = targetURL.host?.lowercased(), !host.isEmpty {
            let existing = await store.allCookies()
            for old in existing {
                let d = old.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !d.isEmpty && (host == d || host.hasSuffix("." + d) || d.hasSuffix("." + host)) {
                    await store.deleteCookie(old)
                }
            }
        }
        for cookie in cookies { await store.setCookie(cookie) }
    }

    @MainActor
    internal func ensureWebViewOnMain(userAgent: String) -> WKWebView {
        lock.withLock { lastUserAgent = userAgent }
        if let existing = webView { existing.customUserAgent = userAgent; return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let script = WKUserScript(source: Self.sniffHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        let proxy = HeadlessWebViewDelegateProxy(self)
        self.delegateProxy = proxy
        config.userContentController.add(proxy, name: "dsSniff")
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = userAgent
        wv.navigationDelegate = proxy
        self.webView = wv
        return wv
    }

    internal func stopLoadingAndWait() {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor [weak self] in
            await self?.stopLoadingOnMain()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    @MainActor
    internal func stopLoadingOnMain() async {
        lock.withLock { activeNavigationID = nil }
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        // AUD-12：会话结束后彻底清理非持久化容器的 Cookie/Storage/Cache，防止跨源残留
        if let dataStore = webView?.configuration.websiteDataStore {
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    @MainActor
    internal func releaseWebViewOnMain(notifyError: Error? = PluginSecurityError.scriptError("WebView 因系统内存警告已释放")) {
        let failCb = lock.withLock { () -> ((Error) -> Void)? in
            activePolicy = nil
            activeNavigationID = nil; onNavigationFinished = nil; onSniffCandidate = nil
            let cb = onNavigationFailed; onNavigationFailed = nil
            return cb
        }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dsSniff")
        webView = nil
        delegateProxy = nil
        if let err = notifyError { failCb?(err) }
    }
}
