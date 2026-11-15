import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

/// 设置页（5.6 节）：严格划分为 5 个分组（1. 听书源摘要卡片、2. 播放、3. 界面、4. 下载与存储、5. 数据），全量移除无关模块
struct SettingsView: View {
    @Binding var path: [Route]

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\.order)]) private var plugins: [PluginRecord]
    @Query private var books: [Book]
    @Query private var histories: [SearchHistory]

    @State private var settings = AppSettingsStore.shared
    @State private var coverCacheBytes: Int64 = 0
    @State private var showClearHistoryConfirm = false
    @State private var showResetSettingsConfirm = false

    private var loginRequiredCount: Int {
        plugins.filter { $0.requiresLogin && !$0.loggedIn }.count
    }

    var body: some View {
        Form {
            // 1. 听书源（插件）——置顶摘要卡片行（5.6 节第 1 组）
            Section {
                NavigationLink(value: Route.pluginManager) {
                    if plugins.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(DSColor.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导入听书源")
                                    .font(.headline)
                                    .foregroundStyle(DSColor.primary)
                                Text("从本地 .zip 文件或网址导入听书源插件包")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.title3)
                                .foregroundStyle(DSColor.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("听书源管理")
                                    .font(.body.weight(.medium))
                                Text("已安装 \(plugins.count) 个源 · \(loginRequiredCount) 个需要登录")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("听书源")
            }

            // 2. 播放（5.6 节第 2 组）
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("播放通道", selection: Bindable(settings).audioChannel) {
                        ForEach(AudioChannelMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.audioChannel.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Picker("默认倍速", selection: Bindable(settings).defaultSpeed) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { spd in
                        Text(String(format: "%.2gx", spd)).tag(spd)
                    }
                }

                Toggle(isOn: Bindable(settings).sleepFadeOutEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("睡眠定时结束前渐弱")
                        Text("最后 30 秒线性降低音量后暂停")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Bindable(settings).autoResumeOnLaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("打开 App 后自动继续播放")
                        Text("启动时自动恢复上次收听的书籍与进度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("预缓存后续集数", selection: Bindable(settings).precacheCount) {
                    Text("关").tag(0)
                    Text("1 集").tag(1)
                    Text("2 集").tag(2)
                    Text("3 集").tag(3)
                    Text("5 集").tag(5)
                }

                Toggle(isOn: Bindable(settings).rememberBookVolume) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记住每本书的音量")
                        Text("为不同音量的有声书分别保存独立音量")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink(value: Route.skipSettings) {
                    HStack {
                        Text("默认跳过片头/片尾")
                        Spacer()
                        Text("片头 \(settings.defaultSkipIntroSec)s · 片尾 \(settings.defaultSkipOutroSec)s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("播放")
            }

            // 3. 界面（5.6 节第 3 组）
            Section {
                Picker("发现页默认布局", selection: Bindable(settings).discoverLayout) {
                    ForEach(DiscoverLayoutStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                Picker("外观", selection: Bindable(settings).appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle(isOn: Bindable(settings).hapticsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("触感反馈")
                        Text("添加书签与关键操作时提供轻触震动反馈")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("界面")
            }

            // 4. 下载与存储（5.6 节第 4 组）
            Section {
                Toggle(isOn: Bindable(settings).wifiOnlyDownload) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仅 Wi-Fi 下载")
                        Text("使用蜂窝移动网络时不执行离线下载与预缓存")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("已下载占用")
                    Spacer()
                    let dlBytes = DownloadManager.shared.totalManualDownloadedBytes()
                    Text(ByteCountFormatter.string(fromByteCount: dlBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("封面缓存占用")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: coverCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }

                Button("清理缓存") {
                    Task {
                        await CoverImagePipeline.shared.clearCache()
                        DownloadManager.shared.clearPrecacheOnly()
                        ChapterCacheStore.clearAll()
                        coverCacheBytes = await CoverImagePipeline.shared.diskUsageBytes()
                        ToastManager.shared.show("已清理封面缓存与预缓存")
                    }
                }

                NavigationLink("下载管理", value: Route.downloadManager)
            } header: {
                Text("下载与存储")
            }

            // 5. 数据（5.6 节第 5 组：破坏性操作集中在最底部，红色文字，二次确认）
            Section {
                Button(role: .destructive) {
                    showClearHistoryConfirm = true
                } label: {
                    Text("清除播放记录")
                }

                Button(role: .destructive) {
                    showResetSettingsConfirm = true
                } label: {
                    Text("重置所有设置")
                }
            } header: {
                Text("数据")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            coverCacheBytes = await CoverImagePipeline.shared.diskUsageBytes()
        }
        .confirmationDialog("确定要清除所有播放记录与搜索历史吗？", isPresented: $showClearHistoryConfirm, titleVisibility: .visible) {
            Button("清除播放记录", role: .destructive) {
                for b in books {
                    b.lastPlayedAt = nil
                    b.lastPositionMs = 0
                }
                for h in histories {
                    modelContext.delete(h)
                }
                try? modelContext.save()
                ToastManager.shared.show("已清除播放记录")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确定要将所有播放与界面设置恢复为默认值吗？", isPresented: $showResetSettingsConfirm, titleVisibility: .visible) {
            Button("重置所有设置", role: .destructive) {
                settings.resetAll()
                ToastManager.shared.show("已重置所有设置")
            }
            Button("取消", role: .cancel) {}
        }
    }
}

struct DefaultSkipSettingsView: View {
    @State private var settings = AppSettingsStore.shared

    var body: some View {
        Form {
            Section("新加入书架书籍的默认跳过时长") {
                Stepper("默认跳过片头：\(settings.defaultSkipIntroSec) 秒", value: Bindable(settings).defaultSkipIntroSec, in: 0...300, step: 5)
                Stepper("默认跳过片尾：\(settings.defaultSkipOutroSec) 秒", value: Bindable(settings).defaultSkipOutroSec, in: 0...300, step: 5)
            }
        }
        .navigationTitle("默认跳过片头/片尾")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 插件管理二级页（5.7 节）：文件/网址导入预览、置顶区、可折叠分组、源详情与登录验证
struct PluginManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\.order)]) private var groups: [PluginGroup]
    @Query private var shelfBooks: [Book]

    @State private var showFileImporter = false
    @State private var showURLImportAlert = false
    @State private var importURLString = ""
    @State private var importPreview: PluginImportPreview?
    @State private var showNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var authSession: WebAuthSessionRequest?

    private var pinnedPlugins: [PluginRecord] {
        plugins.filter(\.isPinned)
    }

    var body: some View {
        List {
            if plugins.isEmpty {
                ContentUnavailableView(
                    "尚未安装任何听书源插件",
                    systemImage: "puzzlepiece.extension",
                    description: Text("点击右上角「+」从本地 .zip 文件或网址导入插件包")
                )
            } else {
                if !pinnedPlugins.isEmpty {
                    Section("置顶") {
                        ForEach(pinnedPlugins) { plugin in
                            pluginRow(for: plugin)
                        }
                    }
                }

                ForEach(groups) { group in
                    Section {
                        if !group.isCollapsed {
                            let groupItems = plugins.filter { $0.groupID == group.id && !$0.isPinned }
                            ForEach(groupItems) { plugin in
                                pluginRow(for: plugin)
                            }
                        }
                    } header: {
                        HStack {
                            Button {
                                group.isCollapsed.toggle()
                                try? modelContext.save()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                                    Text(group.name)
                                }
                                .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button("删除分组", role: .destructive) {
                                for p in plugins where p.groupID == group.id {
                                    p.groupID = nil
                                }
                                modelContext.delete(group)
                                try? modelContext.save()
                            }
                            .font(.caption2)
                        }
                    }
                }

                let ungrouped = plugins.filter { ($0.groupID == nil || $0.groupID == "") && !$0.isPinned }
                if !ungrouped.isEmpty {
                    Section("未分组") {
                        ForEach(ungrouped) { plugin in
                            pluginRow(for: plugin)
                        }
                    }
                }
            }
        }
        .navigationTitle("听书源管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("新建分组") {
                    showNewGroupAlert = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从文件导入 (.zip)", systemImage: "doc.zipper")
                    }

                    Button {
                        if let clip = UIPasteboard.general.string, clip.hasPrefix("http") {
                            importURLString = clip
                        }
                        showURLImportAlert = true
                    } label: {
                        Label("从网址导入", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("导入插件")
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.zip, .archive],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                let accessed = first.startAccessingSecurityScopedResource()
                defer { if accessed { first.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: first) {
                    Task { await parseAndPreviewZIP(data) }
                }
            }
        }
        .alert("从网址导入插件包 (.zip)", isPresented: $showURLImportAlert) {
            TextField("https://example.com/sources.zip", text: $importURLString)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {}
            Button("下载并预览") {
                let urlStr = importURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await downloadAndPreviewURL(urlStr) }
            }
        }
        .alert("新建听书源分组", isPresented: $showNewGroupAlert) {
            TextField("分组名称", text: $newGroupName)
            Button("取消", role: .cancel) { newGroupName = "" }
            Button("创建") {
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    modelContext.insert(PluginGroup(name: name, order: groups.count))
                    try? modelContext.save()
                }
                newGroupName = ""
            }
        }
        .sheet(item: $importPreview) { preview in
            PluginImportPreviewSheet(preview: preview) { confirmedPreview in
                installConfirmedPackage(confirmedPreview)
            }
        }
        .sheet(item: $authSession) { session in
            WebAuthSheet(session: session)
        }
    }

    private func pluginRow(for plugin: PluginRecord) -> some View {
        NavigationLink {
            SourceDetailView(plugin: plugin) {
                deletePluginSource(plugin)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(plugin.name)
                            .font(.body.weight(.medium))
                        Text("v\(plugin.version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        // 登录状态徽标（5.7 节步骤 3）
                        Button {
                            if plugin.requiresLogin {
                                authSession = WebAuthSessionRequest(
                                    sourceID: plugin.id,
                                    title: "登录 · \(plugin.name)",
                                    initialURL: plugin.loginURL.isEmpty ? plugin.siteURL : plugin.loginURL,
                                    expectedCookieName: nil,
                                    onCompleted: {
                                        plugin.loggedIn = true
                                        try? modelContext.save()
                                    }
                                )
                            }
                        } label: {
                            Text(plugin.requiresLogin ? (plugin.loggedIn ? "已登录" : "需要登录") : "无需登录")
                                .font(.caption2)
                                .foregroundStyle(plugin.requiresLogin && !plugin.loggedIn ? .orange : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DSColor.cardSurface)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        if !plugin.summary.isEmpty {
                            Text(plugin.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                Toggle("", isOn: Bindable(plugin).isEnabled)
                    .labelsHidden()
                    .onChange(of: plugin.isEnabled) { _, _ in
                        try? modelContext.save()
                    }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                plugin.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(plugin.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(DSColor.primary)

            Button(role: .destructive) {
                deletePluginSource(plugin)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                plugin.isEnabled.toggle()
                try? modelContext.save()
            } label: {
                Text(plugin.isEnabled ? "停用" : "启用")
            }
            .tint(plugin.isEnabled ? .gray : .green)
        }
    }

    private func parseAndPreviewZIP(_ data: Data) async {
        do {
            let preview = try await PluginRuntime.shared.prepareImportPreview(from: data)
            importPreview = preview
        } catch {
            ToastManager.shared.show(error.localizedDescription)
        }
    }

    private func downloadAndPreviewURL(_ urlStr: String) async {
        guard let url = URL(string: urlStr) else {
            ToastManager.shared.show("请输入合法的 http/https 插件地址")
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            await parseAndPreviewZIP(data)
        } catch {
            ToastManager.shared.show("下载插件包失败：\(error.localizedDescription)")
        }
    }

    private func installConfirmedPackage(_ preview: PluginImportPreview) {
        Task {
            do {
                let installedMetas = try await PluginRuntime.shared.installPackage(preview)
                var successCount = 0
                for meta in installedMetas {
                    // 同名同 id 的插件视为更新，保留分组、置顶与登录状态（5.7 节步骤 1）
                    var groupID: String? = nil
                    if !meta.group.isEmpty {
                        if let existingGroup = groups.first(where: { $0.name == meta.group }) {
                            groupID = existingGroup.id
                        } else {
                            let newGroup = PluginGroup(name: meta.group, order: groups.count)
                            modelContext.insert(newGroup)
                            groupID = newGroup.id
                        }
                    }

                    if let existing = plugins.first(where: { $0.id == meta.id }) {
                        existing.packageID = preview.packageID
                        existing.name = meta.name
                        existing.version = preview.version
                        existing.author = preview.author
                        existing.siteURL = meta.url
                        existing.summary = meta.summary
                        existing.searchable = meta.searchable
                        existing.discoverable = meta.discoverable
                        existing.requiresLogin = !meta.loginURL.isEmpty
                        existing.loginURL = meta.loginURL
                    } else {
                        let record = PluginRecord(
                            id: meta.id,
                            packageID: preview.packageID,
                            name: meta.name,
                            version: preview.version,
                            author: preview.author,
                            siteURL: meta.url,
                            summary: meta.summary,
                            groupID: groupID,
                            order: plugins.count + successCount,
                            isPinned: false,
                            isEnabled: meta.enabledByDefault,
                            searchable: meta.searchable,
                            discoverable: meta.discoverable,
                            requiresLogin: !meta.loginURL.isEmpty,
                            loginURL: meta.loginURL,
                            loggedIn: false
                        )
                        modelContext.insert(record)
                    }
                    // 恢复之前标记为来源不可用的书籍
                    for b in shelfBooks where b.sourceID == meta.id {
                        b.sourceUnavailable = false
                    }
                    successCount += 1
                }
                try? modelContext.save()
                ToastManager.shared.show("导入完成：成功 \(successCount) 个源")
            } catch {
                ToastManager.shared.show("安装失败：\(error.localizedDescription)")
            }
        }
    }

    private func deletePluginSource(_ plugin: PluginRecord) {
        let sourceID = plugin.id
        let pkgID = plugin.packageID
        // 书架中来自该源的书保留，但标记「来源不可用」（5.7 节步骤 5）
        for book in shelfBooks where book.sourceID == sourceID {
            book.sourceUnavailable = true
        }
        modelContext.delete(plugin)
        try? modelContext.save()
        Task {
            await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: sourceID, packageID: pkgID)
        }
        ToastManager.shared.show("已删除听书源并清理关联缓存")
    }
}

/// 插件导入安全确认预览 Sheet（4.2.7 & 5.7 节步骤 1）
struct PluginImportPreviewSheet: View {
    let preview: PluginImportPreview
    let onConfirm: (PluginImportPreview) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("插件包概要") {
                    LabeledContent("插件包名称", value: preview.name)
                    LabeledContent("版本", value: preview.version)
                    if !preview.author.isEmpty {
                        LabeledContent("作者", value: preview.author)
                    }
                    LabeledContent("包含听书源数量", value: "\(preview.sources.count) 个")
                }

                if !preview.domains.isEmpty {
                    Section("声明将要访问的域名（共 \(preview.domains.count) 个）") {
                        ForEach(preview.domains, id: \.self) { domain in
                            Text(domain)
                                .font(.caption.monospaced())
                        }
                    }
                }

                Section("包含的听书源列表") {
                    ForEach(preview.sources, id: \.id) { src in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(src.name)
                                .font(.subheadline.weight(.medium))
                            Text(src.url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("确认导入听书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认安装") {
                        onConfirm(preview)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct SourceDetailView: View {
    @Bindable var plugin: PluginRecord
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\.order)]) private var groups: [PluginGroup]
    @State private var showDeleteConfirm = false
    @State private var authSession: WebAuthSessionRequest?

    var body: some View {
        Form {
            Section("基本信息") {
                LabeledContent("名称", value: plugin.name)
                LabeledContent("版本", value: plugin.version)
                if !plugin.author.isEmpty {
                    LabeledContent("作者", value: plugin.author)
                }
                LabeledContent("站点域名", value: plugin.siteURL)
            }

            Section("分组与状态") {
                Toggle("启用该听书源", isOn: $plugin.isEnabled)
                Toggle("置顶显示", isOn: $plugin.isPinned)
                Picker("所属分组", selection: $plugin.groupID) {
                    Text("未分组").tag(String?.none)
                    ForEach(groups) { g in
                        Text(g.name).tag(Optional(g.id))
                    }
                }
            }

            if plugin.requiresLogin {
                Section("账号登录") {
                    Button(plugin.loggedIn ? "重新登录" : "去登录账号") {
                        authSession = WebAuthSessionRequest(
                            sourceID: plugin.id,
                            title: "登录 · \(plugin.name)",
                            initialURL: plugin.loginURL.isEmpty ? plugin.siteURL : plugin.loginURL,
                            expectedCookieName: nil,
                            onCompleted: {
                                plugin.loggedIn = true
                                try? modelContext.save()
                            }
                        )
                    }
                    if plugin.loggedIn {
                        Button("退出登录并清除 Cookie", role: .destructive) {
                            plugin.loggedIn = false
                            clearCookies(for: plugin.siteURL)
                            try? modelContext.save()
                            ToastManager.shared.show("已退出登录")
                        }
                    }
                }
            }

            Section {
                Button("清除该源缓存与 Cookie") {
                    clearCookies(for: plugin.siteURL)
                    ToastManager.shared.show("已清除该源缓存与 Cookie")
                }

                Button("删除该听书源", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .navigationTitle(plugin.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $authSession) { session in
            WebAuthSheet(session: session)
        }
        .confirmationDialog("确定要删除「\(plugin.name)」吗？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除听书源", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func clearCookies(for urlString: String) {
        guard let url = URL(string: urlString),
              let cookies = HTTPCookieStorage.shared.cookies(for: url) else { return }
        for c in cookies {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
    }
}
