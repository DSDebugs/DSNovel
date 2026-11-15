import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(DualSourceEngine.self) private var engine
    @Environment(AudioPlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(QXRewriteParserEngine.self) private var qxParser
    @Environment(CompliantDataUpdateModule.self) private var dataUpdater

    let onOpenFullPlayer: () -> Void

    @State private var loginTargetSource: CoreSourceID? = nil
    @State private var cacheClearedBanner: Bool = false
    @State private var isShowingAddDataSourceSheet: Bool = false
    @State private var isShowingPasteRewriteSheet: Bool = false
    @State private var newSourceTitle: String = ""
    @State private var newSourceURL: String = ""
    @State private var newSourceKind: CompliantFeedKind = .qxRewriteConf
    @State private var pastedRewriteText: String = "[rewrite_local]\n"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("我的与听书设置")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 4)


                    // 0. 合规数据更新模块与 Quantumult X 重写解析器（无预设地址，仅支持用户添加 HTTPS 数据源与标准 [rewrite_local] 规则）
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("数据更新与 QX 重写解析器", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.orange)
                            Spacer()
                            Text(qxParser.isEnabled ? "已启用 (\(qxParser.rules.filter { $0.isEnabled }.count)条)" : "未启用")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(qxParser.isEnabled ? .green : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("启用 Quantumult X 重写解析模块")
                                        .font(.system(size: 14, weight: .bold))
                                    Text("支持 [rewrite_local] 请求头/响应体/脚本重写与本地 Mock 调试")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { qxParser.isEnabled }, set: { qxParser.isEnabled = $0 }))
                                    .labelsHidden()
                                    .tint(.orange)
                            }

                            Divider().overlay(Color.white.opacity(0.08))

                            HStack(spacing: 8) {
                                Text(dataUpdater.statusMessage)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                                Spacer()
                                GlassPillButton(title: "添加HTTPS源", icon: "plus.circle.fill", isSelected: true, activeColor: .orange, minHeight: 32) {
                                    newSourceTitle = ""
                                    newSourceURL = ""
                                    isShowingAddDataSourceSheet = true
                                }
                                GlassPillButton(title: "导入规则", icon: "doc.text", isSelected: false, minHeight: 32) {
                                    isShowingPasteRewriteSheet = true
                                }
                            }

                            if !dataUpdater.sources.isEmpty {
                                ForEach(dataUpdater.sources) { src in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(src.title) · \(src.kind.rawValue)")
                                                .font(.system(size: 12.5, weight: .semibold))
                                            Text("\(src.lastUpdatedText) · \(src.urlString)")
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        GlassPillButton(title: "同步", isSelected: false, minHeight: 28) {
                                            Task { await dataUpdater.syncSource(id: src.id) }
                                        }
                                        GlassIconButton(systemName: "trash", accessibilityTitle: "删除数据源", tint: .red, size: 28) {
                                            dataUpdater.removeSource(id: src.id)
                                        }
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                                }
                            }

                            if !qxParser.rules.isEmpty {
                                Divider().overlay(Color.white.opacity(0.08))
                                HStack {
                                    Text("已解析重写规则 (\(qxParser.rules.count)) · 命中 \(qxParser.hitCount) 次")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    GlassPillButton(title: "清空规则", isSelected: false, minHeight: 26) {
                                        qxParser.clearAllRules()
                                    }
                                }

                                ForEach(qxParser.rules) { rule in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(rule.action.displayLabel + " · " + rule.action.rawValue)
                                                .font(.system(size: 11.5, weight: .bold))
                                                .foregroundStyle(.orange)
                                            Text(rule.urlPattern)
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        GlassPillButton(title: rule.isEnabled ? "启用" : "停用", isSelected: rule.isEnabled, activeColor: .green, minHeight: 28) {
                                            qxParser.toggleRule(id: rule.id)
                                        }
                                        GlassIconButton(systemName: "trash", accessibilityTitle: "删除规则", tint: .red, size: 28) {
                                            qxParser.removeRule(id: rule.id)
                                        }
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                                }
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                    }

                    // 1. 书源账号登录区（Keychain 安全存储 + 退出清理 WebKit 会话）
                    VStack(alignment: .leading, spacing: 12) {
                        Label("书源账号登录", systemImage: "person.badge.key.fill")
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
                                        Text(engine.loginNicknames[source] != nil ? "已登录" : "未登录")
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
                                        clearWebViewCookies(domain: source.cookieDomain)
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

                    // 2. 播放偏好（支持持久化）
                    VStack(alignment: .leading, spacing: 12) {
                        Label("播放偏好与跳过片头片尾", systemImage: "waveform.path.ecg")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 14) {
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

                    // 3. 缓存管理
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
            .sheet(isPresented: $isShowingAddDataSourceSheet) {
                NavigationStack {
                    Form {
                        Section("添加合规 HTTPS 数据源") {
                            TextField("名称备注（选填）", text: $newSourceTitle)
                            TextField("https://example.com/feed.json", text: $newSourceURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            Picker("数据格式类型", selection: $newSourceKind) {
                                ForEach(CompliantFeedKind.allCases) { k in
                                    Text(k.rawValue).tag(k)
                                }
                            }
                        }
                    }
                    .navigationTitle("添加 HTTPS 数据源")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { isShowingAddDataSourceSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("添加并同步") {
                                let t = newSourceTitle
                                let u = newSourceURL
                                let k = newSourceKind
                                isShowingAddDataSourceSheet = false
                                Task { _ = await dataUpdater.addSource(title: t, urlString: u, kind: k) }
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isShowingPasteRewriteSheet) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("粘贴 Quantumult X [rewrite_local] 规则文本：")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $pastedRewriteText)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                    }
                    .padding(16)
                    .navigationTitle("导入 QX 重写规则")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { isShowingPasteRewriteSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("解析导入") {
                                let txt = pastedRewriteText
                                isShowingPasteRewriteSheet = false
                                Task { _ = await qxParser.importRules(from: txt) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func clearWebViewCookies(domain: String) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.lowercased().hasSuffix(domain.lowercased()) {
                store.delete(cookie)
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
                let matched = cookies.filter {
                    let d = $0.domain.lowercased()
                    return d == self.domainFilter || d.hasSuffix("." + self.domainFilter)
                }
                let hasAuth = matched.contains { $0.name == "1&_token" || $0.name == "1&_device" }
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
