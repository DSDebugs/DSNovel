import DSCore
import DSDesignSystem
import DSDownloads
import DSPluginKit
import DSStorage
import SwiftUI

/// 新版书源详情页（Hero 头卡 + 书源设置下拉换组 + 按需账号与解析卡 + 移除书源）
struct SourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner
    @Environment(AppSettingsStore.self) private var settings

    let sourceID: String

    @State private var meta: SourceMetaDTO?
    @State private var allGroupNames: [String] = [SourceListHelper.defaultGroupName]
    @State private var activeAuthRequest: WebAuthRequest?
    @State private var showDeleteConfirm = false
    @State private var showNewGroupAlert = false
    @State private var newGroupInput = ""

    private var authStatus: SourceAuthStatus {
        container.sourceAuth.status(for: sourceID)
    }

    private var isXimalayaSource: Bool {
        sourceID == AppContainer.ximalayaSourceID
    }

    var body: some View {
        List {
            if let meta {
                Section {
                    heroHeaderCard(meta)
                        .listRowInsets(EdgeInsets(top: DSSpacing.sm, leading: DSSpacing.md, bottom: DSSpacing.sm, trailing: DSSpacing.md))
                        .listRowBackground(DSColors.surfaceCard)
                }

                Section("书源设置") {
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

                    groupPickerRow(meta)
                        .listRowBackground(DSColors.surfaceCard)
                }

                let needsLogin = SourceListHelper.supportsLogin(meta)
                let showParser = isXimalayaSource && settings.builtinParserUnlocked
                if needsLogin || showParser {
                    Section(needsLogin && showParser ? "账号与解析" : (needsLogin ? "账号登录" : "音频解析")) {
                        if needsLogin {
                            accountStatusRow(meta)
                                .listRowBackground(DSColors.surfaceCard)
                        }
                        if showParser {
                            Button {
                                router.push(.builtinParser)
                            } label: {
                                HStack(spacing: DSSpacing.sm) {
                                    Image(systemName: "waveform.badge.magnifyingglass")
                                        .foregroundStyle(DSColors.accent)
                                    Text("音频解析")
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
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("移除书源")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DSColors.danger)
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
        .navigationTitle("书源详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeAuthRequest, onDismiss: {
            Task { await verifyLoginStatus(sourceID: sourceID, showBanner: false) }
        }) { req in
            WebAuthScreen(request: req) {
                activeAuthRequest = nil
            }
        }
        .alert("新建并移入分组", isPresented: $showNewGroupAlert) {
            TextField("输入分组名称", text: $newGroupInput)
            Button("取消", role: .cancel) {}
            Button("确定") {
                let clean = newGroupInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return }
                settings.addCustomSourceGroup(clean)
                Task { await updateOrganization(isEnabled: nil, isPinned: nil, groupName: clean) }
            }
        }
        .alert("确认移除书源？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                Task { await deleteCurrentSource() }
            }
        } message: {
            Text("移除后该书源将不再参与发现与搜索，可随时重新导入或恢复内置书源。")
        }
        .task { await loadMeta() }
    }

    private func heroHeaderCard(_ meta: SourceMetaDTO) -> some View {
        let supportsLogin = SourceListHelper.supportsLogin(meta)
        return HStack(spacing: DSSpacing.md) {
            DSSourceAvatar(name: meta.name, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(meta.name)
                        .font(DSTypography.title)
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(1)
                    if supportsLogin {
                        heroAuthBadge
                    } else {
                        DSBadge("免登录", style: .success)
                    }
                    DSBadge("v\(meta.version)", style: .neutral)
                }
                Text(SourceListHelper.conciseSummary(for: meta))
                    .font(DSTypography.footnote)
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var heroAuthBadge: some View {
        switch authStatus {
        case .loggedIn:
            DSBadge("已登录", style: .success)
        case .checking:
            DSBadge("检测中", style: .neutral)
        case .loggedOut, .unknown:
            DSBadge("未登录", style: .warning)
        }
    }

    private func groupPickerRow(_ meta: SourceMetaDTO) -> some View {
        let currentGroup = SourceListHelper.normalizedGroupName(meta.groupName)
        return HStack {
            Text("所属分组")
                .foregroundStyle(DSColors.inkPrimary)
            Spacer()
            Menu {
                ForEach(allGroupNames, id: \.self) { g in
                    Button {
                        DSHaptics.selection()
                        Task { await updateOrganization(isEnabled: nil, isPinned: nil, groupName: g) }
                    } label: {
                        HStack {
                            Text(g)
                            if g == currentGroup { Image(systemName: "checkmark") }
                        }
                    }
                }
                Divider()
                Button {
                    newGroupInput = ""
                    showNewGroupAlert = true
                } label: {
                    Label("新建分组…", systemImage: "folder.badge.plus")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentGroup)
                        .font(DSTypography.subheadline.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(DSTypography.caption2)
                }
                .foregroundStyle(DSColors.inkPrimary)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, 6)
                .background(Capsule().fill(DSColors.surfaceGrouped))
            }
            .tint(DSColors.accent)
        }
        .frame(minHeight: 36)
    }

    private func accountStatusRow(_ meta: SourceMetaDTO) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .center, spacing: DSSpacing.xs) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("账号状态")
                        .font(DSTypography.subheadline.weight(.medium))
                        .foregroundStyle(DSColors.inkPrimary)
                    accountSubtitleButton(meta)
                }
                Spacer(minLength: DSSpacing.xs)
                if let loginStr = meta.loginURL, let loginURL = URL(string: loginStr) {
                    Button {
                        activeAuthRequest = WebAuthRequest(
                            sourceID: meta.id,
                            title: meta.name,
                            loginURL: loginURL,
                            allowedHosts: meta.declaredHosts
                        )
                    } label: {
                        Text(authStatus.isLoggedIn ? "重新登录" : "登录账号")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.onAccent)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 32)
                            .background(Capsule().fill(DSColors.accent))
                    }
                    .buttonStyle(.plain)
                }
                if authStatus.isLoggedIn {
                    Button {
                        Task { await clearLoginCookies(for: meta) }
                    } label: {
                        Text("退出登录")
                            .font(DSTypography.caption.weight(.medium))
                            .foregroundStyle(DSColors.danger)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 32)
                            .background(Capsule().fill(DSColors.danger.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func accountSubtitleButton(_ meta: SourceMetaDTO) -> some View {
        Button {
            if meta.methods.contains("checkLogin") && !authStatus.isChecking {
                Task { await verifyLoginStatus(sourceID: meta.id, showBanner: true) }
            }
        } label: {
            HStack(spacing: 5) {
                switch authStatus {
                case .checking:
                    ProgressView().controlSize(.mini)
                    Text("正在检测登录状态…")
                case .loggedIn(let nickname):
                    Circle().fill(DSColors.success).frame(width: 7, height: 7)
                    Text(nickname.isEmpty ? "已登录（点按刷新）" : nickname)
                case .loggedOut, .unknown:
                    Circle().fill(DSColors.warning).frame(width: 7, height: 7)
                    Text("未登录（点按检测）")
                }
            }
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.inkSecondary)
        }
        .buttonStyle(.plain)
    }

    private func loadMeta() async {
        await container.ensureSourcesRegistered()
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let metas = all.map(\.meta)
        allGroupNames = SourceListHelper.allGroupNames(sources: metas, customGroups: settings.customSourceGroups)
        guard let found = metas.first(where: { $0.id == sourceID }) else { return }
        meta = found
        if SourceListHelper.supportsLogin(found) {
            await verifyLoginStatus(sourceID: found.id, showBanner: false)
        }
    }

    private func updateOrganization(isEnabled: Bool?, isPinned: Bool?, groupName: String?) async {
        do {
            try await container.persistence.updateSourceOrganization(
                id: sourceID, isEnabled: isEnabled, isPinned: isPinned, groupName: groupName
            )
            if let all = try? await container.persistence.fetchAllSources() {
                await container.pluginRuntime.registerSources(all)
                let metas = all.map(\.meta)
                allGroupNames = SourceListHelper.allGroupNames(sources: metas, customGroups: settings.customSourceGroups)
                if let found = metas.first(where: { $0.id == sourceID }) {
                    meta = found
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
        if let loginStr = meta.loginURL, let host = URL(string: loginStr)?.host {
            domains.insert(host)
        }
        for domain in domains {
            await container.cookieVault.clearCookies(forDomain: domain)
        }
        await container.sourceAuth.markLoggedOut(sourceID: meta.id, reason: "已退出登录")
        banner.show("已退出登录并清除账号 Cookie", tone: .info)
    }

    private func verifyLoginStatus(sourceID: String, showBanner: Bool) async {
        let status = await container.sourceAuth.checkLogin(sourceID: sourceID, runtime: container.pluginRuntime)
        guard showBanner else { return }
        switch status {
        case .loggedIn(let name):
            banner.show(name.isEmpty ? "登录有效" : "已登录：\(name)", tone: .success)
        case .loggedOut(let reason):
            banner.show(reason ?? "未登录或登录已失效", tone: .info)
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
            dismiss()
        } catch {
            banner.show("移除失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
