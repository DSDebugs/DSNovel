import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

// MARK: - 书源管理（重新设计）
//
// 设计原则：一个页面完成「导入 → 检测 → 启用/停用 → 整理」，不再有多处重复入口。
//  · 右上角「＋」：导入（文件 / 链接 / 剪贴板）
//  · 右上角「…」：整理（检测、排序、分组、批量停用/删除）
//  · 顶部一张状态卡：当前书源概况 + 一键检测
//  · 分段筛选：全部 / 可用 / 异常 / 已停用
//  · 每行：状态灯 + 名称 + 延迟，右侧开关直接启用/停用；点击行进入详情
//  · 左滑：删除、置顶；右滑：检测

enum SourceFilterMode: String, CaseIterable, Identifiable {
    case all = "全部"
    case available = "可用"
    case abnormal = "异常"
    case disabled = "已停用"

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

struct PluginManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]

    @State private var editMode: EditMode = .inactive
    @State private var searchText: String = ""
    @State private var selectedFilter: SourceFilterMode = .all

    // 弹窗与导入
    @State private var activeSheet: PluginManagerSheet?
    @State private var showFileImporter = false
    @State private var showURLImportAlert = false
    @State private var importURLString: String = ""
    @State private var isImporting = false
    @State private var errorAlertMessage: String?

    // 检测
    @State private var checkingSourceIDs: Set<String> = []
    @State private var isBatchChecking = false
    @State private var batchCompletedCount: Int = 0
    @State private var batchTotalCount: Int = 0
    @State private var batchCheckTask: Task<Void, Never>?

    // 删除确认
    @State private var pendingDeletePlugin: PluginRecord?
    @State private var activeBatchDeleteMode: BatchDeleteMode?

    // MARK: 统计

    private var enabledCount: Int { plugins.filter(\.isEnabled).count }
    private var availableCount: Int { plugins.filter(\.isHealthyOrSlow).count }
    private var unavailableCount: Int { plugins.filter { $0.healthState == .unavailable }.count }
    private var abnormalCount: Int {
        plugins.filter { $0.healthState == .unavailable || $0.healthState == .needAuth }.count
    }
    private var disabledCount: Int { plugins.filter { !$0.isEnabled }.count }

    private func count(for mode: SourceFilterMode) -> Int {
        switch mode {
        case .all: return plugins.count
        case .available: return availableCount
        case .abnormal: return abnormalCount
        case .disabled: return disabledCount
        }
    }

    // MARK: 筛选后的数据

    private var filteredPlugins: [PluginRecord] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return plugins.filter { plugin in
            if !kw.isEmpty {
                let hit = plugin.name.localizedCaseInsensitiveContains(kw)
                    || plugin.id.localizedCaseInsensitiveContains(kw)
                    || plugin.author.localizedCaseInsensitiveContains(kw)
                    || plugin.summary.localizedCaseInsensitiveContains(kw)
                if !hit { return false }
            }
            switch selectedFilter {
            case .all: return true
            case .available: return plugin.isHealthyOrSlow
            case .abnormal: return plugin.healthState == .unavailable || plugin.healthState == .needAuth
            case .disabled: return !plugin.isEnabled
            }
        }
    }

    private var pinnedPlugins: [PluginRecord] {
        filteredPlugins.filter(\.isPinned).sorted { $0.order < $1.order }
    }

    private func groupItems(in group: PluginGroup) -> [PluginRecord] {
        filteredPlugins
            .filter { !$0.isPinned && $0.groupID == group.id }
            .sorted { $0.order < $1.order }
    }

    /// 未分组：包含 groupID 为空，或指向已不存在分组的书源（避免书源「消失」）
    private var ungroupedPlugins: [PluginRecord] {
        let validGroupIDs = Set(groups.map(\.id))
        return filteredPlugins
            .filter { p in
                guard !p.isPinned else { return false }
                guard let gid = p.groupID, !gid.isEmpty else { return true }
                return !validGroupIDs.contains(gid)
            }
            .sorted { $0.order < $1.order }
    }

    // MARK: Body

    var body: some View {
        Group {
            if plugins.isEmpty {
                emptyState
            } else {
                managerContent
            }
        }
        .background(DSColor.contentBackground)
        .navigationTitle("书源管理")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType.zip, UTType.javaScript, UTType.archive, UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("从链接导入", isPresented: $showURLImportAlert) {
            TextField("https://…/sources.zip", text: $importURLString)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("下载并预览") {
                let url = importURLString
                Task { await downloadAndPreparePreview(from: url) }
            }
        } message: {
            Text("输入 .zip 书源包或 .js 脚本的直链地址，下载后会先展示书源列表，确认后才会安装。")
        }
        .alert("删除书源", isPresented: Binding(
            get: { pendingDeletePlugin != nil },
            set: { if !$0 { pendingDeletePlugin = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeletePlugin = nil }
            Button("删除", role: .destructive) {
                if let target = pendingDeletePlugin { deleteSinglePlugin(target) }
                pendingDeletePlugin = nil
            }
        } message: {
            Text("确认删除「\(pendingDeletePlugin?.name ?? "")」及其本地缓存吗？")
        }
        .alert("提示", isPresented: Binding(
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
            sheetView(for: sheet)
        }
        .onDisappear {
            batchCheckTask?.cancel()
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editMode == .active {
                Button("完成") {
                    withAnimation { editMode = .inactive }
                }
                .fontWeight(.semibold)
            } else {
                if !plugins.isEmpty {
                    organizeMenu
                }
                importMenu
            }
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                showFileImporter = true
            } label: {
                Label("从文件导入", systemImage: "doc.zipper")
            }
            Button {
                importURLString = ""
                showURLImportAlert = true
            } label: {
                Label("从链接导入", systemImage: "link")
            }
            Button {
                importFromClipboard()
            } label: {
                Label("从剪贴板链接导入", systemImage: "doc.on.clipboard")
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

    private var organizeMenu: some View {
        Menu {
            Section("检测") {
                Button {
                    startHealthCheck(ids: plugins.filter(\.isEnabled).map(\.id))
                } label: {
                    Label("检测已启用书源 (\(enabledCount))", systemImage: "bolt.heart")
                }
                Button {
                    startHealthCheck(ids: plugins.map(\.id))
                } label: {
                    Label("检测全部书源 (\(plugins.count))", systemImage: "network")
                }
            }

            Section("排序与分组") {
                Button {
                    sortPluginsByLatency()
                } label: {
                    Label("按速度排序（最快优先）", systemImage: "bolt.horizontal")
                }
                Button {
                    sortPluginsByAvailability()
                } label: {
                    Label("按可用状态排序", systemImage: "checkmark.seal")
                }
                Button {
                    sortPluginsByName()
                } label: {
                    Label("按名称排序", systemImage: "textformat.abc")
                }
                Button {
                    withAnimation { editMode = .active }
                } label: {
                    Label("手动拖拽排序", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    activeSheet = .groupSort
                } label: {
                    Label("分组管理…", systemImage: "folder.badge.gearshape")
                }
            }

            Section("批量操作") {
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
                        Label("停用不可用书源 (\(unavailableCount))", systemImage: "slash.circle")
                    }
                    Button(role: .destructive) {
                        activeBatchDeleteMode = .unavailable
                    } label: {
                        Label("删除不可用书源 (\(unavailableCount))", systemImage: "trash")
                    }
                }
                if disabledCount > 0 {
                    Button(role: .destructive) {
                        activeBatchDeleteMode = .disabled
                    } label: {
                        Label("删除已停用书源 (\(disabledCount))", systemImage: "trash.slash")
                    }
                }
                Button(role: .destructive) {
                    activeBatchDeleteMode = .all
                } label: {
                    Label("清空全部书源", systemImage: "xmark.bin")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("整理书源")
    }

    // MARK: 空状态（不内置任何书源）

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有书源", systemImage: "puzzlepiece.extension")
        } description: {
            Text("应用不内置任何书源。请导入你自己的书源包（.zip）或 .js 脚本后开始使用。")
        } actions: {
            VStack(spacing: 10) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入", systemImage: "doc.zipper")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    importURLString = ""
                    showURLImportAlert = true
                } label: {
                    Label("从链接导入", systemImage: "link")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.bordered)

                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板链接导入", systemImage: "doc.on.clipboard")
                        .font(.footnote)
                }
            }
        }
    }

    // MARK: 主内容

    private var managerContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                summaryCard
                Picker("筛选", selection: $selectedFilter) {
                    ForEach(SourceFilterMode.allCases) { mode in
                        Text("\(mode.rawValue) \(count(for: mode))").tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, 10)

            if filteredPlugins.isEmpty {
                ContentUnavailableView(
                    "没有符合条件的书源",
                    systemImage: "magnifyingglass",
                    description: Text(searchText.isEmpty ? "切换上方筛选查看其他书源" : "换个关键词试试")
                )
            } else {
                sourceList
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索书源名称或说明")
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("共 \(plugins.count) 个书源 · 已启用 \(enabledCount)")
                    .font(.subheadline.weight(.semibold))
                if isBatchChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在检测 \(batchCompletedCount)/\(batchTotalCount)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isBatchChecking {
                Button(role: .destructive) {
                    stopBatchHealthCheck()
                } label: {
                    Text("停止")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    startHealthCheck(ids: plugins.filter(\.isEnabled).map(\.id))
                } label: {
                    Text("一键检测")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(DSColor.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DSColor.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var summarySubtitle: String {
        let untested = plugins.filter { $0.healthState == .untested }.count
        if untested == plugins.count { return "尚未检测，点「一键检测」找出可用书源" }
        var parts: [String] = ["可用 \(availableCount)"]
        if unavailableCount > 0 { parts.append("不可用 \(unavailableCount)") }
        let needAuth = plugins.filter { $0.healthState == .needAuth }.count
        if needAuth > 0 { parts.append("需验证 \(needAuth)") }
        if untested > 0 { parts.append("未检测 \(untested)") }
        return parts.joined(separator: " · ")
    }

    private var sourceList: some View {
        List {
            if !pinnedPlugins.isEmpty {
                Section {
                    ForEach(pinnedPlugins) { row(for: $0) }
                        .onMove { movePlugins(in: pinnedPlugins, from: $0, to: $1) }
                } header: {
                    Label("置顶", systemImage: "pin.fill")
                }
            }

            ForEach(groups) { group in
                let items = groupItems(in: group)
                if !items.isEmpty {
                    Section {
                        if !group.isCollapsed {
                            ForEach(items) { row(for: $0) }
                                .onMove { movePlugins(in: items, from: $0, to: $1) }
                        }
                    } header: {
                        Button {
                            group.isCollapsed.toggle()
                            try? modelContext.save()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption2)
                                Text("\(group.name) (\(items.count))")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !ungroupedPlugins.isEmpty {
                Section {
                    ForEach(ungroupedPlugins) { row(for: $0) }
                        .onMove { movePlugins(in: ungroupedPlugins, from: $0, to: $1) }
                } header: {
                    let showTitle = !groups.isEmpty || !pinnedPlugins.isEmpty
                    Text(showTitle ? "未分组 (\(ungroupedPlugins.count))" : "书源 (\(ungroupedPlugins.count))")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for plugin: PluginRecord) -> some View {
        PluginSourceRow(
            plugin: plugin,
            isChecking: checkingSourceIDs.contains(plugin.id),
            onTap: { activeSheet = .detail(plugin) }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletePlugin = plugin
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                plugin.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(plugin.isPinned ? "取消置顶" : "置顶", systemImage: plugin.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await checkSinglePlugin(plugin) }
            } label: {
                Label("检测", systemImage: "bolt.heart")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func sheetView(for sheet: PluginManagerSheet) -> some View {
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

    private func openWebAuth(for plugin: PluginRecord) {
        let targetURL = plugin.loginURL.isEmpty ? plugin.siteURL : plugin.loginURL
        guard !targetURL.isEmpty else {
            errorAlertMessage = "该书源没有提供登录或验证地址"
            return
        }
        let sid = plugin.id
        let session = WebAuthSessionRequest(
            sourceID: sid,
            title: "登录/验证 · \(plugin.name)",
            initialURL: targetURL,
            expectedCookieName: nil,
            onCompleted: {
                if let record = record(for: sid) {
                    record.loggedIn = true
                    Task { await checkSinglePlugin(record) }
                }
            }
        )
        activeSheet = .webAuth(session)
    }

    // MARK: 检测

    private func record(for id: String) -> PluginRecord? {
        var descriptor = FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func applyCheckResult(_ res: SourceHealthCheckResult, to record: PluginRecord) {
        record.lastCheckStatus = res.state.rawValue
        record.lastLatencyMs = res.latencyMs
        record.lastCheckMessage = res.message
        record.lastCheckedAt = res.checkedAt
        try? modelContext.save()
    }

    private func checkSinglePlugin(_ plugin: PluginRecord) async {
        let sourceID = plugin.id
        guard !checkingSourceIDs.contains(sourceID) else { return }
        checkingSourceIDs.insert(sourceID)
        let res = await PluginRuntime.shared.checkSourceHealth(sourceID: sourceID)
        if let latest = record(for: sourceID) {
            applyCheckResult(res, to: latest)
        }
        checkingSourceIDs.remove(sourceID)
    }

    /// 批量并发检测（最多 5 个同时进行）；结果逐个写回，界面实时更新
    private func startHealthCheck(ids targetIDs: [String]) {
        guard !targetIDs.isEmpty else { return }
        batchCheckTask?.cancel()

        isBatchChecking = true
        batchCompletedCount = 0
        batchTotalCount = targetIDs.count

        batchCheckTask = Task {
            let maxConcurrency = 5
            var nextIndex = 0
            var okCount = 0
            var failCount = 0

            await withTaskGroup(of: (String, SourceHealthCheckResult).self) { group in
                while nextIndex < min(maxConcurrency, targetIDs.count) {
                    let sid = targetIDs[nextIndex]
                    nextIndex += 1
                    checkingSourceIDs.insert(sid)
                    group.addTask {
                        let res = await PluginRuntime.shared.checkSourceHealth(sourceID: sid)
                        return (sid, res)
                    }
                }

                while let (sid, res) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let rec = record(for: sid) {
                        applyCheckResult(res, to: rec)
                    }
                    if res.state == .healthy || res.state == .slow { okCount += 1 }
                    if res.state == .unavailable { failCount += 1 }
                    checkingSourceIDs.remove(sid)
                    batchCompletedCount += 1

                    if nextIndex < targetIDs.count {
                        let nextSid = targetIDs[nextIndex]
                        nextIndex += 1
                        checkingSourceIDs.insert(nextSid)
                        group.addTask {
                            let res = await PluginRuntime.shared.checkSourceHealth(sourceID: nextSid)
                            return (nextSid, res)
                        }
                    }
                }
            }

            let cancelled = Task.isCancelled
            checkingSourceIDs.removeAll()
            isBatchChecking = false
            if !cancelled {
                ToastManager.shared.show("检测完成：\(okCount) 可用，\(failCount) 不可用")
            }
        }
    }

    private func stopBatchHealthCheck() {
        batchCheckTask?.cancel()
        batchCheckTask = nil
        checkingSourceIDs.removeAll()
        isBatchChecking = false
        ToastManager.shared.show("已停止检测（完成 \(batchCompletedCount)/\(batchTotalCount)）")
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
                    // 导入后自动检测新书源，让可用性与延迟立刻可见，搜索时即可提前跳过不可用的源
                    startHealthCheck(ids: metas.map(\.id))
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
        var nextPluginOrder = (plugins.map(\.order).max() ?? -1) + 1

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

    private func importFromClipboard() {
        let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorAlertMessage = "剪贴板里没有有效的书源链接（需要以 http:// 或 https:// 开头）"
            return
        }
        Task { await downloadAndPreparePreview(from: raw) }
    }
}



// MARK: - 单行书源

struct PluginSourceRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var plugin: PluginRecord
    let isChecking: Bool
    let onTap: () -> Void

    private var statusColor: Color {
        switch plugin.healthState {
        case .untested: return Color.secondary.opacity(0.45)
        case .healthy: return .green
        case .slow: return .yellow
        case .needAuth: return .orange
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        switch plugin.healthState {
        case .untested: return "未检测"
        case .healthy, .slow: return plugin.lastLatencyMs > 0 ? "\(plugin.lastLatencyMs)ms" : "可用"
        case .needAuth: return "需登录/验证"
        case .unavailable:
            return plugin.lastCheckMessage.isEmpty ? "不可用" : "不可用 · \(plugin.lastCheckMessage)"
        }
    }

    private var subtitle: String {
        plugin.summary.isEmpty ? statusText : "\(statusText) · \(plugin.summary)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if plugin.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(plugin.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(plugin.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    if plugin.requiresLogin && !plugin.loggedIn {
                        Image(systemName: "key.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isChecking {
                ProgressView().controlSize(.small)
            }

            Toggle("", isOn: $plugin.isEnabled)
                .labelsHidden()
                .onChange(of: plugin.isEnabled) { _, _ in
                    try? modelContext.save()
                }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

