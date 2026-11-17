import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - 1. Settings Root View (设置主页，5.6 节：四分组精简列表 + 书源管理入口)
struct SettingsView: View {
    @Binding var path: [Route]

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]

    @State private var settings = AppSettingsStore.shared
    @State private var cacheSizeBytes: Int64 = 0
    @State private var showClearCacheConfirm = false
    @State private var showResetConfirm = false

    private var enabledCount: Int {
        plugins.filter(\.isEnabled).count
    }

    private var healthyCount: Int {
        plugins.filter { $0.isEnabled && $0.isHealthyOrSlow }.count
    }

    private var unavailableCount: Int {
        plugins.filter { $0.healthState == .unavailable }.count
    }

    var body: some View {
        List {
            sourceManagementSection
            playbackSettingsSection
            interfaceSettingsSection
            storageAndNetworkSection
        }
        .listStyle(.insetGrouped)
        .dsAdaptiveBottomDockScroll()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshCacheSize()
        }
        .confirmationDialog("确认清理临时缓存？", isPresented: $showClearCacheConfirm, titleVisibility: .visible) {
            Button("立即清理", role: .destructive) {
                DownloadManager.shared.clearTemporaryCaches()
                ChapterCacheStore.clearAll()
                URLCache.shared.removeAllCachedResponses()
                refreshCacheSize()
                ToastManager.shared.show("临时缓存已清理")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会删除您手动离线下载的章节、已安装的书源或书架收藏记录。")
        }
        .confirmationDialog("确认将所有播放与界面偏好恢复为默认值？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) {
                settings.resetAll()
                ToastManager.shared.show("已恢复默认设置")
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var sourceManagementSection: some View {
        Section {
            NavigationLink(value: Route.pluginManager) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DSColor.primary.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.title3)
                            .foregroundStyle(DSColor.primary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("书源管理")
                            .font(.body.weight(.semibold))
                        HStack(spacing: 6) {
                            Text("已启用 \(enabledCount)/\(plugins.count) 个书源")
                            if !groups.isEmpty {
                                Text("· \(groups.count) 个分组")
                            }
                            if healthyCount > 0 {
                                Text("· \(healthyCount) 可用")
                                    .foregroundStyle(.green)
                            }
                            if unavailableCount > 0 {
                                Text("· \(unavailableCount) 异常")
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("书源")
        } footer: {
            Text("支持导入 .zip 或在线书源合集、点击检测书源可用性及延迟、书源删除与分组排序。")
        }
    }

    private var playbackSettingsSection: some View {
        Section("播放设置") {
            Picker("音频通道模式", selection: $settings.audioChannel) {
                ForEach(AudioChannelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Picker("默认播放倍速", selection: $settings.defaultSpeed) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                    Text(String(format: "%.2gx", rate)).tag(rate)
                }
            }

            Toggle("睡眠定时结束前 30 秒音量渐弱", isOn: $settings.sleepFadeOutEnabled)
            Toggle("启动应用时自动续播上次书籍", isOn: $settings.autoResumeOnLaunch)

            Stepper("自动预缓存后续章数：\(settings.precacheCount) 章", value: $settings.precacheCount, in: 0...5)
            Toggle("按书籍独立记忆音量与倍速", isOn: $settings.rememberBookVolume)

            NavigationLink(value: Route.skipSettings) {
                HStack {
                    Text("默认跳过片头 / 片尾")
                    Spacer()
                    Text("片头 \(settings.defaultSkipIntroSec)s · 片尾 \(settings.defaultSkipOutroSec)s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var interfaceSettingsSection: some View {
        Section("界面与交互") {
            Picker("发现页默认布局", selection: $settings.discoverLayout) {
                ForEach(DiscoverLayoutStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            Picker("书架默认布局", selection: $settings.shelfLayout) {
                ForEach(DiscoverLayoutStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            Picker("书架默认排序", selection: $settings.shelfSort) {
                ForEach(ShelfSortOrder.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }

            Picker("外观模式", selection: $settings.appearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Toggle("触感反馈", isOn: $settings.hapticsEnabled)
        }
    }

    private var storageAndNetworkSection: some View {
        Section("存储与网络") {
            Toggle("仅在 Wi-Fi 下执行离线下载", isOn: $settings.wifiOnlyDownload)

            NavigationLink(value: Route.downloadManager) {
                HStack {
                    Text("已下载内容管理")
                    Spacer()
                    let dlBytes = DownloadManager.shared.totalManualDownloadedBytes()
                    Text(ByteCountFormatter.string(fromByteCount: dlBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                showClearCacheConfirm = true
            } label: {
                HStack {
                    Text("清理临时缓存（图片 / 预缓存 / 章节缓存）")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("恢复默认设置", role: .destructive) {
                showResetConfirm = true
            }
        }
    }

    private func refreshCacheSize() {
        let preBytes = DownloadManager.shared.totalPrecacheAndTempBytes()
        let urlBytes = Int64(URLCache.shared.currentDiskUsage)
        cacheSizeBytes = preBytes + urlBytes
    }
}

// MARK: - 2. Default Skip Settings View (默认跳过片头/片尾子页面)
struct DefaultSkipSettingsView: View {
    @State private var settings = AppSettingsStore.shared

    var body: some View {
        Form {
            Section("全局默认片头 / 片尾跳过时长") {
                Stepper("跳过片头：\(settings.defaultSkipIntroSec) 秒", value: $settings.defaultSkipIntroSec, in: 0...180, step: 5)
                Stepper("跳过片尾：\(settings.defaultSkipOutroSec) 秒", value: $settings.defaultSkipOutroSec, in: 0...180, step: 5)
            }
            Section {
                Text("新加入播放的书籍会默认应用此跳过配置；您也可以在全屏播放器的「跳过片头/片尾」中针对单本书籍单独调整。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("默认跳过片头/片尾")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 6. Group Manage & Sort Sheet (分组管理与分组拖拽排序弹窗)
struct GroupManageAndSortSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]
    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]

    @State private var editMode: EditMode = .active
    @State private var newGroupTitle: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("新建书源分组") {
                    HStack {
                        TextField("输入新分组名称（如：有声主力、相声评书）", text: $newGroupTitle)
                            .textFieldStyle(.plain)
                        Button("添加") {
                            addGroup()
                        }
                        .disabled(newGroupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                Section {
                    if groups.isEmpty {
                        Text("暂无自定义书源分组，可在上方新建分组后将书源归类排序。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groups) { group in
                            let count = plugins.filter { !$0.isPinned && $0.groupID == group.id }.count
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(DSColor.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.body.weight(.medium))
                                    Text("包含 \(count) 个书源")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .onMove(perform: moveGroups)
                        .onDelete(perform: deleteGroups)
                    }
                } header: {
                    Text("拖拽右侧手柄调整分组顺序，左滑可删除分组")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("分组管理与排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addGroup() {
        let trimmed = newGroupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let group = PluginGroup(name: trimmed, order: groups.count)
        modelContext.insert(group)
        try? modelContext.save()
        newGroupTitle = ""
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        var reordered = Array(groups)
        reordered.move(fromOffsets: source, toOffset: destination)
        for (idx, g) in reordered.enumerated() {
            g.order = idx
        }
        try? modelContext.save()
    }

    private func deleteGroups(at offsets: IndexSet) {
        for idx in offsets {
            let group = groups[idx]
            for plugin in plugins where plugin.groupID == group.id {
                plugin.groupID = nil
            }
            modelContext.delete(group)
        }
        try? modelContext.save()
    }
}

// MARK: - 7. Plugin Import Preview Sheet (导入安全预览确认单，4.2.7 节)
struct PluginImportPreviewSheet: View {
    let preview: PluginImportPreview
    let onConfirmInstall: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("书源包信息") {
                    LabeledContent("名称", value: preview.name)
                    LabeledContent("版本", value: "v\(preview.version)")
                    if !preview.author.isEmpty {
                        LabeledContent("作者", value: preview.author)
                    }
                    LabeledContent("包含书源数量", value: "\(preview.sources.count) 个")
                    if !preview.description.isEmpty {
                        Text(preview.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !preview.domains.isEmpty {
                    Section("声明访问的目标站点域名 (\(preview.domains.count))") {
                        ForEach(preview.domains.prefix(15), id: \.self) { domain in
                            HStack {
                                Image(systemName: "network")
                                    .foregroundStyle(.secondary)
                                Text(domain)
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }

                Section("包含的书源列表") {
                    ForEach(preview.sources, id: \.id) { src in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.name)
                                    .font(.subheadline.weight(.medium))
                                Text("\(src.group) · \(src.url)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if src.searchable {
                                Text("可搜索")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(DSColor.primary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(DSColor.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("确认导入书源包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认安装 (\(preview.sources.count))") {
                        onConfirmInstall()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 8. Plugin Detail & Check Sheet (单源详情、实时测速、内嵌网页登录、自定义配置与删除面板)
struct PluginDetailAndCheckSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var plugin: PluginRecord
    let groups: [PluginGroup]
    let isChecking: Bool
    let onTriggerCheck: () -> Void
    let onOpenWebAuth: () -> Void
    let onDelete: () -> Void

    @State private var configItems: [SourceConfigItem] = []
    @State private var configValues: [String: String] = [:]
    @State private var nestedAuthSession: WebAuthSessionRequest?
    @State private var loginStatusNote: String = ""

    var body: some View {
        NavigationStack {
            Form {
                healthCheckSection
                // 内置解析：仅喜马拉雅类书源显示；未导入脚本时是纯中性空位（不产生任何提示）
                if BuiltinParserSection.isSupportedSource(plugin) {
                    BuiltinParserSection(plugin: plugin)
                }
                statusAndGroupSection
                if !configItems.isEmpty {
                    customConfigSection
                }
                metadataSection
                deleteSection
            }
            .navigationTitle(plugin.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .sheet(item: $nestedAuthSession) { session in
                WebAuthSheet(session: session)
            }
            .task {
                await loadConfigMetadata()
                await refreshLoginState()
            }
        }
    }

    private var healthCheckSection: some View {
        Section("可用性与延迟检测") {
            HStack {
                Label("当前状态", systemImage: "waveform.path.ecg")
                Spacer()
                Text(plugin.healthState.displayTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
            }

            HStack {
                Label("网络响应延迟", systemImage: "speedometer")
                Spacer()
                Text(plugin.lastLatencyMs > 0 ? "\(plugin.lastLatencyMs) ms" : "尚未检测")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if !plugin.lastCheckMessage.isEmpty {
                LabeledContent("检测诊断说明", value: plugin.lastCheckMessage)
            }

            if let checkedAt = plugin.lastCheckedAt {
                LabeledContent("上次检测时间", value: checkedAt.formatted(date: .abbreviated, time: .standard))
            }

            Button(action: onTriggerCheck) {
                HStack {
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在检测该书源可用性及延迟…")
                    } else {
                        Image(systemName: "bolt.heart.fill")
                        Text("立即检测可用性及延迟")
                    }
                }
            }
            .disabled(isChecking)
        }
    }

    private var statusAndGroupSection: some View {
        Section("书源状态与账号登录") {
            Toggle("启用该书源", isOn: $plugin.isEnabled)
            Toggle("置顶该书源", isOn: $plugin.isPinned)

            Picker("所属分组", selection: $plugin.groupID) {
                Text("未分组").tag(String?.none)
                ForEach(groups) { g in
                    Text(g.name).tag(Optional(g.id))
                }
            }

            HStack {
                Label("账号登录状态", systemImage: plugin.loggedIn ? "checkmark.shield.fill" : "key.fill")
                    .foregroundStyle(plugin.loggedIn ? .green : .primary)
                Spacer()
                Text(
                    loginStatusNote.isEmpty
                        ? (plugin.loggedIn
                            ? (CookieSync.verifiedNickname(for: plugin.id).map { "已登录 (\($0))" } ?? "已登录")
                            : "未登录")
                        : loginStatusNote
                )
                .font(.caption)
                .foregroundStyle(plugin.loggedIn ? .green : .secondary)
            }

            Button {
                presentInlineWebAuth()
            } label: {
                Label(
                    plugin.loggedIn ? "重新打开网页登录 / 刷新验证" : "打开网页登录 / 验证码验证",
                    systemImage: "person.badge.key"
                )
            }

            if plugin.loggedIn {
                Button(role: .destructive) {
                    Task {
                        await CookieSync.clearCookies(
                            for: [plugin.loginURL, plugin.siteURL],
                            sourceID: plugin.id
                        )
                        plugin.loggedIn = false
                        loginStatusNote = "未登录"
                        try? modelContext.save()
                        ToastManager.shared.show("已退出「\(plugin.name)」账号登录")
                    }
                } label: {
                    Label("退出登录 / 清除该源登录凭证", systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }
    }

    private func presentInlineWebAuth() {
        let targetURL = plugin.loginURL.isEmpty ? plugin.siteURL : plugin.loginURL
        guard !targetURL.isEmpty else {
            onOpenWebAuth()
            return
        }
        nestedAuthSession = WebAuthSessionRequest(
            sourceID: plugin.id,
            title: "登录/验证 · \(plugin.name)",
            initialURL: targetURL,
            expectedCookieName: nil,
            onCompleted: {
                let isLogged = CookieSync.isSourceLoggedIn(plugin.id)
                plugin.loggedIn = isLogged
                if isLogged && plugin.healthState == .needAuth {
                    plugin.lastCheckStatus = SourceHealthState.healthy.rawValue
                    plugin.lastCheckMessage = "已完成网页登录"
                }
                try? modelContext.save()
                Task {
                    await refreshLoginState()
                    if isLogged {
                        onTriggerCheck()
                    }
                }
            }
        )
    }

    private func refreshLoginState() async {
        let res = await PluginRuntime.shared.verifyLoginStatus(sourceID: plugin.id)
        switch res {
        case .verified(let nick):
            loginStatusNote = "已登录 (\(nick))"
            if !plugin.loggedIn {
                plugin.loggedIn = true
                try? modelContext.save()
            }
        case .notLoggedIn:
            loginStatusNote = "未登录"
            if plugin.loggedIn {
                plugin.loggedIn = false
                try? modelContext.save()
            }
        case .noCheckMethod:
            if let savedNick = CookieSync.verifiedNickname(for: plugin.id) {
                loginStatusNote = "已登录 (\(savedNick))"
                if !plugin.loggedIn {
                    plugin.loggedIn = true
                    try? modelContext.save()
                }
            } else {
                loginStatusNote = "未登录"
                if plugin.loggedIn {
                    plugin.loggedIn = false
                    try? modelContext.save()
                }
            }
        }
    }

    private var customConfigSection: some View {
        Section("书源专属配置项") {
            ForEach(configItems) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                    TextField(item.defaultValue, text: Binding(
                        get: { configValues[item.key] ?? item.defaultValue },
                        set: { newVal in
                            configValues[item.key] = newVal
                            UserDefaults.standard.set(newVal, forKey: "plugin_pref_\(plugin.id).\(item.key)")
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var metadataSection: some View {
        Section("书源元数据") {
            LabeledContent("书源名称", value: plugin.name)
            LabeledContent("书源 ID", value: plugin.id)
            LabeledContent("所属插件包", value: plugin.packageID)
            LabeledContent("版本", value: "v\(plugin.version)")
            if !plugin.siteURL.isEmpty {
                LabeledContent("站点地址", value: plugin.siteURL)
            }
            LabeledContent("支持搜索", value: plugin.searchable ? "是" : "否")
            LabeledContent("支持发现分类", value: plugin.discoverable ? "是" : "否")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive, action: onDelete) {
                Label("删除该书源", systemImage: "trash")
            }
        }
    }

    private func loadConfigMetadata() async {
        if let meta = await PluginRuntime.shared.sourceMeta(for: plugin.id) {
            configItems = meta.config
            var loaded: [String: String] = [:]
            for item in meta.config {
                let stored = UserDefaults.standard.string(forKey: "plugin_pref_\(plugin.id).\(item.key)")
                loaded[item.key] = stored ?? item.defaultValue
            }
            configValues = loaded
        }
    }

    private var statusColor: Color {
        switch plugin.healthState {
        case .healthy: return .green
        case .slow, .needAuth: return .orange
        case .unavailable: return .red
        case .untested: return .secondary
        }
    }
}
