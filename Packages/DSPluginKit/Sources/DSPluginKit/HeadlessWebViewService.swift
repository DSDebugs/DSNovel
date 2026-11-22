import DSCore
import Foundation
import UIKit
import WebKit

/// 后台无头 WKWebView 渲染与媒体嗅探服务（可取消互斥门 + 会话令牌防竞态 + AUD-12 导航策略校验与数据清理）
public final class HeadlessWebViewService: NSObject, @unchecked Sendable {
    internal let gateCondition = NSCondition()
    internal var isGateBusy = false
    internal let lock = NSLock()
    internal var webView: WKWebView?
    internal var delegateProxy: HeadlessWebViewDelegateProxy?
    internal var lastUserAgent: String = HostHTTPClient.mobileUserAgent
    internal var currentSessionToken: UInt64 = 0
    internal var activePolicy: SourcePermissionPolicy?
    internal var activeNavigationID: ObjectIdentifier?
    internal var onSniffCandidate: ((String, Bool) -> Void)?
    internal var onNavigationFinished: (() -> Void)?
    internal var onNavigationFailed: ((Error) -> Void)?
    internal var setupTask: Task<Void, Never>?
    internal var renderPollTask: Task<Void, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    public override init() {
        super.init()
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.releaseWebViewOnMain() }
        }
    }

    deinit { if let obs = memoryWarningObserver { NotificationCenter.default.removeObserver(obs) } }

    /// 渲染动态页面：基于 didFinish + 增量 DOM 就绪检测，加载前自动注入 CookieVault Cookie
    public func renderHTML(
        url: URL, userAgent: String, cookies: [HTTPCookie] = [], timeoutSeconds: TimeInterval = 10.0,
        policy: SourcePermissionPolicy, desktop: Bool = false, cancellationToken: SandboxCancellationToken? = nil
    ) throws -> String {
        try policy.validate(url: url)
        guard !Thread.isMainThread else { throw PluginSecurityError.scriptError("render 不允许在主线程同步调用") }
        if cancellationToken?.isCancelled == true { throw CancellationError() }
        let clampedTimeout = max(2.0, min(timeoutSeconds, 25.0))
        let deadline = Date().addingTimeInterval(clampedTimeout)
        try acquireGate(until: deadline, timeoutSeconds: clampedTimeout, cancellationToken: cancellationToken)
        let myToken = beginSession(policy: policy)
        let queue = BlockingCandidateQueue<String>(maxCapacity: 2)
        let cancelID = cancellationToken?.onCancel { queue.fail(CancellationError()) }
        defer {
            if let cancelID { cancellationToken?.removeCancelHandler(cancelID) }
            endSession()
            releaseGate()
        }
        if cancellationToken?.isCancelled == true { throw CancellationError() }

        let effectiveUA = desktop ? HostHTTPClient.desktopUserAgent : userAgent
        let setup = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isSessionActive(myToken) else { return }
            let wv = self.ensureWebViewOnMain(userAgent: effectiveUA)
            await self.injectCookiesOnMain(cookies, for: url, into: wv)
            guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
            guard cancellationToken?.isCancelled != true else { queue.fail(CancellationError()); return }
            self.lock.withLock {
                guard self.currentSessionToken == myToken else { return }
                self.onNavigationFailed = { err in queue.fail(err) }
                self.onNavigationFinished = { [weak self] in
                    let pollTask = Task { @MainActor [weak self] in
                        guard let self, !Task.isCancelled, self.isSessionActive(myToken) else { return }
                        for _ in 0..<8 {
                            guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
                            let ready = (try? await self.webView?.evaluateJavaScript("document.readyState") as? String) ?? ""
                            guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
                            let html = (try? await self.webView?.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
                            guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
                            if ready == "complete" && html.count > 64 { queue.push(html); return }
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
                        let fallback = (try? await self.webView?.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
                        guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
                        if !fallback.isEmpty { queue.push(fallback) }
                    }
                    let kept = self?.lock.withLock { () -> Bool in
                        guard let self, self.currentSessionToken == myToken else { return false }
                        self.renderPollTask = pollTask
                        return true
                    } ?? false
                    if !kept { pollTask.cancel() }
                }
            }
            guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
            let nav = wv.load(URLRequest(url: url))
            self.lock.withLock { if self.currentSessionToken == myToken { self.activeNavigationID = nav.map { ObjectIdentifier($0) } } }
        }
        storeSetupTask(setup, for: myToken)

        guard let html = try queue.poll(until: deadline), !html.isEmpty else {
            if cancellationToken?.isCancelled == true { throw CancellationError() }
            throw PluginSecurityError.timeout(seconds: clampedTimeout)
        }
        return html
    }

    /// 嗅探网页中触发的音频/流媒体 URL（预注入 CookieVault 登录态）
    public func sniffMediaURL(
        url: URL, userAgent: String, cookies: [HTTPCookie] = [], timeoutSeconds: TimeInterval = 15.0,
        policy: SourcePermissionPolicy, desktop: Bool = false, cancellationToken: SandboxCancellationToken? = nil,
        validator: @Sendable (String) -> Bool
    ) throws -> String {
        try policy.validate(url: url)
        guard !Thread.isMainThread else { throw PluginSecurityError.scriptError("sniff 不允许在主线程同步调用") }
        if cancellationToken?.isCancelled == true { throw CancellationError() }
        let clampedTimeout = max(3.0, min(timeoutSeconds, 25.0))
        let deadline = Date().addingTimeInterval(clampedTimeout)
        try acquireGate(until: deadline, timeoutSeconds: clampedTimeout, cancellationToken: cancellationToken)
        let myToken = beginSession(policy: policy)
        let queue = BlockingCandidateQueue<(url: String, fromElement: Bool)>(maxCapacity: 8)
        let cancelID = cancellationToken?.onCancel { queue.fail(CancellationError()) }
        defer {
            if let cancelID { cancellationToken?.removeCancelHandler(cancelID) }
            endSession()
            releaseGate()
        }
        if cancellationToken?.isCancelled == true { throw CancellationError() }

        let effectiveUA = desktop ? HostHTTPClient.desktopUserAgent : userAgent
        let setup = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isSessionActive(myToken) else { return }
            let wv = self.ensureWebViewOnMain(userAgent: effectiveUA)
            await self.injectCookiesOnMain(cookies, for: url, into: wv)
            guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
            guard cancellationToken?.isCancelled != true else { queue.fail(CancellationError()); return }
            self.lock.withLock {
                guard self.currentSessionToken == myToken else { return }
                self.onNavigationFailed = { err in queue.fail(err) }
                self.onSniffCandidate = { candidate, isEl in queue.push((candidate, isEl)) }
            }
            guard !Task.isCancelled, self.isSessionActive(myToken) else { return }
            let nav = wv.load(URLRequest(url: url))
            self.lock.withLock { if self.currentSessionToken == myToken { self.activeNavigationID = nav.map { ObjectIdentifier($0) } } }
        }
        storeSetupTask(setup, for: myToken)

        while Date() < deadline {
            if cancellationToken?.isCancelled == true { throw CancellationError() }
            guard let candidate = try queue.poll(until: deadline) else { break }
            if let parsed = URL(string: candidate.url), (try? SSRFGuard.validatePublicURL(parsed)) != nil {
                if validator(candidate.url) { return candidate.url }
            }
        }
        if cancellationToken?.isCancelled == true { throw CancellationError() }
        throw PluginSecurityError.timeout(seconds: timeoutSeconds)
    }

    // MARK: - WebKit Delegate Handlers (invoked via @MainActor HeadlessWebViewDelegateProxy)

    internal func handleScriptMessage(name: String, body: Any) {
        guard name == "dsSniff", let raw = body as? String, raw.count > 1 else { return }
        let callback = lock.withLock { onSniffCandidate }
        callback?(String(raw.dropFirst()), raw.first == "E")
    }

    internal func handleNavigationFinished(navigation: WKNavigation?) {
        guard let navigation else { return }
        let navID = ObjectIdentifier(navigation)
        let cb = lock.withLock { () -> (() -> Void)? in
            guard activeNavigationID == navID else { return nil }
            activeNavigationID = nil
            let fn = onNavigationFinished; onNavigationFinished = nil
            return fn
        }
        cb?()
    }

    @MainActor
    internal func handleWebContentProcessDidTerminate() {
        let ua = lock.withLock { lastUserAgent }
        releaseWebViewOnMain(notifyError: PluginSecurityError.scriptError("WebView 渲染进程已异常终止"))
        _ = ensureWebViewOnMain(userAgent: ua)
    }

    internal func decideNavigationPolicy(for url: URL?) -> WKNavigationActionPolicy {
        if let url, url.scheme != "about" {
            let currentPolicy = lock.withLock { activePolicy }
            if let currentPolicy {
                if (try? currentPolicy.validate(url: url)) == nil { return .cancel }
            } else if (try? SSRFGuard.validatePublicURL(url)) == nil {
                return .cancel
            }
        }
        return .allow
    }
}
