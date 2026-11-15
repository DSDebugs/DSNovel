import SwiftUI
import WebKit

struct WebAuthSessionRequest: Identifiable {
    let id = UUID()
    let sourceID: String
    let title: String
    let initialURL: String
    let expectedCookieName: String?
    var onCompleted: (() -> Void)?
}

/// 统一的登录与人机验证弹层（WKWebView + 顶部进度条 + WKHTTPCookieStore 自动同步）
struct WebAuthSheet: View {
    let session: WebAuthSessionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0.1
    @State private var currentURLString: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if progress < 1.0 {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(DSColor.primary)
                }

                WebAuthRepresentable(
                    urlString: session.initialURL,
                    expectedCookieName: session.expectedCookieName,
                    progress: $progress,
                    currentURLString: $currentURLString,
                    onVerified: {
                        ToastManager.shared.show("验证/登录已同步")
                        session.onCompleted?()
                        dismiss()
                    }
                )
            }
            .background(DSColor.contentBackground)
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        WebAuthRepresentable.syncCookiesToSharedStorage {
                            session.onCompleted?()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct WebAuthRepresentable: UIViewRepresentable {
    let urlString: String
    let expectedCookieName: String?
    @Binding var progress: Double
    @Binding var currentURLString: String
    let onVerified: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observeProgress(of: webView)

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func syncCookiesToSharedStorage(completion: @escaping @MainActor () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            Task { @MainActor in
                completion()
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebAuthRepresentable
        private var observation: NSKeyValueObservation?

        init(parent: WebAuthRepresentable) {
            self.parent = parent
        }

        func observeProgress(of webView: WKWebView) {
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.parent.progress = wv.estimatedProgress
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let current = webView.url?.absoluteString ?? ""
            Task { @MainActor in
                self.parent.currentURLString = current
            }
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                if let expected = self.parent.expectedCookieName, !expected.isEmpty,
                   cookies.contains(where: { $0.name.lowercased().contains(expected.lowercased()) }) {
                    Task { @MainActor in
                        self.parent.onVerified()
                    }
                }
            }
        }
    }
}
