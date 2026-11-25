import DSCore
import DSDesignSystem
import DSDownloads
import DSPluginKit
import SwiftUI
import WebKit

/// 网页登录会话请求（内置单次终态守护，防止下拉关闭与完成按钮重复回调）
struct WebAuthRequest: Identifiable, Sendable {
    let id = UUID()
    let sourceID: String
    let title: String
    let loginURL: URL
    let allowedHosts: [String]

    init(sourceID: String, title: String, loginURL: URL, allowedHosts: [String] = []) {
        self.sourceID = sourceID
        self.title = title
        self.loginURL = loginURL
        self.allowedHosts = allowedHosts
    }
}

/// 内嵌 WKWebView 网页登录页（支持移动/桌面 UA 切换、SSRF 拦截、错误态重试、按域过滤 CookieVault 双向同步）
struct WebAuthScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner

    private let request: WebAuthRequest
    private let onDismiss: () -> Void

    @State private var isDesktopUA = false
    @State private var currentURLText: String
    @State private var capturedCookieCount = 0
    @State private var loadErrorMessage: String?
    @State private var visitedHosts: Set<String>
    @State private var webViewRef: WKWebView?
    @State private var initialCookies: [HTTPCookie] = []
    @State private var cookiesReady = false
    @State private var isFinishing = false

    init(request: WebAuthRequest, onDismiss: @escaping () -> Void) {
        self.request = request
        self.onDismiss = onDismiss
        _currentURLText = State(initialValue: request.loginURL.absoluteString)
        var initialHosts: Set<String> = request.loginURL.host.map { [$0.lowercased()] } ?? []
        for raw in request.allowedHosts {
            var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clean.hasPrefix("*.") { clean = String(clean.dropFirst(2)) }
            clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !clean.isEmpty { initialHosts.insert(clean) }
        }
        _visitedHosts = State(initialValue: initialHosts)
    }

    var body: some View {
        DSSheetScaffold(title: "登录：\(request.title)", banner: banner, onDismiss: dismissOnce) {
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(DSColors.accent)
                    Text(currentURLText)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button(isDesktopUA ? "桌面 UA" : "移动 UA") {
                        isDesktopUA.toggle()
                        loadErrorMessage = nil
                        webViewRef?.customUserAgent = isDesktopUA ? HostHTTPClient.desktopUserAgent : HostHTTPClient.mobileUserAgent
                        webViewRef?.reload()
                    }
                    .font(DSTypography.caption)
                    .buttonStyle(.bordered)
                    .disabled(webViewRef == nil)
                    .frame(minHeight: 36)
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)

                if let err = loadErrorMessage {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DSColors.danger)
                        Text(err)
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.danger)
                            .lineLimit(2)
                        Spacer()
                        Button("重试") {
                            retryLoad()
                        }
                        .font(DSTypography.caption)
                        .buttonStyle(.bordered)
                        .frame(minHeight: 36)
                    }
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, DSSpacing.xs)
                    .background(DSColors.surfaceCard)
                }

                if cookiesReady {
                    AuthWebViewRepresentable(
                        initialURL: request.loginURL,
                        userAgent: isDesktopUA ? HostHTTPClient.desktopUserAgent : HostHTTPClient.mobileUserAgent,
                        initialCookies: initialCookies,
                        onWebViewReady: { webViewRef = $0 },
                        onURLChange: { urlString in
                            currentURLText = urlString
                            if let host = URL(string: urlString)?.host?.lowercased() {
                                visitedHosts.insert(host)
                            }
                        },
                        onVisitHost: { host in
                            visitedHosts.insert(host.lowercased())
                        },
                        onCookiesUpdated: { allCookies in
                            let relevant = Self.filterRelevantCookies(allCookies, allowedHosts: visitedHosts)
                            capturedCookieCount = relevant.count
                        },
                        onLoadError: { err in
                            loadErrorMessage = err
                        }
                    )
                } else {
                    ProgressView("正在同步会话...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack(spacing: DSSpacing.sm) {
                    Text("已捕获 Cookie：\(capturedCookieCount) 项")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                    Spacer()
                    Button("同步登录态并完成") {
                        Task { await syncCookiesAndFinish() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFinishing)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)
                .background(DSColors.surfaceCard)
            }
        }
        .interactiveDismissDisabled(isFinishing)
        .onDisappear {
            if !isFinishing {
                Task { await syncCookiesAndFinish(showBannerIfEmpty: false) }
            }
        }
        .task {
            initialCookies = await container.cookieVault.matchingCookies(for: request.loginURL)
            capturedCookieCount = initialCookies.count
            cookiesReady = true
        }
    }

    private func retryLoad() {
        loadErrorMessage = nil
        guard let wv = webViewRef else { return }
        if wv.url != nil {
            wv.reload()
        } else if (try? SSRFGuard.validatePublicURL(request.loginURL)) != nil {
            wv.load(URLRequest(url: request.loginURL))
        } else {
            loadErrorMessage = "已拦截不安全的内网或非法登录地址"
        }
    }

    private func dismissOnce() {
        Task { await syncCookiesAndFinish(showBannerIfEmpty: false) }
    }

    private func syncCookiesAndFinish(showBannerIfEmpty: Bool = true) async {
        guard !isFinishing else { return }
        isFinishing = true
        guard let store = webViewRef?.configuration.websiteDataStore.httpCookieStore else {
            onDismiss()
            return
        }
        let allCookies = await store.allCookies()
        let relevant = Self.filterRelevantCookies(allCookies, allowedHosts: visitedHosts)
        if !relevant.isEmpty {
            await container.cookieVault.setCookies(relevant)
            capturedCookieCount = relevant.count
            // L-IOS-2：登录态刷新后立刻作废旧下载 resumeData，避免 401/403 死循环
            downloads.invalidateResumeDataOnAuthOrNetworkChange()
            _ = await container.sourceAuth.refresh(sourceID: request.sourceID, runtime: container.pluginRuntime, force: true)
            banner.show("已同步 \(relevant.count) 条登录 Cookie", tone: .success)
        } else if showBannerIfEmpty {
            banner.show("暂未捕获到新的登录 Cookie", tone: .info)
        }
        onDismiss()
    }

    private static func filterRelevantCookies(_ cookies: [HTTPCookie], allowedHosts: Set<String>) -> [HTTPCookie] {
        guard !allowedHosts.isEmpty else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty else { return false }
            return allowedHosts.contains { host in
                host == domain || host.hasSuffix("." + domain)
            }
        }
    }
}

private struct AuthWebViewRepresentable: UIViewRepresentable {
    let initialURL: URL
    let userAgent: String
    let initialCookies: [HTTPCookie]
    let onWebViewReady: @MainActor (WKWebView) -> Void
    let onURLChange: @MainActor (String) -> Void
    let onVisitHost: @MainActor (String) -> Void
    let onCookiesUpdated: @MainActor ([HTTPCookie]) -> Void
    let onLoadError: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onURLChange: onURLChange,
            onVisitHost: onVisitHost,
            onCookiesUpdated: onCookiesUpdated,
            onLoadError: onLoadError
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = userAgent
        wv.navigationDelegate = context.coordinator
        let readyCallback = onWebViewReady
        let errorCallback = onLoadError
        let store = cfg.websiteDataStore.httpCookieStore
        let target = initialURL
        let preset = initialCookies
        context.coordinator.setupTask = Task { @MainActor in
            readyCallback(wv)
            for cookie in preset {
                guard !Task.isCancelled else { return }
                await store.setCookie(cookie)
            }
            guard !Task.isCancelled else { return }
            if (try? SSRFGuard.validatePublicURL(target)) != nil {
                wv.load(URLRequest(url: target))
            } else {
                errorCallback("已拦截不安全的内网或非法登录地址")
            }
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.customUserAgent != userAgent {
            uiView.customUserAgent = userAgent
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.setupTask?.cancel()
        coordinator.setupTask = nil
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onURLChange: @MainActor (String) -> Void
        let onVisitHost: @MainActor (String) -> Void
        let onCookiesUpdated: @MainActor ([HTTPCookie]) -> Void
        let onLoadError: @MainActor (String?) -> Void
        var setupTask: Task<Void, Never>?

        init(
            onURLChange: @escaping @MainActor (String) -> Void,
            onVisitHost: @escaping @MainActor (String) -> Void,
            onCookiesUpdated: @escaping @MainActor ([HTTPCookie]) -> Void,
            onLoadError: @escaping @MainActor (String?) -> Void
        ) {
            self.onURLChange = onURLChange
            self.onVisitHost = onVisitHost
            self.onCookiesUpdated = onCookiesUpdated
            self.onLoadError = onLoadError
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" {
                    if (try? SSRFGuard.validatePublicURL(url)) == nil {
                        onLoadError("已拦截不安全的内网或非法地址")
                        decisionHandler(.cancel)
                        return
                    }
                    if let host = url.host {
                        onVisitHost(host)
                    }
                    if navigationAction.targetFrame?.isMainFrame == true {
                        onURLChange(url.absoluteString)
                    }
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            onLoadError(nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            onLoadError(nil)
            if let host = webView.url?.host {
                onVisitHost(host)
            }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let notify = onCookiesUpdated
            Task { @MainActor in
                let cookies = await store.allCookies()
                notify(cookies)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            handleLoadError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            handleLoadError(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        private func handleLoadError(_ error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                return
            }
            onLoadError("页面加载失败：\(error.localizedDescription)")
        }
    }
}
