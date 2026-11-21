import SwiftUI
import WebKit

/// 书源网页登录与人机验证请求模型（对齐 ssts WebScreenData / WebViewHost；9-5 内置单次终态守护，防止下拉关闭与完成/取消重复回调）
struct WebAuthSessionRequest: Identifiable {
    private final class OutcomeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func tryClaim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    let id = UUID()
    let sourceID: String
    let title: String
    let initialURL: String
    let expectedCookieName: String?
    let onCompleted: () -> Void
    let onCancelled: (() -> Void)?
    private let outcomeGuard = OutcomeGuard()

    init(
        sourceID: String,
        title: String,
        initialURL: String,
        expectedCookieName: String? = nil,
        onCompleted: @escaping () -> Void,
        onCancelled: (() -> Void)? = nil
    ) {
        let guardBox = OutcomeGuard()
        self.outcomeGuard = guardBox
        self.sourceID = sourceID
        self.title = title
        self.initialURL = initialURL
        self.expectedCookieName = expectedCookieName
        self.onCompleted = {
            guard guardBox.tryClaim() else { return }
            onCompleted()
        }
        if let onCancelled {
            self.onCancelled = {
                guard guardBox.tryClaim() else { return }
                onCancelled()
            }
        } else {
            self.onCancelled = nil
        }
    }
}

/// 内嵌 WKWebView 网页登录与安全验证弹层：双向同步 HTTPCookieStorage 与 WKHTTPCookieStore，支持 loginDesktop UA 切换、loginScript 自动注入与按源精准校验登录状态
struct WebAuthSheet: View {
    let session: WebAuthSessionRequest

    init(session: WebAuthSessionRequest) {
        self.session = session
    }

    @Environment(\.dismiss) private var dismiss

    @State private var currentURLString: String = ""
    @State private var isLoading: Bool = true
    @State private var capturedCookiesCount: Int = 0
    @State private var isDesktopUA: Bool = false
    @State private var loginScript: String = ""
    @State private var altLoginURL: String = ""
    @State private var activeTargetURL: String = ""
    @State private var reloadTrigger: Int = 0
    @State private var isCompleting: Bool = false
    @State private var verificationWarning: String? = nil
    @State private var loadErrorMessage: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let warning = verificationWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Spacer()
                    } else {
                        Image(systemName: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(DSColor.primary)
                        Text(currentURLString.isEmpty ? session.initialURL : currentURLString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else if capturedCookiesCount > 0 {
                            Text("当前站点已同步 \(capturedCookiesCount) 项 Cookie")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, 8)
                .background(verificationWarning != nil ? Color.red.opacity(0.1) : DSColor.cardSurface)

                if let loadErrorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(loadErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                        Button("重新加载") {
                            self.loadErrorMessage = nil
                            self.verificationWarning = nil
                            self.reloadTrigger += 1
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                }

                WebAuthViewRepresentable(
                    urlString: activeTargetURL.isEmpty ? session.initialURL : activeTargetURL,
                    desktop: isDesktopUA,
                    loginScript: loginScript,
                    reloadTrigger: reloadTrigger,
                    expectedCookieName: session.expectedCookieName,
                    onStateChange: { urlStr, loading, cookieCount in
                        self.currentURLString = urlStr
                        self.isLoading = loading
                        self.capturedCookiesCount = cookieCount
                    },
                    onLoadError: { message in
                        self.loadErrorMessage = message
                    },
                    onExpectedCookieDetected: {
                        finishSession(isCancel: false)
                    }
                )
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        finishSession(isCancel: true)
                    }
                    .disabled(isCompleting)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isDesktopUA.toggle()
                            loadErrorMessage = nil
                            verificationWarning = nil
                            reloadTrigger += 1
                        } label: {
                            Label(
                                isDesktopUA ? "切换为手机版网页" : "切换为桌面版网页（推荐扫码）",
                                systemImage: isDesktopUA ? "iphone" : "desktopcomputer"
                            )
                        }

                        if !altLoginURL.isEmpty {
                            Button {
                                activeTargetURL = (activeTargetURL == altLoginURL) ? session.initialURL : altLoginURL
                                loadErrorMessage = nil
                                verificationWarning = nil
                                reloadTrigger += 1
                            } label: {
                                Label("切换备用登录入口", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }

                        Button {
                            loadErrorMessage = nil
                            verificationWarning = nil
                            reloadTrigger += 1
                        } label: {
                            Label("刷新当前页面", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("网页登录选项")
                    .disabled(isCompleting)

                    if isCompleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("完成") {
                            finishSession(isCancel: false)
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .task {
                if let meta = await PluginRuntime.shared.sourceLoginMeta(sourceID: session.sourceID) {
                    isDesktopUA = meta.loginDesktop
                    loginScript = meta.loginScript
                    altLoginURL = meta.loginAltURL
                    if session.initialURL.isEmpty {
                        activeTargetURL = meta.loginURL.isEmpty ? meta.siteURL : meta.loginURL
                    } else {
                        activeTargetURL = session.initialURL
                    }
                } else {
                    activeTargetURL = session.initialURL
                }
            }
        }
    }

    private func finishSession(isCancel: Bool) {
        guard !isCompleting else { return }
        isCompleting = true
        verificationWarning = nil
        let targetURL = activeTargetURL.isEmpty ? session.initialURL : activeTargetURL
        let isPureVerify = session.title.contains("验证") && !session.title.contains("登录")

        Task { @MainActor in
            if isCancel {
                session.onCancelled?()
                dismiss()
                return
            }

            let filterURL = JsHostBridge.makeRequestURL(from: currentURLString.isEmpty ? targetURL : currentURLString)
                ?? JsHostBridge.makeRequestURL(from: targetURL)
            _ = await CookieSync.pullFromWebView(for: filterURL)
            let verifyResult = await PluginRuntime.shared.verifyLoginStatus(sourceID: session.sourceID)

            switch verifyResult {
            case .verified(let nickname):
                CookieSync.setVerifiedLogin(sourceID: session.sourceID, nickname: nickname)
                // 7-3：登录/鉴权刷新后作废该书源过期 resumeData 并以新 Cookie 重建下载请求
                await DownloadManager.shared.handleAuthOrCookieRefreshed(forSourceID: session.sourceID)
                // R4：登录成功提示统一交由 AuthCoordinator（通过 session.onCompleted 回调），避免与 Toast 重复横幅
                session.onCompleted()
                dismiss()

            case .notLoggedIn:
                CookieSync.setVerifiedLogin(sourceID: session.sourceID, nickname: nil)
                SourceStore.shared.markAuthExpired(sourceID: session.sourceID)
                if isPureVerify {
                    ToastManager.shared.show("已完成网页验证")
                    session.onCancelled?()
                    dismiss()
                } else {
                    // R4：未检测到登录态时保留登录页面，复位完成状态并在顶部状态条展示红色提示
                    isCompleting = false
                    verificationWarning = "尚未检测到登录状态，请完成登录后再点完成"
                }

            case .noCheckMethod:
                // 对未定义 checkLogin() 的书源，仅在用户主动点击「完成」且该站点已有 Cookie 时标记为该源已登录
                if CookieSync.hasCookies(for: targetURL) {
                    if !isPureVerify {
                        CookieSync.setVerifiedLogin(sourceID: session.sourceID, nickname: "已授权")
                        session.onCompleted()
                    } else {
                        ToastManager.shared.show("已完成网页验证")
                        session.onCancelled?()
                    }
                    dismiss()
                } else {
                    CookieSync.setVerifiedLogin(sourceID: session.sourceID, nickname: nil)
                    SourceStore.shared.markAuthExpired(sourceID: session.sourceID)
                    if isPureVerify {
                        ToastManager.shared.show("已完成网页验证")
                        session.onCancelled?()
                        dismiss()
                    } else {
                        isCompleting = false
                        verificationWarning = "尚未检测到登录状态，请完成登录后再点完成"
                    }
                }
            }
        }
    }
}

@MainActor
private struct WebAuthViewRepresentable: UIViewRepresentable {
    let urlString: String
    let desktop: Bool
    let loginScript: String
    let reloadTrigger: Int
    let expectedCookieName: String?
    let onStateChange: (String, Bool, Int) -> Void
    let onLoadError: (String?) -> Void
    let onExpectedCookieDetected: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = desktop ? JsHostBridge.desktopUA : JsHostBridge.mobileUA

        context.coordinator.lastLoadedURL = urlString
        context.coordinator.lastDesktop = desktop
        context.coordinator.lastReloadTrigger = reloadTrigger
        let initialTarget = urlString

        Task { @MainActor in
            let url = JsHostBridge.makeRequestURL(from: initialTarget)
            await CookieSync.pushToWebView(for: url)
            if let url {
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let urlChanged = context.coordinator.lastLoadedURL != urlString
        let needReload = urlChanged
            || context.coordinator.lastDesktop != desktop
            || context.coordinator.lastReloadTrigger != reloadTrigger

        if needReload {
            context.coordinator.lastLoadedURL = urlString
            context.coordinator.lastDesktop = desktop
            context.coordinator.lastReloadTrigger = reloadTrigger
            webView.customUserAgent = desktop ? JsHostBridge.desktopUA : JsHostBridge.mobileUA
            let target = urlString
            if urlChanged {
                Task { @MainActor in
                    let url = JsHostBridge.makeRequestURL(from: target)
                    await CookieSync.pushToWebView(for: url)
                    if let url {
                        webView.load(URLRequest(url: url))
                    }
                }
            } else if let url = JsHostBridge.makeRequestURL(from: target) {
                webView.load(URLRequest(url: url))
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebAuthViewRepresentable
        var didTriggerCompletion = false
        var lastLoadedURL: String = ""
        var lastDesktop: Bool = false
        var lastReloadTrigger: Int = 0

        init(parent: WebAuthViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadError(nil)
            parent.onStateChange(webView.url?.absoluteString ?? parent.urlString, true, 0)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.onLoadError(nil)
            parent.onStateChange(webView.url?.absoluteString ?? parent.urlString, true, 0)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadError(nil)
            syncCookiesAndRunScript(from: webView, isFinished: true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if !(nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                parent.onLoadError("页面加载失败：\(error.localizedDescription)")
            }
            syncCookiesAndRunScript(from: webView, isFinished: true)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if !(nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                parent.onLoadError("页面无法加载：\(error.localizedDescription)")
            }
            let currentURL = webView.url?.absoluteString ?? parent.urlString
            let domainCookieCount: Int
            if let targetURL = JsHostBridge.makeRequestURL(from: currentURL) {
                domainCookieCount = CookieSync.cookies(for: targetURL).count
            } else {
                domainCookieCount = 0
            }
            parent.onStateChange(currentURL, false, domainCookieCount)
        }

        private func syncCookiesAndRunScript(from webView: WKWebView, isFinished: Bool) {
            let script = parent.loginScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFinished && !script.isEmpty {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
            let currentURL = webView.url?.absoluteString ?? parent.urlString
            let expectedName = parent.expectedCookieName
            Task { @MainActor in
                let targetURL = JsHostBridge.makeRequestURL(from: currentURL)
                _ = await CookieSync.pullFromWebView(for: targetURL)
                let domainCookieCount: Int
                if let targetURL {
                    domainCookieCount = CookieSync.cookies(for: targetURL).count
                } else {
                    domainCookieCount = 0
                }
                self.parent.onStateChange(currentURL, !isFinished, domainCookieCount)
                if let expected = expectedName, !expected.isEmpty, !self.didTriggerCompletion {
                    if let targetURL,
                       CookieSync.cookies(for: targetURL).contains(where: { $0.name == expected && !$0.value.isEmpty }) {
                        self.didTriggerCompletion = true
                        self.parent.onExpectedCookieDetected()
                    }
                }
            }
        }
    }
}
