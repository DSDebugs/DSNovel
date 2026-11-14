import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(DualSourceEngine.self) private var engine
    @Environment(AudioPlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ProxyInterventionEngine.self) private var intervention

    let onOpenFullPlayer: () -> Void

    @State private var loginTargetSource: CoreSourceID? = nil
    @State private var isShowingAddURLSheet: Bool = false
    @State private var newURLTitle: String = ""
    @State private var newURLString: String = ""
    @State private var cacheClearedBanner: Bool = false

    private let eqPresets = ["人声清晰", "低音增强", "夜间柔和", "原声直通"]

    var body: some View {
        @Bindable var bindableIntervention = intervention

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("我的与听书设置")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 4)

                    // 1. 代理介入专区（集成 WeiGiegie/666/main/ximalaya.js，支持一键开启/关闭与添加在线 URL 更新）
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("代理介入", systemImage: "bolt.shield.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.orange)
                            Spacer()
                            Text(intervention.isEnabled ? "已开启介入" : "已关闭")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(intervention.isEnabled ? .green : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            // 代理介入主开关
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("启用代理介入")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("内置喜马拉雅会员调试、音质/章节试听介入与去广告规则")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $bindableIntervention.isEnabled)
                                    .labelsHidden()
                                    .tint(.orange)
                            }

                            Divider().overlay(Color.white.opacity(0.08))

                            // 状态与在线更新栏
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(intervention.statusMessage)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                    Text("已介入解锁 \(intervention.interventionHitCount) 次 · 拦截广告 \(intervention.adBlockedCount) 次")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                GlassPillButton(
                                    title: intervention.isUpdatingScript ? "更新中..." : "在线更新",
                                    icon: "arrow.triangle.2.circlepath",
                                    isSelected: true,
                                    activeColor: .orange,
                                    minHeight: 34
                                ) {
                                    Task {
                                        await intervention.updateFromOnlineURL()
                                    }
                                }

                                GlassPillButton(
                                    title: "添加URL",
                                    icon: "plus.circle.fill",
                                    isSelected: false,
                                    minHeight: 34
                                ) {
                                    newURLTitle = ""
                                    newURLString = ""
                                    isShowingAddURLSheet = true
                                }
                            }

                            // 在线脚本 URL 源列表（支持切换与删除自定义 URL）
                            VStack(alignment: .leading, spacing: 8) {
                                Text("在线脚本源（点击切换生效源）")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(intervention.scriptSources) { src in
                                    let isSelected = (intervention.activeSourceId == src.id)
                                    HStack(spacing: 10) {
                                        Button {
                                            intervention.activeSourceId = src.id
                                            Task {
                                                await intervention.updateFromOnlineURL(sourceId: src.id)
                                            }
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundStyle(isSelected ? .orange : .secondary)

                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack(spacing: 6) {
                                                        Text(src.title)
                                                            .font(.system(size: 13, weight: .semibold))
                                                            .foregroundStyle(.primary)
                                                            .lineLimit(1)
                                                        Text(src.lastUpdatedText)
                                                            .font(.system(size: 9.5, weight: .semibold))
                                                            .foregroundStyle(.green)
                                                            .padding(.horizontal, 5)
                                                            .padding(.vertical, 1.5)
                                                            .background(Capsule().fill(Color.green.opacity(0.14)))
                                                    }
                                                    Text(src.urlString)
                                                        .font(.system(size: 10.5, design: .monospaced))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(ResponsivePressButtonStyle())

                                        if !src.isBuiltIn {
                                            GlassIconButton(systemName: "trash", tint: .red, size: 30) {
                                                intervention.removeSource(id: src.id)
                                            }
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(isSelected ? Color.orange.opacity(0.12) : Color.white.opacity(0.04))
                                    )
                                }
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                    }

                    // 2. 书源账号登录区（全软件唯一需要分离操作喜马拉雅与番茄畅听的地方）
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

                    // 3. 播放偏好与音效调节
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
            .sheet(isPresented: $isShowingAddURLSheet) {
                NavigationStack {
                    Form {
                        Section("添加代理介入在线脚本 URL") {
                            TextField("名称备注（选填，如：喜马拉雅最新脚本）", text: $newURLTitle)
                            TextField("https://raw.githubusercontent.com/.../ximalaya.js", text: $newURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                    }
                    .navigationTitle("添加在线更新 URL")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { isShowingAddURLSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("添加并更新") {
                                intervention.addOnlineURL(title: newURLTitle, urlString: newURLString)
                                isShowingAddURLSheet = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
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
