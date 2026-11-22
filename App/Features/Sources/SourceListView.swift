import DSCore
import DSDesignSystem
import DSPluginKit
import DSStorage
import SwiftUI
import UniformTypeIdentifiers

/// 书源管理列表（顶部 DSChipBar 状态筛选 + 已置顶/分组/未分组 + 真实登录态角标 + 右滑置顶/删除）
struct SourceListView: View {
    @Environment(AppContainer.self) var container
    @Environment(AppRouter.self) var router
    @Environment(DSBannerCoordinator.self) var banner

    @State var sources: [SourceMetaDTO] = []
    @State var selectedFilter: SourceListFilter = .all
    @State var showImportSheet = false
    @State var showFileImporter = false
    @State var showOrganizeSheet = false
    @State var isSeedingSources = false
    @State var isImporting = false
    @State var importScriptText = ""
    @State var queuedCompatPreview: SourcePreviewResult?
    @State var pendingCompatPreview: SourcePreviewResult?
    @State var mutationVersions: [String: UInt64] = [:]
    @State var mutationSerialTask: Task<Void, Never>?

    var body: some View {
        let loggedInIDs = container.sourceAuth.loggedInSourceIDs
        let chips = SourceListHelper.makeFilterChips(from: sources, loggedInSourceIDs: loggedInIDs)
        let partition = SourceListHelper.partition(sources: sources, filter: selectedFilter, loggedInSourceIDs: loggedInIDs)

        List {
            if sources.isEmpty {
                Section("已安装书源（0）") {
                    Text("暂无书源，可点击右上角导入或重新加载内置书源。")
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .listRowBackground(DSColors.surfaceCard)
                }
            } else if partition.isEmpty {
                Section {
                    DSStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "当前筛选下暂无书源",
                        message: "切换顶部状态标签可查看全部已安装书源。",
                        actionTitle: "查看全部",
                        action: { selectedFilter = .all }
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                if !partition.pinned.isEmpty {
                    Section("已置顶（\(partition.pinned.count)）") {
                        ForEach(partition.pinned) { src in
                            sourceRow(src)
                                .listRowBackground(DSColors.surfaceCard)
                        }
                    }
                }

                ForEach(partition.grouped) { section in
                    Section("\(section.title)（\(section.sources.count)）") {
                        ForEach(section.sources) { src in
                            sourceRow(src)
                                .listRowBackground(DSColors.surfaceCard)
                        }
                    }
                }

                if !partition.ungrouped.isEmpty {
                    Section("未分组（\(partition.ungrouped.count)）") {
                        ForEach(partition.ungrouped) { src in
                            sourceRow(src)
                                .listRowBackground(DSColors.surfaceCard)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("书源管理")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !sources.isEmpty {
                DSChipBar(items: chips, selection: $selectedFilter)
                    .padding(.vertical, DSSpacing.xs)
                    .background(.bar)
            }
        }
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
            importSheetContent
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.zip, .javaScript, .plainText],
                    allowsMultipleSelection: false
                ) { result in
                    Task { await handleImportedFile(result) }
                }
        }
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

    private func sourceRow(_ src: SourceMetaDTO) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Button {
                router.push(.sourceDetail(sourceID: src.id))
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    DSSourceAvatar(name: src.name, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(src.name)
                                .font(DSTypography.rowTitle)
                                .foregroundStyle(src.isEnabled ? DSColors.inkPrimary : DSColors.inkSecondary)
                                .lineLimit(1)
                            if src.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(DSTypography.caption2)
                                    .foregroundStyle(DSColors.accent)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("v\(src.version) · \(src.permissionMode == .compatApproved ? "兼容放行" : "白名单模式")")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(DSColors.inkSecondary)
                            if SourceListHelper.supportsLogin(src) {
                                loginStatusBadge(for: src.id)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { src.isEnabled },
                set: { next in enqueueSourceUpdate(src.id, isEnabled: next, isPinned: nil) }
            ))
            .labelsHidden()
            .tint(DSColors.accent)
            .fixedSize()
            .accessibilityLabel("启用或停用书源 \(src.name)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive) {
                deleteSource(src.id)
            }
            Button {
                DSHaptics.selection()
                enqueueSourceUpdate(src.id, isEnabled: nil, isPinned: !src.isPinned)
            } label: {
                Label(src.isPinned ? "取消置顶" : "置顶", systemImage: src.isPinned ? "pin.slash" : "pin")
            }
            .tint(DSColors.accent)
        }
    }

    @ViewBuilder
    private func loginStatusBadge(for sourceID: String) -> some View {
        switch container.sourceAuth.status(for: sourceID) {
        case .loggedIn:
            DSBadge("已登录", style: .success)
        case .checking:
            DSBadge("检测中", style: .neutral)
        case .loggedOut, .unknown:
            DSBadge("未登录", style: .warning)
        }
    }

    func reload() async {
        await container.ensureSourcesRegistered()
        if let rows = try? await container.persistence.fetchAllSources() {
            sources = rows.map(\.meta)
            await container.sourceAuth.refreshAllLoginCapable(
                sources: sources,
                runtime: container.pluginRuntime
            )
        }
    }

    private func deleteSource(_ id: String) {
        sources.removeAll { $0.id == id }
        let previous = mutationSerialTask
        mutationSerialTask = Task {
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

    private func enqueueSourceUpdate(_ id: String, isEnabled: Bool?, isPinned: Bool?) {
        let nextVer = (mutationVersions[id] ?? 0) &+ 1
        mutationVersions[id] = nextVer
        if let idx = sources.firstIndex(where: { $0.id == id }) {
            let old = sources[idx]
            sources[idx] = SourceMetaDTO(
                id: old.id, name: old.name, version: old.version, author: old.author,
                summary: old.summary, declaredHosts: old.declaredHosts,
                permissionMode: old.permissionMode, methods: old.methods,
                isEnabled: isEnabled ?? old.isEnabled,
                isPinned: isPinned ?? old.isPinned,
                groupName: old.groupName, sortOrder: old.sortOrder, loginURL: old.loginURL
            )
        }
        let previous = mutationSerialTask
        mutationSerialTask = Task {
            _ = await previous?.value
            do {
                try await container.persistence.updateSourceOrganization(id: id, isEnabled: isEnabled, isPinned: isPinned)
                if let all = try? await container.persistence.fetchAllSources() {
                    await container.pluginRuntime.registerSources(all)
                }
                container.notifySourcesChanged()
            } catch {
                banner.show("更新书源状态失败：\(error.localizedDescription)", tone: .error)
            }
            if mutationVersions[id] == nextVer {
                await reload()
            }
        }
    }
}
