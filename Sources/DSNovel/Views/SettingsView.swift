import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(DualSourceEngine.self) private var engine
    @Environment(AudioPlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    let onOpenFullPlayer: () -> Void

    @State private var loginTargetSource: CoreSourceID? = nil
    @State private var cacheClearedBanner: Bool = false

    private let eqPresets = ["人声清晰", "低音增强", "夜间柔和", "原声直通"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("我的与听书设置")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 4)

                    // 0. 软件内部代理与 Quantumult X 脚本引擎专区（支持全局代理、喜马拉雅/番茄畅听单独代理及 QX 脚本）
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("软件内部代理与 Quantumult X", systemImage: "network.badge.shield.half.filled")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.orange)
                            Spacer()
                            NavigationLink {
                                QuantumultXCenterView()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("进入完整控制台")
                                        .font(.system(size: 12, weight: .bold))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundStyle(.orange)
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                ForEach(InAppProxyMode.allCases) { mode in
                                    GlassPillButton(
                                        title: mode.rawValue,
                                        isSelected: QuantumultXEngine.shared.isProxyEnabled ? (QuantumultXEngine.shared.proxyMode == mode) : (mode == .direct),
                                        activeColor: .orange,
                                        minHeight: 34
                                    ) {
                                        if mode == .direct {
                                            QuantumultXEngine.shared.isProxyEnabled = false
                                            QuantumultXEngine.shared.proxyMode = .direct
                                        } else {
                                            QuantumultXEngine.shared.proxyMode = mode
                                            QuantumultXEngine.shared.isProxyEnabled = true
                                        }
                                    }
                                }
                            }

                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("番茄畅听路由：\(QuantumultXEngine.shared.routeDescription(for: .fanqie))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Text("喜马拉雅路由：\(QuantumultXEngine.shared.routeDescription(for: .ximalaya))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                NavigationLink {
                                    QuantumultXCenterView()
                                } label: {
                                    Text("配置节点与QX脚本")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(Color.orange.gradient))
                                }
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                    }

                    // 1. 书源账号登录区（全软件唯一需要分离操作喜马拉雅与番茄畅听的地方）
                    VStack(alignment: .leading, spacing: 12) {
                        Label("书源账号登录（唯一分源操作区）", systemImage: "person.badge.key.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.orange)

                        ForEach(CoreSourceID.allCases) { source in
                            HStack(spacing: 12) {
                                Image(systemName: source.iconName)
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(source.brandColor))

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("\(source.displayName)账号")
                                            .font(.system(size: 15, weight: .bold))
                                        Text(engine.loginNicknames[source] != nil ? "已登录" : "未登录(免登可用)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(engine.loginNicknames[source] != nil ? .green : .secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.white.opacity(0.08)))
                                    }
                                    Text(source.loginCardSubtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if engine.loginNicknames[source] != nil {
                                    GlassPillButton(title: "退出登录", isSelected: false, minHeight: 36) {
                                        engine.logout(source: source)
                                    }
                                } else {
                                    GlassPillButton(
                                        title: "去登录",
                                        icon: "arrow.up.right.square",
                                        isSelected: true,
                                        activeColor: source.brandColor,
                                        minHeight: 36
                                    ) {
                                        loginTargetSource = source
                                    }
                                }
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                        }
                    }

                    // 2. 人声音效与自动跳过片头片尾
                    VStack(alignment: .leading, spacing: 12) {
                        Label("播放偏好与音效调节", systemImage: "waveform.path.ecg")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 14) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(eqPresets, id: \.self) { preset in
                                        GlassPillButton(
                                            title: preset,
                                            isSelected: player.activeEQPreset == preset,
                                            activeColor: .orange,
                                            minHeight: 34
                                        ) {
                                            player.activeEQPreset = preset
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("自动跳过片头：\(Int(player.skipIntroSeconds)) 秒")
                                    .font(.system(size: 14))
                                Spacer()
                                GlassPillButton(title: "-5s", isSelected: false, minHeight: 32) {
                                    player.skipIntroSeconds = max(0, player.skipIntroSeconds - 5)
                                }
                                GlassPillButton(title: "+5s", isSelected: false, minHeight: 32) {
                                    player.skipIntroSeconds = min(90, player.skipIntroSeconds + 5)
                                }
                            }

                            HStack {
                                Text("自动跳过片尾：\(Int(player.skipOutroSeconds)) 秒")
                                    .font(.system(size: 14))
                                Spacer()
                                GlassPillButton(title: "-5s", isSelected: false, minHeight: 32) {
                                    player.skipOutroSeconds = max(0, player.skipOutroSeconds - 5)
                                }
                                GlassPillButton(title: "+5s", isSelected: false, minHeight: 32) {
                                    player.skipOutroSeconds = min(90, player.skipOutroSeconds + 5)
                                }
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                    }

                    // 3. 我的收听书签速览（点击即刻跳转播放器对应时间点）
                    if !library.bookmarks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("我的收听书签 (\(library.bookmarks.count))", systemImage: "bookmark.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.orange)

                            ForEach(Array(library.bookmarks.prefix(5))) { bm in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(bm.bookTitle) · \(bm.episodeTitle)")
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                        Text("时间点：\(bm.formattedTimestamp)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    GlassIconButton(systemName: "trash", tint: .red, size: 32) {
                                        library.removeBookmark(bm.id)
                                    }
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                            }
                        }
                    }

                    // 4. 缓存管理
                    VStack(alignment: .leading, spacing: 12) {
                        Label("存储与缓存", systemImage: "internaldrive.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.orange)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("刷新目录与书城内存缓存")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(cacheClearedBanner ? "缓存已刷新！" : "当连载章节有更新时可点击清理并重新同步")
                                    .font(.system(size: 12))
                                    .foregroundStyle(cacheClearedBanner ? .green : .secondary)
                            }
                            Spacer()
                            GlassPillButton(title: "立即刷新", icon: "arrow.clockwise", isSelected: false, minHeight: 36) {
                                engine.clearAllCaches()
                                cacheClearedBanner = true
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 125)
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $loginTargetSource) { source in
                SourceWebLoginSheet(source: source)
            }
        }
    }
}

struct SourceWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DualSourceEngine.self) private var engine
    let source: CoreSourceID

    var body: some View {
        NavigationStack {
            CookieLoginWebView(url: source.loginURL, domainFilter: source.cookieDomain) { cookieHeader in
                engine.saveCookies(cookieHeader, for: source)
                dismiss()
            }
            .navigationTitle("登录\(source.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

struct CookieLoginWebView: UIViewRepresentable {
    let url: URL
    let domainFilter: String
    let onCapturedCookie: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(domainFilter: domainFilter, onCapturedCookie: onCapturedCookie)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let domainFilter: String
        let onCapturedCookie: (String) -> Void

        init(domainFilter: String, onCapturedCookie: @escaping (String) -> Void) {
            self.domainFilter = domainFilter
            self.onCapturedCookie = onCapturedCookie
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let matched = cookies.filter { $0.domain.contains(self.domainFilter) }
                let hasAuth = matched.contains { $0.name.contains("token") || $0.name.contains("session") || $0.name == "1&_token" }
                if hasAuth {
                    let header = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    Task { @MainActor in
                        self.onCapturedCookie(header)
                    }
                }
            }
        }
    }
}
