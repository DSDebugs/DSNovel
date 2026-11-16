import SwiftUI
import WebKit

/// 书源网页登录与人机验证请求模型（对齐 ssts WebScreenData / WebViewHost）
struct WebAuthSessionRequest: Identifiable {
    let id = UUID()
    let sourceID: String
    let title: String
    let initialURL: String
    let expectedCookieName: String?
    let onCompleted: () -> Void
}

/// 内嵌 WKWebView 网页登录与安全验证弹层：双向同步 HTTPCookieStorage 与 WKHTTPCookieStore，支持 loginDesktop UA 切换、loginScript 自动注入与按源精准校验登录状态
struct WebAuthSheet: View {
    let session: WebAuthSessionRequest
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
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
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, 8)
                .background(DSColor.cardSurface)

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
                                reloadTrigger += 1
                            } label: {
                                Label("切换备用登录入口", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }

                        Button {
                            reloadTrigger += 1
                        } label: {
                            Label("刷新当前页面", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("网页登录选项")

                    Button("完成") {
                        finishSession(isCancel: false)
                    }
                    .fontWeight(.semibold)
                    .disabled(isCompleting)
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
        let targetURL = activeTargetURL.isEmpty ? session.initialURL : activeTargetURL
        let isPureVerify = session.title.contains("验证") && !session.title.contains("登录")

        Task { @MainActor in
            _ = await CookieSync.pullFromWebView()
            let verifyResult = await PluginRuntime.shared.verifyLoginStatus(sourceID: session.sourceID)

            switch verifyResult {
            case .verified(let nickname):
                CookieSync.setVerifiedLogin(sourceID: session.sourceID, nickname: nickname)
                ToastManager.shared.show("登录成功：\(nickname)")
                session.onCompleted()
                dismiss()

            case .notLoggedIn:
                CookieSync.setVerifiedLogin(sourceID: session.sourceID, nickname: nil)
                if isCancel {
                    session.onCompleted()
                    dismiss()
                } else if isPureVerify {
                    ToastManager.shared.show("已完成网页验证")
                    session.onCompleted()
                    dismiss()
                } else {
                    ToastManager.shared.show("尚未检测到该书源的登录状态")
                    session.onCompleted()
                    dismiss()
                }

            case .noCheckMethod:
                // 对未定义 checkLogin() 的书源（如懒人听书），仅在用户主动点击「完成」且该站点已有 Cookie 时标记为该源已登录
                if !isCancel && CookieSync.hasCookies(for: targetURL) {
                    if !isPureVerify {
                        CookieSync.setVerifiedLogin(sourceID: session.sourceID, nickname: "已授权")
                        ToastManager.shared.show("已保存当前书源登录凭证")
                    } else {
                        ToastManager.shared.show("已完成网页验证")
                    }
                }
                session.onCompleted()
                dismiss()
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
            await CookieSync.pushToWebView()
            if let url = JsHostBridge.makeRequestURL(from: initialTarget) {
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let needReload = context.coordinator.lastLoadedURL != urlString
            || context.coordinator.lastDesktop != desktop
            || context.coordinator.lastReloadTrigger != reloadTrigger

        if needReload {
            context.coordinator.lastLoadedURL = urlString
            context.coordinator.lastDesktop = desktop
            context.coordinator.lastReloadTrigger = reloadTrigger
            webView.customUserAgent = desktop ? JsHostBridge.desktopUA : JsHostBridge.mobileUA
            if let url = JsHostBridge.makeRequestURL(from: urlString) {
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
            parent.onStateChange(webView.url?.absoluteString ?? parent.urlString, true, 0)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            syncCookiesAndRunScript(from: webView, isFinished: false)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncCookiesAndRunScript(from: webView, isFinished: true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            syncCookiesAndRunScript(from: webView, isFinished: true)
        }

        private func syncCookiesAndRunScript(from webView: WKWebView, isFinished: Bool) {
            let script = parent.loginScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFinished && !script.isEmpty {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
            let currentURL = webView.url?.absoluteString ?? parent.urlString
            let expectedName = parent.expectedCookieName
            Task { @MainActor in
                _ = await CookieSync.pullFromWebView()
                let domainCookieCount: Int
                if let targetURL = JsHostBridge.makeRequestURL(from: currentURL) {
                    domainCookieCount = CookieSync.cookies(for: targetURL).count
                } else {
                    domainCookieCount = 0
                }
                self.parent.onStateChange(currentURL, !isFinished, domainCookieCount)
                if let expected = expectedName, !expected.isEmpty, !self.didTriggerCompletion {
                    if let targetURL = JsHostBridge.makeRequestURL(from: currentURL),
                       CookieSync.cookies(for: targetURL).contains(where: { $0.name == expected && !$0.value.isEmpty }) {
                        self.didTriggerCompletion = true
                        self.parent.onExpectedCookieDetected()
                    }
                }
            }
        }
    }
}
