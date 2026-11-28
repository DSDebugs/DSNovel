import DSCore
import DSDesignSystem
import DSPluginKit
import DSStorage
import SwiftUI
import UniformTypeIdentifiers

/// 新版书源管理主界面（精炼一句话简介外置 + 分组头快捷改名/删组 + 顶栏「分组」与「+」收拢）
struct SourceListView: View {
    @Environment(AppContainer.self) var container
    @Environment(AppRouter.self) var router
    @Environment(AppSettingsStore.self) var settings
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

    @State var renamingGroupName: String?
    @State var renameGroupInput = ""
    @State var pendingDeleteGroupName: String?
    @State var healthEngine = SourceHealthCheckEngine()

    var body: some View {
        let loggedInIDs = container.sourceAuth.loggedInSourceIDs
        let invalidIDs = healthEngine.invalidSourceIDs
        let chips = SourceListHelper.makeFilterChips(
            from: sources,
            loggedInSourceIDs: loggedInIDs,
            invalidSourceIDs: invalidIDs
        )
        let partition = SourceListHelper.partition(
            sources: sources,
            filter: selectedFilter,
            loggedInSourceIDs: loggedInIDs,
            invalidSourceIDs: invalidIDs,
            customGroups: settings.customSourceGroups
        )
        let availableGroups = SourceListHelper.allGroupNames(sources: sources, customGroups: settings.customSourceGroups)

        List {
            if sources.isEmpty {
                Section("已安装书源（0）") {
                    Text("暂无书源，可点击右上角「+」导入或恢复内置书源。")
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
                ForEach(partition.grouped) { section in
                    Section {
                        ForEach(section.sources) { src in
                            sourceRow(src, availableGroups: availableGroups)
                                .listRowBackground(DSColors.surfaceCard)
                        }
                    } header: {
                        groupSectionHeader(section)
                    }
                }
            }
        }
        .accessibilityIdentifier("source_list_root")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("书源管理")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !sources.isEmpty {
                VStack(spacing: 0) {
                    DSChipBar(items: chips, selection: $selectedFilter)
                        .padding(.vertical, DSSpacing.xs)
                    healthStatusBanner
                }
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    Button {
                        DSHaptics.selection()
                        if healthEngine.isRunning {
                            healthEngine.cancel()
                        } else {
                            runBatchHealthCheck()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: healthEngine.isRunning ? "stop.circle" : "waveform.path.ecg")
                                .font(DSTypography.caption)
                            Text(healthEngine.isRunning ? "停止" : "检测")
                                .font(DSTypography.subheadline)
                        }
                        .foregroundStyle(DSColors.accent)
                        .frame(minHeight: 44)
                    }
                    .disabled(sources.isEmpty)
                    .accessibilityIdentifier("source_list_health_check_button")
                    .accessibilityLabel(healthEngine.isRunning ? "停止检测书源" : "一键检测全部书源")

                    Button {
                        DSHaptics.selection()
                        showOrganizeSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(DSTypography.caption)
                            Text("分组")
                                .font(DSTypography.subheadline)
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(sources.isEmpty)

                    Menu {
                        Button {
                            showImportSheet = true
                        } label: {
                            Label("导入第三方书源", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            Task { await resetBundledSources() }
                        } label: {
                            Label("恢复内置书源", systemImage: "arrow.clockwise")
                        }
                        .disabled(isSeedingSources)
                    } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: 36, minHeight: 44)
                    }
                    .accessibilityLabel("更多书源操作")
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
        .alert(
            "重命名分组",
            isPresented: Binding(
                get: { renamingGroupName != nil },
                set: { if !$0 { renamingGroupName = nil } }
            )
        ) {
            TextField("输入新分组名称", text: $renameGroupInput)
            Button("取消", role: .cancel) { renamingGroupName = nil }
            Button("保存") {
                if let oldName = renamingGroupName {
                    let clean = renameGroupInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await renameGroupInline(from: oldName, to: clean) }
                }
                renamingGroupName = nil
            }
        }
        .alert(
            "删除分组",
            isPresented: Binding(
                get: { pendingDeleteGroupName != nil },
                set: { if !$0 { pendingDeleteGroupName = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingDeleteGroupName = nil }
            Button("删除", role: .destructive) {
                if let target = pendingDeleteGroupName {
                    Task { await deleteGroupInline(target) }
                }
                pendingDeleteGroupName = nil
            }
        } message: {
            Text("删除后组内书源不会丢失，将自动移入「默认分组」。")
        }
        .onChange(of: container.sourcesRevision) { _, _ in
            Task { await reload() }
        }
        .task { await reload() }
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
}
