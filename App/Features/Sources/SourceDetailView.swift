import DSCore
import DSDesignSystem
import DSDownloads
import DSPluginKit
import DSStorage
import SwiftUI

/// 书源详情、登录校验、喜马拉雅音频解析唯一入口、分组整理与单源清理
struct SourceDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner
    @Environment(AppSettingsStore.self) private var settings

    let sourceID: String

    @State private var meta: SourceMetaDTO?
    @State private var groupInput: String = ""
    @State private var activeAuthRequest: WebAuthRequest?
    @State private var showDeleteConfirm = false

    private var authStatus: SourceAuthStatus {
        container.sourceAuth.status(for: sourceID)
    }

    private var isXimalayaSource: Bool {
        sourceID == AppContainer.ximalayaSourceID
    }

    var body: some View {
        List {
            if let meta {
                Section("基本信息") {
                    LabeledContent("名称", value: meta.name)
                        .listRowBackground(DSColors.surfaceCard)
                    LabeledContent("版本", value: "v\(meta.version)")
                        .listRowBackground(DSColors.surfaceCard)
                    LabeledContent("作者", value: meta.author)
                        .listRowBackground(DSColors.surfaceCard)
                    LabeledContent("权限模式", value: meta.permissionMode == .compatApproved ? "兼容放行（用户确认）" : "声明域名白名单")
                        .listRowBackground(DSColors.surfaceCard)
                    if !meta.declaredHosts.isEmpty {
                        LabeledContent("声明域名", value: meta.declaredHosts.joined(separator: ", "))
                            .listRowBackground(DSColors.surfaceCard)
                    }
                    if !meta.summary.isEmpty {
                        Text(meta.summary)
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                            .listRowBackground(DSColors.surfaceCard)
                    }
                }

                if isXimalayaSource && settings.builtinParserUnlocked {
                    Section {
                        Button {
                            router.push(.builtinParser)
                        } label: {
                            HStack {
                                Label("音频解析", systemImage: "waveform.badge.magnifyingglass")
                                    .foregroundStyle(DSColors.inkPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.inkSecondary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ximalaya_audio_parser_entry")
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }

                Section("书源整理") {
                    Toggle("启用该书源", isOn: Binding(
                        get: { meta.isEnabled },
                        set: { next in Task { await updateOrganization(isEnabled: next, isPinned: nil, groupName: nil) } }
                    ))
                    .tint(DSColors.accent)
                    .listRowBackground(DSColors.surfaceCard)

                    Toggle("置顶展示", isOn: Binding(
                        get: { meta.isPinned },
                        set: { next in Task { await updateOrganization(isEnabled: nil, isPinned: next, groupName: nil) } }
                    ))
                    .tint(DSColors.accent)
                    .listRowBackground(DSColors.surfaceCard)

                    HStack {
                        TextField("分组名称", text: $groupInput)
                        Button("保存分组") {
                            Task { await updateOrganization(isEnabled: nil, isPinned: nil, groupName: groupInput) }
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 36)
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }

                if meta.loginURL != nil || meta.methods.contains("checkLogin") {
                    Section("账号登录") {
                        HStack {
                            Text("登录状态")
                            Spacer()
                            loginStatusView
                        }
                        .listRowBackground(DSColors.surfaceCard)

                        if let loginStr = meta.loginURL, let loginURL = URL(string: loginStr) {
                            Button(authStatus.isLoggedIn ? "重新打开网页登录" : "打开网页登录") {
                                activeAuthRequest = WebAuthRequest(
                                    sourceID: meta.id,
                                    title: meta.name,
                                    loginURL: loginURL,
                                    allowedHosts: meta.declaredHosts
                                )
                            }
                            .frame(minHeight: 44)
                            .listRowBackground(DSColors.surfaceCard)
                        }

                        if meta.methods.contains("checkLogin") {
                            Button("重新检测登录状态") {
                                Task { await verifyLoginStatus(sourceID: meta.id, showBanner: true) }
                            }
                            .disabled(authStatus.isChecking)
                            .frame(minHeight: 44)
                            .listRowBackground(DSColors.surfaceCard)
                        }

                        Button("退出登录（清除 Cookie）", role: .destructive) {
                            Task { await clearLoginCookies(for: meta) }
                        }
                        .frame(minHeight: 44)
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }

                Section {
                    Button("移除书源", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .frame(minHeight: 44)
                    .listRowBackground(DSColors.surfaceCard)
                }
            } else {
                ProgressView("正在加载书源信息...")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle(meta?.name ?? "书源详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeAuthRequest, onDismiss: {
            Task { await verifyLoginStatus(sourceID: sourceID, showBanner: false) }
        }) { req in
            WebAuthScreen(request: req) {
                activeAuthRequest = nil
            }
        }
        .alert("确认移除书源？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                Task { await deleteCurrentSource() }
            }
        } message: {
            Text("移除后该书源将不再参与发现与搜索，可随时重新导入或重置内置书源恢复。")
        }
        .task { await loadMeta() }
    }

    @ViewBuilder
    private var loginStatusView: some View {
        switch authStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("检测中...")
                    .font(DSTypography.footnote)
                    .foregroundStyle(DSColors.inkSecondary)
            }
        case .loggedIn(let nickname):
            HStack(spacing: 6) {
                DSBadge("已登录", style: .success)
                if !nickname.isEmpty {
                    Text(nickname)
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(1)
                }
            }
        case .loggedOut(let reason):
            HStack(spacing: 6) {
                DSBadge("未登录", style: .warning)
                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }
            }
        case .unknown:
            Text("未检测")
                .font(DSTypography.footnote)
                .foregroundStyle(DSColors.inkSecondary)
        }
    }

    private func loadMeta() async {
        await container.ensureSourcesRegistered()
        guard let all = try? await container.persistence.fetchAllSources(),
              let found = all.first(where: { $0.meta.id == sourceID }) else { return }
        meta = found.meta
        groupInput = found.meta.groupName
        if found.meta.loginURL != nil || found.meta.methods.contains("checkLogin") {
            await verifyLoginStatus(sourceID: found.meta.id, showBanner: false)
        }
    }

    private func updateOrganization(isEnabled: Bool?, isPinned: Bool?, groupName: String?) async {
        do {
            try await container.persistence.updateSourceOrganization(
                id: sourceID,
                isEnabled: isEnabled,
                isPinned: isPinned,
                groupName: groupName
            )
            if let all = try? await container.persistence.fetchAllSources() {
                await container.pluginRuntime.registerSources(all)
                if let found = all.first(where: { $0.meta.id == sourceID }) {
                    meta = found.meta
                    groupInput = found.meta.groupName
                }
            }
            container.notifySourcesChanged()
            banner.show("书源设置已更新", tone: .success)
        } catch {
            banner.show("更新失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func clearLoginCookies(for meta: SourceMetaDTO) async {
        var domains = Set(meta.declaredHosts)
        if let rawLogin = meta.loginURL, let host = URL(string: rawLogin)?.host {
            domains.insert(host)
        }
        for domain in domains {
            await container.cookieVault.clearCookies(forDomain: domain)
        }
        container.sourceAuth.markLoggedOut(sourceID: meta.id, reason: "已退出登录")
        downloads.invalidateResumeDataOnAuthOrNetworkChange()
        banner.show("已清除 \(meta.name) 的登录 Cookie", tone: .info)
    }

    private func verifyLoginStatus(sourceID: String, showBanner: Bool) async {
        let status = await container.sourceAuth.refresh(
            sourceID: sourceID,
            runtime: container.pluginRuntime,
            force: true
        )
        guard showBanner else { return }
        switch status {
        case .loggedIn(let nickname):
            let display = nickname.isEmpty ? "登录状态有效" : "已登录：\(nickname)"
            banner.show(display, tone: .success)
        case .loggedOut(let reason):
            banner.show("未登录：\(reason ?? "请重新登录")", tone: .warning)
        case .checking, .unknown:
            break
        }
    }

    private func deleteCurrentSource() async {
        do {
            try await container.persistence.deleteSource(id: sourceID)
            if let all = try? await container.persistence.fetchAllSources() {
                await container.pluginRuntime.registerSources(all)
            }
            container.notifySourcesChanged()
            banner.show("已移除书源", tone: .info)
            router.pop()
        } catch {
            banner.show("移除失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
