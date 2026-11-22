import DSCore
import DSDesignSystem
import SwiftUI

/// 单个书源详情页（1:1 复刻 v2.8：启用/置顶开关、账号登录状态、删除书源，保留 v3.0 安全模式与声明域名列表）
struct SourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @Environment(DSBannerCoordinator.self) private var banner
    private let sourceID: String

    @State private var meta: SourceMetaDTO?
    @State private var isLoading = true
    @State private var activeAuthRequest: WebAuthRequest?
    @State private var loginStatusText: String?
    @State private var isCheckingLogin = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

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

                Section {
                    HStack {
                        DSSourceBadge(
                            name: m.name,
                            health: m.isEnabled ? .healthy : .untested,
                            showHealthAndLatency: true
                        )
                        Spacer()
                        DSBadge(m.isEnabled ? "已启用" : "已停用", style: m.isEnabled ? .success : .neutral)
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }

                Section("启用与置顶") {
                    Toggle("启用书源", isOn: Binding(
                        get: { m.isEnabled },
                        set: { next in Task { await updateOrganization(isEnabled: next, isPinned: nil) } }
                    ))
                    .tint(DSColors.accent)
                    .listRowBackground(DSColors.surfaceCard)

                    Toggle("置顶书源", isOn: Binding(
                        get: { m.isPinned },
                        set: { next in Task { await updateOrganization(isEnabled: nil, isPinned: next) } }
                    ))
                    .tint(DSColors.accent)
                    .listRowBackground(DSColors.surfaceCard)
                }

                Section("基本信息") {
                    row("名称", m.name)
                    row("标识", m.id)
                    row("版本", "v\(m.version)")
                    row("作者", m.author.isEmpty ? "未知" : m.author)
                    row("分组", m.groupName.isEmpty ? "未分组" : m.groupName)
                }

                Section("安全与权限模式") {
                    row("安全模式", m.permissionMode == .compatApproved ? "兼容放行（已确认）" : "声明白名单")
                    row("声明域名", m.declaredHosts.isEmpty ? "未声明（宿主 SSRF 防护仍生效）" : m.declaredHosts.joined(separator: ", "))
                    row("能力接口", m.methods.joined(separator: ", "))
                }

                if validLoginURL != nil || m.methods.contains("checkLogin") {
                    Section("账号登录") {
                        row("登录状态", loginStatusText ?? "未检测")
                        if let url = validLoginURL {
                            Button("网页登录并同步 Cookie") {
                                activeAuthRequest = WebAuthRequest(sourceID: m.id, title: m.name, loginURL: url)
                            }
                            .foregroundStyle(DSColors.accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .listRowBackground(DSColors.surfaceCard)
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
                            .listRowBackground(DSColors.surfaceCard)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(isDeleting ? "正在删除..." : "删除书源", systemImage: "trash")
                            .foregroundStyle(DSColors.danger)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                    .listRowBackground(DSColors.surfaceCard)
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
        .background(DSColors.surfaceGrouped)
        .navigationTitle(meta?.name ?? "书源详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeAuthRequest) { req in
            WebAuthScreen(request: req) { activeAuthRequest = nil }
        }
        .alert("删除书源", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) {
                Task { await deleteCurrentSource() }
            }
        } message: {
            Text("确认删除书源「\(meta?.name ?? "")」？书架与离线下载记录将保留。")
        }
        .task(id: sourceID) {
            await loadMeta()
        }
    }

    private func loadMeta() async {
        isLoading = true
        defer { isLoading = false }
        if let all = try? await container.persistence.fetchAllSources() {
            meta = all.first(where: { $0.meta.id == sourceID })?.meta
        } else {
            meta = nil
        }
    }

    private func updateOrganization(isEnabled: Bool?, isPinned: Bool?) async {
        guard let old = meta else { return }
        meta = SourceMetaDTO(
            id: old.id, name: old.name, version: old.version, author: old.author,
            summary: old.summary, declaredHosts: old.declaredHosts,
            permissionMode: old.permissionMode, methods: old.methods,
            isEnabled: isEnabled ?? old.isEnabled,
            isPinned: isPinned ?? old.isPinned,
            groupName: old.groupName, sortOrder: old.sortOrder, loginURL: old.loginURL
        )
        do {
            try await container.persistence.updateSourceOrganization(id: old.id, isEnabled: isEnabled, isPinned: isPinned)
            if let all = try? await container.persistence.fetchAllSources() {
                await container.pluginRuntime.registerSources(all)
            }
            container.notifySourcesChanged()
            DSHaptics.selection()
        } catch {
            meta = old
            banner.show("更新书源设置失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func deleteCurrentSource() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await container.persistence.deleteSource(id: sourceID)
            if let all = try? await container.persistence.fetchAllSources() {
                await container.pluginRuntime.registerSources(all)
            }
            container.notifySourcesChanged()
            banner.show("已删除书源", tone: .info)
            dismiss()
        } catch {
            banner.show("删除书源失败：\(error.localizedDescription)", tone: .error)
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
        .listRowBackground(DSColors.surfaceCard)
    }
}
