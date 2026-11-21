import DSCore
import DSDesignSystem
import SwiftUI

/// 单个书源详情页（展示 Q5 权限模式、声明域名与支持方法）
struct SourceDetailView: View {
    @Environment(AppContainer.self) private var container
    private let sourceID: String
    @State private var meta: SourceMetaDTO?
    @State private var isLoading = true
    @State private var activeAuthRequest: WebAuthRequest?
    @State private var loginStatusText: String?
    @State private var isCheckingLogin = false

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView("正在加载书源详情...")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if let m = meta {
                let validLoginURL = m.loginURL.flatMap(URL.init(string:))
                Section("基本信息") {
                    row("名称", m.name)
                    row("标识", m.id)
                    row("版本", m.version)
                    row("作者", m.author.isEmpty ? "未知" : m.author)
                    row("分组", m.groupName)
                }
                Section("安全与权限模式") {
                    row("模式", m.permissionMode == .compatApproved ? "兼容放行（已确认）" : "声明白名单")
                    row("声明域名", m.declaredHosts.isEmpty ? "未声明（宿主 SSRF 防护仍生效）" : m.declaredHosts.joined(separator: ", "))
                    row("能力接口", m.methods.joined(separator: ", "))
                }
                if validLoginURL != nil || m.methods.contains("checkLogin") {
                    Section("账号登录") {
                        if let url = validLoginURL {
                            Button("网页登录并同步 Cookie") {
                                activeAuthRequest = WebAuthRequest(sourceID: m.id, title: m.name, loginURL: url)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        if m.methods.contains("checkLogin") {
                            Button {
                                Task { await verifyLoginStatus(sourceID: m.id) }
                            } label: {
                                HStack {
                                    Text(isCheckingLogin ? "正在验证登录状态..." : "验证当前登录状态")
                                    Spacer()
                                    if isCheckingLogin { ProgressView() }
                                }
                                .frame(minHeight: 44)
                            }
                            .disabled(isCheckingLogin)
                        }
                        if let statusText = loginStatusText {
                            Text(statusText)
                                .font(DSTypography.footnote)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                    }
                }
            } else {
                DSStateView(
                    icon: "exclamationmark.circle",
                    title: "未找到该书源",
                    message: "该书源可能已被删除或尚未加载。"
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceBase)
        .navigationTitle(meta?.name ?? "书源详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeAuthRequest) { req in
            WebAuthScreen(request: req) { activeAuthRequest = nil }
        }
        .task(id: sourceID) {
            isLoading = true
            defer { isLoading = false }
            if let all = try? await container.persistence.fetchAllSources() {
                meta = all.first(where: { $0.meta.id == sourceID })?.meta
            } else {
                meta = nil
            }
        }
    }

    private func verifyLoginStatus(sourceID: String) async {
        guard !isCheckingLogin else { return }
        isCheckingLogin = true
        defer { isCheckingLogin = false }
        do {
            let nickname = try await container.pluginRuntime.checkLogin(sourceID: sourceID)
            loginStatusText = nickname.isEmpty ? "登录状态有效" : "已登录：\(nickname)"
        } catch {
            loginStatusText = "未登录或已过期：\(error.localizedDescription)"
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value)
                .font(DSTypography.footnote)
                .foregroundStyle(DSColors.inkSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
