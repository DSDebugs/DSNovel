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

// MARK: - 3. Source Filter & Sheet Enums (书源筛选与弹窗路由枚举)
enum SourceFilterMode: String, CaseIterable, Identifiable {
    case all = "全部"
    case enabled = "已启用"
    case available = "可用"
    case unavailable = "不可用"
    case needAuth = "需验证"

    var id: String { rawValue }
}

enum PluginManagerSheet: Identifiable {
    case importPreview(PluginImportPreview)
    case detail(PluginRecord)
    case webAuth(WebAuthSessionRequest)
    case groupSort

    var id: String {
        switch self {
        case .importPreview(let p): return "preview_\(p.id)"
        case .detail(let r): return "detail_\(r.id)"
        case .webAuth(let s): return "auth_\(s.id.uuidString)"
        case .groupSort: return "group_sort"
        }
    }
}

enum BatchDeleteMode: String, Identifiable {
    case unavailable
    case disabled
    case all

    var id: String { rawValue }

    var dialogTitle: String {
        switch self {
        case .unavailable: return "确认删除所有检测为「不可用」的书源吗？"
        case .disabled: return "确认删除所有已停用的书源吗？"
        case .all: return "确认清空全部已安装的书源吗？"
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .unavailable: return "删除所有不可用书源"
        case .disabled: return "删除所有已停用书源"
        case .all: return "清空全部书源"
        }
    }
}

// MARK: - 4. Plugin Manager View (书源管理主页：可用性与延迟检测、删除、分组与书源排序)
struct PluginManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]

    @State private var editMode: EditMode = .inactive
    @State private var filterKeyword: String = ""
    @State private var selectedFilter: SourceFilterMode = .all

    // 统一弹窗与导入状态
    @State private var activeSheet: PluginManagerSheet?
    @State private var showFileImporter = false
    @State private var showURLImportAlert = false
    @State private var importURLString: String = PluginRuntime.defaultOnlineSourcesURL
    @State private var isImporting = false
    @State private var errorAlertMessage: String?

    // 分组新建与重命名弹窗状态
    @State private var showNewGroupAlert = false
    @State private var newGroupName: String = ""
    @State private var renamingGroup: PluginGroup?
    @State private var renameGroupText: String = ""

    // 书源可用性及延迟检测状态
    @State private var checkingSourceIDs: Set<String> = []
    @State private var isBatchChecking = false
    @State private var batchCompletedCount: Int = 0
    @State private var batchTotalCount: Int = 0
    @State private var batchCheckTask: Task<Void, Never>?

    // 删除确认状态
    @State private var pendingDeletePlugin: PluginRecord?
    @State private var activeBatchDeleteMode: BatchDeleteMode?

    private var enabledCount: Int {
        plugins.filter(\.isEnabled).count
    }

    private var healthyCount: Int {
        plugins.filter(\.isHealthyOrSlow).count
    }

    private var unavailableCount: Int {
        plugins.filter { $0.healthState == .unavailable }.count
    }

    private var needAuthCount: Int {
        plugins.filter { $0.healthState == .needAuth }.count
    }

    private var averageLatencyMs: Int? {
        let valid = plugins.filter { $0.isHealthyOrSlow && $0.lastLatencyMs > 0 }.map(\.lastLatencyMs)
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / valid.count
    }

    private var filteredPlugins: [PluginRecord] {
        let kw = filterKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return plugins.filter { plugin in
            let matchesKeyword: Bool = {
                guard !kw.isEmpty else { return true }
                return plugin.name.localizedCaseInsensitiveContains(kw)
                    || plugin.id.localizedCaseInsensitiveContains(kw)
                    || plugin.author.localizedCaseInsensitiveContains(kw)
                    || plugin.summary.localizedCaseInsensitiveContains(kw)
            }()
            guard matchesKeyword else { return false }

            switch selectedFilter {
            case .all: return true
            case .enabled: return plugin.isEnabled
            case .available: return plugin.isHealthyOrSlow
            case .unavailable: return plugin.healthState == .unavailable
            case .needAuth: return plugin.healthState == .needAuth
            }
        }
    }

    private var pinnedPlugins: [PluginRecord] {
        filteredPlugins.filter(\.isPinned).sorted { $0.order < $1.order }
    }

    private var ungroupedPlugins: [PluginRecord] {
        filteredPlugins
            .filter { !$0.isPinned && ($0.groupID == nil || $0.groupID?.isEmpty == true) }
            .sorted { $0.order < $1.order }
    }

    var body: some View {
        withDialogsAndSheets(on: baseManagerView)
    }

    private var baseManagerView: some View {
        VStack(spacing: 0) {
            if !plugins.isEmpty {
                topDashboardAndFilterBar
                Divider()
            }
            mainContentArea
        }
        .background(DSColor.contentBackground)
        .navigationTitle("书源管理")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !plugins.isEmpty {
                    toolbarSortAndBatchMenu
                }
                toolbarImportMenu
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType.zip, UTType.archive, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onDisappear {
            batchCheckTask?.cancel()
        }
    }

    @ViewBuilder
    private var mainContentArea: some View {
        if plugins.isEmpty {
            emptyPluginState
        } else if filteredPlugins.isEmpty {
            ContentUnavailableView(
                "无匹配书源",
                systemImage: "magnifyingglass",
                description: Text("没有找到符合「\(selectedFilter.rawValue)」或搜索词的书源")
            )
        } else {
            pluginGroupedList
        }
    }

    private func withDialogsAndSheets<V: View>(on content: V) -> some View {
        content
            .alert("从 URL 导入书源包", isPresented: $showURLImportAlert) {
                TextField("https://example.com/sources.zip", text: $importURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("下载预览") {
                    Task { await downloadAndPreparePreview(from: importURLString) }
                }
            } message: {
                Text("支持输入 .zip 书源插件包直链地址，解析后将展示书源列表供确认安装。")
            }
            .alert("新建书源分组", isPresented: $showNewGroupAlert) {
                TextField("分组名称（如：有声主力、评书相声）", text: $newGroupName)
                Button("取消", role: .cancel) {}
                Button("创建") { createGroup() }
            }
            .alert("重命名书源分组", isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            )) {
                TextField("新分组名称", text: $renameGroupText)
                Button("取消", role: .cancel) { renamingGroup = nil }
                Button("保存") { commitRenameGroup() }
            }
            .alert("删除书源确认", isPresented: Binding(
                get: { pendingDeletePlugin != nil },
                set: { if !$0 { pendingDeletePlugin = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDeletePlugin = nil }
                Button("删除", role: .destructive) {
                    if let target = pendingDeletePlugin {
                        deleteSinglePlugin(target)
                    }
                    pendingDeletePlugin = nil
                }
            } message: {
                Text("确认删除书源「\(pendingDeletePlugin?.name ?? "")」及其本地缓存吗？")
            }
            .alert("书源提示", isPresented: Binding(
                get: { errorAlertMessage != nil },
                set: { if !$0 { errorAlertMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorAlertMessage = nil }
            } message: {
                Text(errorAlertMessage ?? "")
            }
            .confirmationDialog(
                activeBatchDeleteMode?.dialogTitle ?? "确认操作",
                isPresented: Binding(
                    get: { activeBatchDeleteMode != nil },
                    set: { if !$0 { activeBatchDeleteMode = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let mode = activeBatchDeleteMode {
                    Button(mode.confirmButtonTitle, role: .destructive) {
                        executeBatchDelete(mode)
                        activeBatchDeleteMode = nil
                    }
                }
                Button("取消", role: .cancel) { activeBatchDeleteMode = nil }
            }
            .sheet(item: $activeSheet) { sheet in
                sheetDestinationView(for: sheet)
            }
    }

    @ViewBuilder
    private func sheetDestinationView(for sheet: PluginManagerSheet) -> some View {
        switch sheet {
        case .importPreview(let preview):
            PluginImportPreviewSheet(preview: preview) {
                installConfirmedPreview(preview)
            }
        case .detail(let plugin):
            PluginDetailAndCheckSheet(
                plugin: plugin,
                groups: groups,
                isChecking: checkingSourceIDs.contains(plugin.id),
                onTriggerCheck: {
                    Task { await checkSinglePlugin(plugin) }
                },
                onOpenWebAuth: {
                    openWebAuth(for: plugin)
                },
                onDelete: {
                    activeSheet = nil
                    deleteSinglePlugin(plugin)
                }
            )
        case .webAuth(let session):
            WebAuthSheet(session: session)
        case .groupSort:
            GroupManageAndSortSheet()
        }
    }

    // MARK: - 工具栏菜单拆分
    private var toolbarSortAndBatchMenu: some View {
        Menu {
            Section("书源智能排序") {
                Button {
                    sortPluginsByLatency()
                } label: {
                    Label("按响应延迟排序（最快优先）", systemImage: "bolt.horizontal.fill")
                }

                Button {
                    sortPluginsByAvailability()
                } label: {
                    Label("按可用状态排序（可用优先）", systemImage: "checkmark.seal.fill")
                }

                Button {
                    sortPluginsByName()
                } label: {
                    Label("按书源名称排序", systemImage: "textformat.abc")
                }
            }

            Section("手动排序与分组管理") {
                Button {
                    withAnimation {
                        editMode = (editMode == .active) ? .inactive : .active
                    }
                } label: {
                    Label(
                        editMode == .active ? "完成手动排序" : "开启手动拖拽排序",
                        systemImage: editMode == .active ? "checkmark.circle.fill" : "arrow.up.arrow.down"
                    )
                }

                Button {
                    activeSheet = .groupSort
                } label: {
                    Label("分组管理与分组排序…", systemImage: "folder.badge.gearshape")
                }

                Button {
                    newGroupName = ""
                    showNewGroupAlert = true
                } label: {
                    Label("新建书源分组", systemImage: "folder.badge.plus")
                }
            }

            Section("批量启用与书源删除") {
                Button {
                    setAllPluginsEnabled(true)
                } label: {
                    Label("全部启用", systemImage: "checkmark.circle")
                }

                Button {
                    setAllPluginsEnabled(false)
                } label: {
                    Label("全部停用", systemImage: "pause.circle")
                }

                if unavailableCount > 0 {
                    Button {
                        disableUnavailablePlugins()
                    } label: {
                        Label("一键停用不可用书源 (\(unavailableCount))", systemImage: "slash.circle")
                    }

                    Button(role: .destructive) {
                        activeBatchDeleteMode = .unavailable
                    } label: {
                        Label("删除所有不可用书源 (\(unavailableCount))", systemImage: "trash")
                    }
                }

                Button(role: .destructive) {
                    activeBatchDeleteMode = .disabled
                } label: {
                    Label("删除所有已停用书源", systemImage: "trash.slash")
                }

                Button(role: .destructive) {
                    activeBatchDeleteMode = .all
                } label: {
                    Label("清空全部书源", systemImage: "xmark.bin.fill")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
        .accessibilityLabel("书源排序与批量管理")
    }

    private var toolbarImportMenu: some View {
        Menu {
            Button {
                showFileImporter = true
            } label: {
                Label("从文件导入 (.zip)", systemImage: "doc.zipper")
            }

            Button {
                importURLString = PluginRuntime.defaultOnlineSourcesURL
                showURLImportAlert = true
            } label: {
                Label("从 URL 在线导入", systemImage: "link.badge.plus")
            }

            Button {
                Task {
                    await downloadAndPreparePreview(from: PluginRuntime.defaultOnlineSourcesURL)
                }
            } label: {
                Label("一键导入推荐书源合集 (v5.6)", systemImage: "icloud.and.arrow.down")
            }

            Divider()

            Button {
                newGroupName = ""
                showNewGroupAlert = true
            } label: {
                Label("新建书源分组", systemImage: "folder.badge.plus")
            }
        } label: {
            if isImporting {
                ProgressView()
            } else {
                Image(systemName: "plus")
            }
        }
        .accessibilityLabel("导入书源")
    }

    // MARK: - 顶部书源检测看板 + 搜索过滤 + 状态筛选胶囊条
    private var topDashboardAndFilterBar: some View {
        VStack(spacing: 10) {
            healthDashboardCard
            searchAndSortInputRow
            filterCapsuleScrollRow
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, 10)
    }

    private var healthDashboardCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("共 \(plugins.count) 源")
                        .font(.subheadline.weight(.semibold))
                    Text("启用 \(enabledCount)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DSColor.primary.opacity(0.12), in: Capsule())
                        .foregroundStyle(DSColor.primary)

                    if healthyCount > 0 {
                        Text("可用 \(healthyCount)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14), in: Capsule())
                            .foregroundStyle(.green)
                    }

                    if unavailableCount > 0 {
                        Text("不可用 \(unavailableCount)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.14), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }

                if isBatchChecking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在检测可用性及延迟 \(batchCompletedCount)/\(batchTotalCount)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let avg = averageLatencyMs {
                    Text("平均响应延迟 \(avg)ms · 点击任意书源右侧按钮可单源测速")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("点击书源右侧「检测」或「一键检测」测试可用性及延迟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
            healthCheckActionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DSColor.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var healthCheckActionButtons: some View {
        if isBatchChecking {
            Button {
                stopBatchHealthCheck()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.caption2)
                    Text("停止")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.14), in: Capsule())
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Button {
                    startBatchHealthCheck(onlyEnabled: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.heart.fill")
                            .font(.caption)
                        Text("一键检测")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(DSColor.primary, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        startBatchHealthCheck(onlyEnabled: true)
                    } label: {
                        Label("检测已启用书源 (\(enabledCount))", systemImage: "bolt.shield.fill")
                    }

                    Button {
                        startBatchHealthCheck(onlyEnabled: false)
                    } label: {
                        Label("检测全部书源 (\(plugins.count))", systemImage: "network")
                    }

                    Divider()

                    Button {
                        sortPluginsByLatency()
                    } label: {
                        Label("按延迟从快到慢排序", systemImage: "bolt.horizontal")
                    }

                    if unavailableCount > 0 {
                        Button {
                            disableUnavailablePlugins()
                        } label: {
                            Label("一键停用不可用书源 (\(unavailableCount))", systemImage: "slash.circle")
                        }

                        Button(role: .destructive) {
                            activeBatchDeleteMode = .unavailable
                        } label: {
                            Label("一键删除不可用书源 (\(unavailableCount))", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DSColor.primary)
                }
                .accessibilityLabel("更多检测选项")
            }
        }
    }

    private var searchAndSortInputRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("搜索书源名称、ID 或说明…", text: $filterKeyword)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !filterKeyword.isEmpty {
                    Button {
                        filterKeyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(DSColor.cardSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Button {
                withAnimation {
                    editMode = (editMode == .active) ? .inactive : .active
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                        .font(.caption.weight(.semibold))
                    Text(editMode == .active ? "完成排序" : "手动排序")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    editMode == .active ? DSColor.primary : DSColor.cardSurface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .foregroundStyle(editMode == .active ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private var filterCapsuleScrollRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SourceFilterMode.allCases) { mode in
                    let isSelected = (selectedFilter == mode)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedFilter = mode
                        }
                    } label: {
                        Text(filterBadgeTitle(for: mode))
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? DSColor.primary : DSColor.cardSurface,
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    activeSheet = .groupSort
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.gearshape")
                        Text("分组排序 (\(groups.count))")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(DSColor.cardSurface, in: Capsule())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func filterBadgeTitle(for mode: SourceFilterMode) -> String {
        switch mode {
        case .all: return "全部 (\(plugins.count))"
        case .enabled: return "已启用 (\(enabledCount))"
        case .available: return "可用 (\(healthyCount))"
        case .unavailable: return "不可用 (\(unavailableCount))"
        case .needAuth: return "需验证 (\(needAuthCount))"
        }
    }

    // MARK: - 无书源空状态
    private var emptyPluginState: some View {
        ContentUnavailableView {
            Label("尚未安装任何书源", systemImage: "puzzlepiece.extension")
        } description: {
            Text("DSNovel 采用纯空壳插件架构，不包含内置书源。您可以从本地导入 .zip 书源包，或一键下载在线书源合集。")
        } actions: {
            VStack(spacing: 10) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入 (.zip)", systemImage: "doc.zipper")
                        .frame(maxWidth: 230)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await downloadAndPreparePreview(from: PluginRuntime.defaultOnlineSourcesURL)
                    }
                } label: {
                    Label("一键导入推荐书源合集 (v5.6)", systemImage: "icloud.and.arrow.down")
                        .frame(maxWidth: 230)
                }
                .buttonStyle(.bordered)

                Button {
                    importURLString = PluginRuntime.defaultOnlineSourcesURL
                    showURLImportAlert = true
                } label: {
                    Label("输入自定义 URL 导入", systemImage: "link")
                        .font(.footnote)
                }
            }
        }
    }

    // MARK: - 分组与书源列表（拆分子视图以确保类型推导极速完成）
    private var pluginGroupedList: some View {
        List {
            if !pinnedPlugins.isEmpty {
                pinnedSectionView
            }
            ForEach(groups) { group in
                customGroupSectionView(for: group)
            }
            if !ungroupedPlugins.isEmpty {
                ungroupedSectionView
            }
        }
        .listStyle(.insetGrouped)
    }

    private var pinnedSectionView: some View {
        Section {
            ForEach(pinnedPlugins) { plugin in
                pluginRow(for: plugin, inSectionList: pinnedPlugins)
            }
            .onMove { indices, newOffset in
                movePlugins(in: pinnedPlugins, from: indices, to: newOffset)
            }
        } header: {
            HStack {
                Label("已置顶 (\(pinnedPlugins.count))", systemImage: "pin.fill")
                Spacer()
                Button("检测本组") {
                    startHealthCheck(for: pinnedPlugins)
                }
                .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func customGroupSectionView(for group: PluginGroup) -> some View {
        let groupItems = filteredPlugins
            .filter { !$0.isPinned && $0.groupID == group.id }
            .sorted { $0.order < $1.order }

        if !groupItems.isEmpty || (filterKeyword.isEmpty && selectedFilter == .all) {
            Section {
                if !group.isCollapsed {
                    if groupItems.isEmpty {
                        Text("该分组暂无书源，可在书源菜单中选择「移动到分组」")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groupItems) { plugin in
                            pluginRow(for: plugin, inSectionList: groupItems)
                        }
                        .onMove { indices, newOffset in
                            movePlugins(in: groupItems, from: indices, to: newOffset)
                        }
                    }
                }
            } header: {
                groupSectionHeader(for: group, groupItems: groupItems)
            }
        }
    }

    private func groupSectionHeader(for group: PluginGroup, groupItems: [PluginRecord]) -> some View {
        HStack(spacing: 8) {
            Button {
                group.isCollapsed.toggle()
                try? modelContext.save()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                    Text("\(group.name) (\(groupItems.count))")
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if !groupItems.isEmpty {
                Button("测速") {
                    startHealthCheck(for: groupItems)
                }
                .font(.caption2)
            }

            Menu {
                Button {
                    startHealthCheck(for: groupItems)
                } label: {
                    Label("检测本组书源可用性及延迟", systemImage: "bolt.heart")
                }

                Button {
                    sortSectionByLatency(groupItems)
                } label: {
                    Label("本组按延迟从快到慢排序", systemImage: "bolt.horizontal")
                }

                Divider()

                Button {
                    moveGroupUp(group)
                } label: {
                    Label("分组上移", systemImage: "arrow.up")
                }

                Button {
                    moveGroupDown(group)
                } label: {
                    Label("分组下移", systemImage: "arrow.down")
                }

                Button {
                    renameGroupText = group.name
                    renamingGroup = group
                } label: {
                    Label("重命名分组", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    deleteGroup(group)
                } label: {
                    Label("删除分组（书源保留至未分组）", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
        }
    }

    private var ungroupedSectionView: some View {
        Section {
            ForEach(ungroupedPlugins) { plugin in
                pluginRow(for: plugin, inSectionList: ungroupedPlugins)
            }
            .onMove { indices, newOffset in
                movePlugins(in: ungroupedPlugins, from: indices, to: newOffset)
            }
        } header: {
            HStack {
                Text(groups.isEmpty && pinnedPlugins.isEmpty ? "全部书源 (\(ungroupedPlugins.count))" : "未分组 (\(ungroupedPlugins.count))")
                Spacer()
                Button("按延迟排序") {
                    sortSectionByLatency(ungroupedPlugins)
                }
                .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func pluginRow(for plugin: PluginRecord, inSectionList sectionList: [PluginRecord]) -> some View {
        let idx = sectionList.firstIndex(where: { $0.id == plugin.id }) ?? 0

        PluginRowView(
            plugin: plugin,
            groups: groups,
            isChecking: checkingSourceIDs.contains(plugin.id),
            canMoveUp: idx > 0,
            canMoveDown: idx < sectionList.count - 1,
            onCheckLatency: {
                Task { await checkSinglePlugin(plugin) }
            },
            onInspectDetail: {
                activeSheet = .detail(plugin)
            },
            onOpenWebAuth: {
                openWebAuth(for: plugin)
            },
            onMoveUp: {
                moveSinglePlugin(in: sectionList, from: idx, to: idx - 1)
            },
            onMoveDown: {
                moveSinglePlugin(in: sectionList, from: idx, to: idx + 1)
            },
            onDelete: {
                pendingDeletePlugin = plugin
            }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteSinglePlugin(plugin)
            } label: {
                Label("删除", systemImage: "trash")
            }

            Button {
                plugin.isEnabled.toggle()
                try? modelContext.save()
            } label: {
                Label(plugin.isEnabled ? "停用" : "启用", systemImage: plugin.isEnabled ? "pause.circle" : "play.circle")
            }
            .tint(plugin.isEnabled ? .orange : .green)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                plugin.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(plugin.isPinned ? "取消置顶" : "置顶", systemImage: plugin.isPinned ? "pin.slash" : "pin.fill")
            }
            .tint(.orange)

            Button {
                Task { await checkSinglePlugin(plugin) }
            } label: {
                Label("检测", systemImage: "bolt.heart")
            }
            .tint(.blue)
        }
    }

    private func openWebAuth(for plugin: PluginRecord) {
        let targetURL = plugin.loginURL.isEmpty ? plugin.siteURL : plugin.loginURL
        let session = WebAuthSessionRequest(
            sourceID: plugin.id,
            title: "登录/验证 · \(plugin.name)",
            initialURL: targetURL.isEmpty ? "https://m.ximalaya.com" : targetURL,
            expectedCookieName: nil,
            onCompleted: {
                plugin.loggedIn = true
                Task { await checkSinglePlugin(plugin) }
            }
        )
        activeSheet = .webAuth(session)
    }

    // MARK: - 单源与批量可用性及延迟检测逻辑（严守 Sendable 跨线程安全）
    private func checkSinglePlugin(_ plugin: PluginRecord) async {
        let sourceID = plugin.id
        guard !checkingSourceIDs.contains(sourceID) else { return }
        checkingSourceIDs.insert(sourceID)

        let res = await PluginRuntime.shared.checkSourceHealth(sourceID: sourceID)

        plugin.lastCheckStatus = res.state.rawValue
        plugin.lastLatencyMs = res.latencyMs
        plugin.lastCheckMessage = res.message
        plugin.lastCheckedAt = res.checkedAt
        try? modelContext.save()

        checkingSourceIDs.remove(sourceID)
    }

    private func startBatchHealthCheck(onlyEnabled: Bool) {
        let targets = onlyEnabled ? plugins.filter(\.isEnabled) : Array(plugins)
        startHealthCheck(for: targets)
    }

    private func startHealthCheck(for targetPlugins: [PluginRecord]) {
        let targetIDs: [String] = targetPlugins.map(\.id)
        guard !targetIDs.isEmpty else { return }
        batchCheckTask?.cancel()

        isBatchChecking = true
        batchCompletedCount = 0
        batchTotalCount = targetIDs.count

        batchCheckTask = Task {
            let maxConcurrency = 5
            var nextIndex = 0

            await withTaskGroup(of: (String, SourceHealthCheckResult).self) { group in
                let initialCount = min(maxConcurrency, targetIDs.count)
                while nextIndex < initialCount {
                    let sid = targetIDs[nextIndex]
                    nextIndex += 1
                    _ = checkingSourceIDs.insert(sid)
                    group.addTask {
                        let res = await PluginRuntime.shared.checkSourceHealth(sourceID: sid)
                        return (sid, res)
                    }
                }

                while let (sid, res) = await group.next() {
                    if Task.isCancelled { break }
                    if let record = plugins.first(where: { $0.id == sid }) {
                        record.lastCheckStatus = res.state.rawValue
                        record.lastLatencyMs = res.latencyMs
                        record.lastCheckMessage = res.message
                        record.lastCheckedAt = res.checkedAt
                        try? modelContext.save()
                    }
                    checkingSourceIDs.remove(sid)
                    batchCompletedCount += 1

                    if nextIndex < targetIDs.count && !Task.isCancelled {
                        let nextSid = targetIDs[nextIndex]
                        nextIndex += 1
                        _ = checkingSourceIDs.insert(nextSid)
                        group.addTask {
                            let res = await PluginRuntime.shared.checkSourceHealth(sourceID: nextSid)
                            return (nextSid, res)
                        }
                    }
                }
            }

            let checkedSet = Set(targetIDs)
            let checkedRecords = plugins.filter { checkedSet.contains($0.id) }
            let okCount = checkedRecords.filter(\.isHealthyOrSlow).count
            let failCount = checkedRecords.filter { $0.healthState == .unavailable }.count
            checkingSourceIDs.removeAll()
            isBatchChecking = false
            ToastManager.shared.show("书源检测完成：\(okCount) 可用，\(failCount) 不可用")
        }
    }

    private func stopBatchHealthCheck() {
        batchCheckTask?.cancel()
        batchCheckTask = nil
        checkingSourceIDs.removeAll()
        isBatchChecking = false
        ToastManager.shared.show("已停止批量检测（完成 \(batchCompletedCount)/\(batchTotalCount)）")
    }

    // MARK: - 书源与分组排序逻辑
    private func movePlugins(in sectionPlugins: [PluginRecord], from source: IndexSet, to destination: Int) {
        var reordered = sectionPlugins
        reordered.move(fromOffsets: source, toOffset: destination)
        let existingOrders = sectionPlugins.map(\.order).sorted()
        for (idx, item) in reordered.enumerated() {
            item.order = idx < existingOrders.count ? existingOrders[idx] : idx
        }
        normalizeGlobalOrder()
    }

    private func moveSinglePlugin(in sectionPlugins: [PluginRecord], from sourceIndex: Int, to targetIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < sectionPlugins.count,
              targetIndex >= 0, targetIndex < sectionPlugins.count else { return }
        var reordered = sectionPlugins
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: targetIndex)
        let existingOrders = sectionPlugins.map(\.order).sorted()
        for (idx, item) in reordered.enumerated() {
            item.order = idx < existingOrders.count ? existingOrders[idx] : idx
        }
        normalizeGlobalOrder()
    }

    private func sortSectionByLatency(_ sectionPlugins: [PluginRecord]) {
        let sorted = sectionPlugins.sorted { latencySortScore($0) < latencySortScore($1) }
        let existingOrders = sectionPlugins.map(\.order).sorted()
        for (idx, item) in sorted.enumerated() {
            item.order = idx < existingOrders.count ? existingOrders[idx] : idx
        }
        normalizeGlobalOrder()
        ToastManager.shared.show("已按延迟从快到慢排序当前分组")
    }

    private func sortPluginsByLatency() {
        let sorted = plugins.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return latencySortScore(a) < latencySortScore(b)
        }
        for (idx, item) in sorted.enumerated() {
            item.order = idx
        }
        try? modelContext.save()
        ToastManager.shared.show("已按响应延迟（最快优先）排序全部书源")
    }

    private func sortPluginsByAvailability() {
        let sorted = plugins.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            if a.isEnabled != b.isEnabled { return a.isEnabled && !b.isEnabled }
            return availabilityRank(a.healthState) < availabilityRank(b.healthState)
        }
        for (idx, item) in sorted.enumerated() {
            item.order = idx
        }
        try? modelContext.save()
        ToastManager.shared.show("已按可用状态（可用优先）排序全部书源")
    }

    private func sortPluginsByName() {
        let sorted = plugins.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for (idx, item) in sorted.enumerated() {
            item.order = idx
        }
        try? modelContext.save()
        ToastManager.shared.show("已按书源名称排序")
    }

    private func latencySortScore(_ plugin: PluginRecord) -> Int {
        switch plugin.healthState {
        case .healthy, .slow:
            return plugin.lastLatencyMs > 0 ? plugin.lastLatencyMs : 5_000
        case .needAuth:
            return 50_000 + (plugin.lastLatencyMs > 0 ? plugin.lastLatencyMs : 0)
        case .untested:
            return 100_000 + plugin.order
        case .unavailable:
            return 500_000 + plugin.order
        }
    }

    private func availabilityRank(_ state: SourceHealthState) -> Int {
        switch state {
        case .healthy: return 0
        case .slow: return 1
        case .needAuth: return 2
        case .untested: return 3
        case .unavailable: return 4
        }
    }

    private func normalizeGlobalOrder() {
        let allSorted = plugins.sorted { $0.order < $1.order }
        for (idx, item) in allSorted.enumerated() {
            item.order = idx
        }
        try? modelContext.save()
    }

    // MARK: - 分组移动与删除
    private func moveGroupUp(_ group: PluginGroup) {
        let sorted = groups.sorted { $0.order < $1.order }
        guard let idx = sorted.firstIndex(where: { $0.id == group.id }), idx > 0 else { return }
        var copy = sorted
        copy.swapAt(idx, idx - 1)
        for (i, g) in copy.enumerated() {
            g.order = i
        }
        try? modelContext.save()
    }

    private func moveGroupDown(_ group: PluginGroup) {
        let sorted = groups.sorted { $0.order < $1.order }
        guard let idx = sorted.firstIndex(where: { $0.id == group.id }), idx < sorted.count - 1 else { return }
        var copy = sorted
        copy.swapAt(idx, idx + 1)
        for (i, g) in copy.enumerated() {
            g.order = i
        }
        try? modelContext.save()
    }

    private func createGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let group = PluginGroup(name: trimmed, order: groups.count)
        modelContext.insert(group)
        try? modelContext.save()
    }

    private func commitRenameGroup() {
        if let group = renamingGroup {
            let trimmed = renameGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                group.name = trimmed
                try? modelContext.save()
            }
        }
        renamingGroup = nil
    }

    private func deleteGroup(_ group: PluginGroup) {
        for plugin in plugins where plugin.groupID == group.id {
            plugin.groupID = nil
        }
        modelContext.delete(group)
        try? modelContext.save()
    }

    // MARK: - 单源删除与批量清理
    private func executeBatchDelete(_ mode: BatchDeleteMode) {
        switch mode {
        case .unavailable: deleteUnavailablePlugins()
        case .disabled: deleteDisabledPlugins()
        case .all: clearAllPlugins()
        }
    }

    private func deleteSinglePlugin(_ plugin: PluginRecord) {
        let sid = plugin.id
        let pkgID = plugin.packageID
        let name = plugin.name
        modelContext.delete(plugin)
        try? modelContext.save()
        Task {
            await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: sid, packageID: pkgID)
        }
        ToastManager.shared.show("已删除书源「\(name)」")
    }

    private func disableUnavailablePlugins() {
        var count = 0
        for plugin in plugins where plugin.healthState == .unavailable && plugin.isEnabled {
            plugin.isEnabled = false
            count += 1
        }
        try? modelContext.save()
        ToastManager.shared.show("已停用 \(count) 个不可用书源")
    }

    private func deleteUnavailablePlugins() {
        let targets = plugins.filter { $0.healthState == .unavailable }
        guard !targets.isEmpty else { return }
        let pairs = targets.map { ($0.id, $0.packageID) }
        for plugin in targets {
            modelContext.delete(plugin)
        }
        try? modelContext.save()
        Task {
            for (sid, pkgID) in pairs {
                await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: sid, packageID: pkgID)
            }
        }
        ToastManager.shared.show("已删除 \(targets.count) 个不可用书源")
    }

    private func deleteDisabledPlugins() {
        let targets = plugins.filter { !$0.isEnabled }
        guard !targets.isEmpty else { return }
        let pairs = targets.map { ($0.id, $0.packageID) }
        for plugin in targets {
            modelContext.delete(plugin)
        }
        try? modelContext.save()
        Task {
            for (sid, pkgID) in pairs {
                await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: sid, packageID: pkgID)
            }
        }
        ToastManager.shared.show("已删除 \(targets.count) 个已停用书源")
    }

    private func clearAllPlugins() {
        for plugin in plugins {
            modelContext.delete(plugin)
        }
        try? modelContext.save()
        Task {
            await PluginRuntime.shared.removeAllPackagesAndCache()
        }
        ToastManager.shared.show("已清空全部书源")
    }

    private func setAllPluginsEnabled(_ enabled: Bool) {
        for plugin in plugins {
            plugin.isEnabled = enabled
        }
        try? modelContext.save()
        ToastManager.shared.show(enabled ? "已启用全部书源" : "已停用全部书源")
    }

    // MARK: - 导入处理
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                Task {
                    do {
                        let preview = try await PluginRuntime.shared.prepareImportPreview(from: data)
                        self.activeSheet = .importPreview(preview)
                    } catch {
                        self.errorAlertMessage = error.localizedDescription
                    }
                }
            } catch {
                errorAlertMessage = "读取书源包失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorAlertMessage = error.localizedDescription
        }
    }

    private func downloadAndPreparePreview(from rawURL: String) async {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorAlertMessage = "请输入有效的 http/https 书源包链接"
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue(JsHostBridge.mobileUA, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PluginError.network("HTTP \(http.statusCode)")
            }
            let preview = try await PluginRuntime.shared.prepareImportPreview(from: data)
            self.activeSheet = .importPreview(preview)
        } catch {
            errorAlertMessage = "在线导入失败：\(error.localizedDescription)"
        }
    }

    private func installConfirmedPreview(_ preview: PluginImportPreview) {
        Task {
            do {
                let metas = try await PluginRuntime.shared.installPackage(preview)
                await MainActor.run {
                    applyInstalledMetas(metas, from: preview)
                }
            } catch {
                await MainActor.run {
                    errorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyInstalledMetas(_ metas: [ParsedSourceMeta], from preview: PluginImportPreview) {
        var existingGroupsByName: [String: PluginGroup] = [:]
        for g in groups {
            existingGroupsByName[g.name] = g
        }
        var nextGroupOrder = groups.count
        var nextPluginOrder = plugins.count

        for meta in metas {
            let targetGroupID: String?
            let gName = meta.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gName.isEmpty {
                if let existingGroup = existingGroupsByName[gName] {
                    targetGroupID = existingGroup.id
                } else {
                    let newGroup = PluginGroup(name: gName, order: nextGroupOrder)
                    nextGroupOrder += 1
                    modelContext.insert(newGroup)
                    existingGroupsByName[gName] = newGroup
                    targetGroupID = newGroup.id
                }
            } else {
                targetGroupID = nil
            }

            if let existing = plugins.first(where: { $0.id == meta.id }) {
                existing.packageID = preview.packageID
                existing.name = meta.name
                existing.version = preview.version
                existing.author = preview.author
                existing.siteURL = meta.url
                existing.summary = meta.summary.isEmpty ? preview.description : meta.summary
                existing.searchable = meta.searchable
                existing.discoverable = meta.discoverable
                existing.requiresLogin = !meta.loginURL.isEmpty
                existing.loginURL = meta.loginURL
                if existing.groupID == nil {
                    existing.groupID = targetGroupID
                }
            } else {
                let record = PluginRecord(
                    id: meta.id,
                    packageID: preview.packageID,
                    name: meta.name,
                    version: preview.version,
                    author: preview.author,
                    siteURL: meta.url,
                    summary: meta.summary.isEmpty ? preview.description : meta.summary,
                    groupID: targetGroupID,
                    order: nextPluginOrder,
                    isPinned: false,
                    isEnabled: meta.enabledByDefault,
                    searchable: meta.searchable,
                    discoverable: meta.discoverable,
                    requiresLogin: !meta.loginURL.isEmpty,
                    loginURL: meta.loginURL
                )
                nextPluginOrder += 1
                modelContext.insert(record)
            }
        }
        try? modelContext.save()
        if AppSettingsStore.shared.currentDiscoverSourceID.isEmpty,
           let firstDiscover = metas.first(where: { $0.discoverable && $0.enabledByDefault }) {
            AppSettingsStore.shared.currentDiscoverSourceID = firstDiscover.id
        }
        ToastManager.shared.show("成功安装 \(metas.count) 个书源")
    }
}

// MARK: - 5. Plugin Row View (单行书源：支持点击检测可用性及延迟、上下移动、分组切换与删除)
struct PluginRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var plugin: PluginRecord
    let groups: [PluginGroup]
    let isChecking: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onCheckLatency: () -> Void
    let onInspectDetail: () -> Void
    let onOpenWebAuth: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            rowTitleAndSummary
            Spacer(minLength: 4)
            Button(action: onCheckLatency) {
                latencyBadgeView
            }
            .buttonStyle(.plain)
            .accessibilityLabel("检测 \(plugin.name) 可用性及延迟")

            Toggle("", isOn: $plugin.isEnabled)
                .labelsHidden()
                .onChange(of: plugin.isEnabled) { _, _ in
                    try? modelContext.save()
                }

            rowTrailingMenu
        }
        .padding(.vertical, 2)
        .contextMenu {
            rowContextMenuItems
        }
    }

    private var rowTitleAndSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if plugin.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text(plugin.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(plugin.isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                Text("v\(plugin.version)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)

                if plugin.requiresLogin {
                    Image(systemName: plugin.loggedIn ? "checkmark.shield.fill" : "key.fill")
                        .font(.caption2)
                        .foregroundStyle(plugin.loggedIn ? .green : .orange)
                }
            }

            HStack(spacing: 6) {
                Text(plugin.summary.isEmpty ? (plugin.author.isEmpty ? plugin.id : plugin.author) : plugin.summary)
                    .lineLimit(1)
                if !plugin.lastCheckMessage.isEmpty {
                    Text("· \(plugin.lastCheckMessage)")
                        .lineLimit(1)
                        .foregroundStyle(statusTextColor)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onInspectDetail()
        }
    }

    private var rowTrailingMenu: some View {
        Menu {
            Button(action: onCheckLatency) {
                Label("立即检测可用性及延迟", systemImage: "bolt.heart")
            }

            Button(action: onInspectDetail) {
                Label("书源配置与诊断详情", systemImage: "slider.horizontal.3")
            }

            Button(action: onOpenWebAuth) {
                Label("网页登录 / 验证码验证", systemImage: "person.badge.key")
            }

            Divider()

            Button {
                plugin.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(plugin.isPinned ? "取消置顶" : "置顶该书源", systemImage: plugin.isPinned ? "pin.slash" : "pin")
            }

            if canMoveUp {
                Button(action: onMoveUp) {
                    Label("在当前分组上移一位", systemImage: "arrow.up")
                }
            }

            if canMoveDown {
                Button(action: onMoveDown) {
                    Label("在当前分组下移一位", systemImage: "arrow.down")
                }
            }

            Menu("移动到分组") {
                Button {
                    plugin.groupID = nil
                    try? modelContext.save()
                } label: {
                    Label("未分组", systemImage: plugin.groupID == nil ? "checkmark" : "folder")
                }
                ForEach(groups) { g in
                    Button {
                        plugin.groupID = g.id
                        try? modelContext.save()
                    } label: {
                        Label(g.name, systemImage: plugin.groupID == g.id ? "checkmark" : "folder")
                    }
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("删除该书源", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private var rowContextMenuItems: some View {
        Button(action: onCheckLatency) {
            Label("检测可用性及延迟", systemImage: "bolt.heart")
        }

        Button {
            plugin.isPinned.toggle()
            try? modelContext.save()
        } label: {
            Label(plugin.isPinned ? "取消置顶" : "置顶该书源", systemImage: plugin.isPinned ? "pin.slash" : "pin")
        }

        if canMoveUp {
            Button(action: onMoveUp) {
                Label("上移一位", systemImage: "arrow.up")
            }
        }

        if canMoveDown {
            Button(action: onMoveDown) {
                Label("下移一位", systemImage: "arrow.down")
            }
        }

        Button(action: onOpenWebAuth) {
            Label("网页登录 / 验证码验证", systemImage: "person.badge.key")
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("删除该书源", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var latencyBadgeView: some View {
        if isChecking {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("测速中")
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DSColor.primary.opacity(0.12), in: Capsule())
            .foregroundStyle(DSColor.primary)
        } else {
            settledLatencyBadge
        }
    }

    @ViewBuilder
    private var settledLatencyBadge: some View {
        switch plugin.healthState {
        case .untested:
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                Text("检测")
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)

        case .healthy:
            let fast = plugin.lastLatencyMs < 600
            HStack(spacing: 4) {
                Circle()
                    .fill(fast ? Color.green : Color.teal)
                    .frame(width: 6, height: 6)
                Text(plugin.latencyBadgeText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((fast ? Color.green : Color.teal).opacity(0.14), in: Capsule())
            .foregroundStyle(fast ? .green : .teal)

        case .slow:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text(plugin.latencyBadgeText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .foregroundStyle(.orange)

        case .needAuth:
            HStack(spacing: 3) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9))
                Text("需验证")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .foregroundStyle(.orange)

        case .unavailable:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("不可用")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.14), in: Capsule())
            .foregroundStyle(.red)
        }
    }

    private var statusTextColor: Color {
        switch plugin.healthState {
        case .healthy: return .green
        case .slow, .needAuth: return .orange
        case .unavailable: return .red
        case .untested: return .secondary
        }
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

// MARK: - 8. Plugin Detail & Check Sheet (单源详情、实时测速、自定义配置与删除面板)
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

    var body: some View {
        NavigationStack {
            Form {
                healthCheckSection
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
            .task {
                await loadConfigMetadata()
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
        Section("书源状态与分组") {
            Toggle("启用该书源", isOn: $plugin.isEnabled)
            Toggle("置顶该书源", isOn: $plugin.isPinned)

            Picker("所属分组", selection: $plugin.groupID) {
                Text("未分组").tag(String?.none)
                ForEach(groups) { g in
                    Text(g.name).tag(Optional(g.id))
                }
            }

            Button(action: onOpenWebAuth) {
                Label("打开网页登录 / 验证码验证", systemImage: "person.badge.key")
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
