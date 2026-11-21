import DSCore
import DSDesignSystem
import DSPluginKit
import DSStorage
import SwiftUI
import UniformTypeIdentifiers

/// 书源管理列表（支持 Q5 未声明 hosts 第三方源弹窗风险确认放行 + 覆盖升级保留用户配置）
struct SourceListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner
    @Environment(AppSettingsStore.self) private var settings

    @State private var sources: [SourceMetaDTO] = []
    @State private var showImportSheet = false
    @State private var showFileImporter = false
    @State private var showOrganizeSheet = false
    @State private var isSeedingSources = false
    @State private var isImporting = false
    @State private var importScriptText = ""
    @State private var queuedCompatPreview: SourcePreviewResult?
    @State private var pendingCompatPreview: SourcePreviewResult?
    @State private var toggleVersions: [String: UInt64] = [:]
    @State private var toggleSerialTask: Task<Void, Never>?

    var body: some View {
        List {
            if settings.builtinParserUnlocked {
                Section("内置解析器（独立于书源）") {
                    Button {
                        router.push(.builtinParser)
                    } label: {
                        HStack {
                            Label("内置音频解析器", systemImage: "cpu")
                                .foregroundStyle(DSColors.inkPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("已安装书源（\(sources.count)）") {
                if sources.isEmpty {
                    Text("暂无书源，可点击右上角导入或重新加载内置书源。")
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                } else {
                    ForEach(sources) { src in
                        HStack(spacing: DSSpacing.sm) {
                            Button {
                                router.push(.sourceDetail(sourceID: src.id))
                            } label: {
                                HStack(spacing: DSSpacing.sm) {
                                    DSSourceAvatar(name: src.name)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(src.name)
                                            .font(DSTypography.headline)
                                            .foregroundStyle(DSColors.inkPrimary)
                                            .lineLimit(2)
                                        Text("v\(src.version) · \(src.permissionMode == .compatApproved ? "兼容放行" : "白名单模式")")
                                            .font(DSTypography.caption)
                                            .foregroundStyle(DSColors.inkSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle("", isOn: Binding(
                                get: { src.isEnabled },
                                set: { next in enqueueSourceEnabled(src.id, enabled: next) }
                            ))
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel("启用或停用书源 \(src.name)")
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                deleteSource(src.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceBase)
        .navigationTitle("书源管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    Button("重置内置") {
                        Task { await resetBundledSources() }
                    }
                    .frame(minHeight: 44)
                    .disabled(isSeedingSources)
                    Button("整理") {
                        showOrganizeSheet = true
                    }
                    .frame(minHeight: 44)
                    .disabled(sources.isEmpty)
                    Button {
                        showImportSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("导入第三方书源")
                }
            }
        }
        .sheet(isPresented: $showOrganizeSheet) {
            SourceOrganizeSheet(sources: sources, onSaved: { Task { await reload() } }) {
                showOrganizeSheet = false
            }
        }
        .sheet(isPresented: $showImportSheet, onDismiss: {
            if let queued = queuedCompatPreview {
                queuedCompatPreview = nil
                pendingCompatPreview = queued
            }
        }) {
            DSSheetScaffold(title: "导入第三方书源（ES5 JS）", banner: banner, onDismiss: { showImportSheet = false }) {
                VStack(spacing: DSSpacing.md) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从文件导入 .zip 书源包或 .js 脚本", systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isImporting)
                    TextEditor(text: $importScriptText)
                        .font(DSTypography.footnote)
                        .padding(DSSpacing.xs)
                        .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.md))
                    Button {
                        Task { await previewAndImport() }
                    } label: {
                        if isImporting {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Text("安全预览并导入")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || importScriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(DSSpacing.md)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.zip, .javaScript, .plainText],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleImportedFile(result) }
            }
        }
        // Q5 决策：未声明 hosts 的第三方书源，在导入 Sheet 关闭后再弹风险确认弹窗（私网 SSRF 仍强制拦截）
        .alert("安全提示：书源未声明域名白名单", isPresented: Binding(
            get: { pendingCompatPreview != nil },
            set: { if !$0 { pendingCompatPreview = nil } }
        )) {
            Button("取消导入", role: .cancel) { pendingCompatPreview = nil }
            Button("确认兼容放行并导入") {
                if let preview = pendingCompatPreview {
                    Task { await commitImport(preview) }
                }
                pendingCompatPreview = nil
            }
        } message: {
            Text("该第三方书源未声明 hosts 白名单。确认兼容放行后，宿主仍会强制拦截内网/回环 SSRF 与 302 跨域 Cookie 泄露。")
        }
        .onChange(of: container.sourcesRevision) { _, _ in
            Task { await reload() }
        }
        .task { await reload() }
    }

    private func reload() async {
        if let rows = try? await container.persistence.fetchAllSources() {
            sources = rows.map(\.meta)
        }
    }

    private func previewAndImport() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let preview = try await container.pluginRuntime.previewSources(scriptBody: importScriptText)
            guard !preview.sources.isEmpty else {
                banner.show("脚本未注册有效书源", tone: .warning)
                return
            }
            if preview.requiresCompatConfirmation {
                queuedCompatPreview = preview
                showImportSheet = false
            } else {
                showImportSheet = false
                await commitImport(preview)
            }
        } catch {
            banner.show("预览校验失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func commitImport(_ preview: SourcePreviewResult) async {
        do {
            for meta in preview.sources {
                try await container.persistence.upsertSource(meta: meta, scriptBody: preview.scriptBody, isBundled: false)
            }
            if let all = try? await container.persistence.fetchAllSources() {
                await container.pluginRuntime.registerSources(all)
            }
            container.notifySourcesChanged()
            importScriptText = ""
            await reload()
            banner.show("已导入 \(preview.sources.count) 个书源", tone: .success)
        } catch {
            banner.show("导入失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func deleteSource(_ id: String) {
        sources.removeAll { $0.id == id }
        let previous = toggleSerialTask
        toggleSerialTask = Task {
            _ = await previous?.value
            do {
                try await container.persistence.deleteSource(id: id)
                if let all = try? await container.persistence.fetchAllSources() {
                    await container.pluginRuntime.registerSources(all)
                }
                container.notifySourcesChanged()
                await reload()
                banner.show("已删除书源", tone: .info)
            } catch {
                await reload()
                banner.show("删除书源失败：\(error.localizedDescription)", tone: .error)
            }
        }
    }

    private func enqueueSourceEnabled(_ id: String, enabled: Bool) {
        let nextVer = (toggleVersions[id] ?? 0) &+ 1
        toggleVersions[id] = nextVer
        if let idx = sources.firstIndex(where: { $0.id == id }) {
            let old = sources[idx]
            sources[idx] = SourceMetaDTO(
                id: old.id, name: old.name, version: old.version, author: old.author,
                summary: old.summary, declaredHosts: old.declaredHosts,
                permissionMode: old.permissionMode, methods: old.methods,
                isEnabled: enabled, isPinned: old.isPinned,
                groupName: old.groupName, sortOrder: old.sortOrder, loginURL: old.loginURL
            )
        }
        let previous = toggleSerialTask
        toggleSerialTask = Task {
            _ = await previous?.value
            do {
                try await container.persistence.updateSourceOrganization(id: id, isEnabled: enabled)
                if let all = try? await container.persistence.fetchAllSources() {
                    await container.pluginRuntime.registerSources(all)
                }
                container.notifySourcesChanged()
            } catch {
                banner.show("更新书源状态失败：\(error.localizedDescription)", tone: .error)
            }
            if toggleVersions[id] == nextVer {
                await reload()
            }
        }
    }

    private func resetBundledSources() async {
        guard !isSeedingSources else { return }
        isSeedingSources = true
        defer { isSeedingSources = false }
        await BundledSourceSeeder.seedIfNeeded(
            persistence: container.persistence,
            pluginRuntime: container.pluginRuntime,
            settings: container.settings,
            logger: container.logger,
            force: true
        )
        if let all = try? await container.persistence.fetchAllSources() {
            await container.pluginRuntime.registerSources(all)
        }
        container.notifySourcesChanged()
        await reload()
        banner.show("已重新加载随包内置书源", tone: .success)
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) async {
        let fileURL: URL
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            fileURL = first
        case .failure(let error):
            banner.show("读取书源文件失败：\(error.localizedDescription)", tone: .error)
            return
        }
        let isZip = fileURL.pathExtension.lowercased() == "zip"
        do {
            let extracted: String? = try await Task.detached(priority: .userInitiated) {
                let accessed = fileURL.startAccessingSecurityScopedResource()
                defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: fileURL)
                if isZip {
                    return try BundledSourceSeeder.extractOrderedScripts(from: data)
                }
                return String(data: BundledSourceSeeder.stripUTF8BOM(data), encoding: .utf8)
            }.value
            guard let script = extracted else {
                banner.show("文件不是有效的 UTF-8 编码", tone: .error)
                return
            }
            if isZip, script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                banner.show("ZIP 压缩包内未找到有效 JS 书源脚本", tone: .warning)
                return
            }
            importScriptText = script
            await previewAndImport()
        } catch {
            banner.show("读取书源文件失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
