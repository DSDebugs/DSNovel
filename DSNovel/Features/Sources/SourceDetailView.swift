import SwiftUI
import SwiftData

struct SourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let sourceID: String
    let focus: SourceFocus?

    @State private var sourceStore = SourceStore.shared
    @State private var highlightParser = false
    @State private var showDeleteDialog = false
    @State private var showLogoutConfirm = false
    @State private var supportsBuiltinParser = false

    init(sourceID: String, focus: SourceFocus? = nil) {
        self.sourceID = sourceID
        self.focus = focus
    }

    private var source: PluginRecord? {
        sourceStore.source(for: sourceID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if let src = source {
                    detailForm(src, proxy: proxy)
                } else {
                    DSStateView(
                        kind: .empty,
                        titleOverride: "未找到该书源",
                        messageOverride: "该书源可能已被删除或移除"
                    )
                }
            }
        }
        .background(Color.dsSurfaceGrouped)
        .navigationTitle(source?.name ?? "书源详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sourceID) {
            if let src = source {
                supportsBuiltinParser = BuiltinParserSection.isSupportedSource(src)
            }
            await BuiltinParserSection.refreshSupportedSourcesCache()
            if let src = source {
                supportsBuiltinParser = BuiltinParserSection.isSupportedSource(src)
            }
        }
    }

    private func detailForm(_ src: PluginRecord, proxy: ScrollViewProxy) -> some View {
        Form {
            Section {
                HStack {
                    DSSourceBadge(
                        name: src.name,
                        health: DSSourceHealthKind(rawValue: src.lastCheckStatus) ?? .untested,
                        latencyMs: src.lastLatencyMs > 0 ? src.lastLatencyMs : nil
                    )
                    Spacer()
                    Button("检测") {
                        Task { _ = await sourceStore.checkSource(src) }
                    }
                    .disabled(sourceStore.checkingSourceIDs.contains(src.id))
                }
                .listRowBackground(Color.dsSurfaceCard)
                LabeledContent("站点域名", value: src.siteURL)
                    .listRowBackground(Color.dsSurfaceCard)
            }

            if (src.requiresLogin && !src.loggedIn) || (!src.loggedIn && src.healthState == .needAuth) || src.healthState == .unavailable {
                Section("需要处理") {
                    if !src.loggedIn && (src.requiresLogin || src.healthState == .needAuth) {
                        Button("去登录") {
                            AuthCoordinator.shared.presentLogin(forSourceID: src.id)
                        }
                        .foregroundStyle(Color.dsAccent)
                        .listRowBackground(Color.dsSurfaceCard)
                    }
                    if src.healthState == .unavailable {
                        Text(src.lastCheckMessage.isEmpty ? "最近一次检测异常，请点击重新检测" : src.lastCheckMessage)
                            .font(DSTypography.caption)
                            .foregroundStyle(.red)
                            .listRowBackground(Color.dsSurfaceCard)
                    }
                }
            }

            Section("启用与能力") {
                Picker("所属分组", selection: Binding<String>(
                    get: { src.groupID ?? "" },
                    set: { newVal in
                        let targetGroupID = newVal.isEmpty ? nil : newVal
                        sourceStore.moveSources([src.id], toGroupID: targetGroupID)
                    }
                )) {
                    Text("未分组").tag("")
                    ForEach(sourceStore.sortedGroups) { grp in
                        Text(grp.name).tag(grp.id)
                    }
                }
                .listRowBackground(Color.dsSurfaceCard)

                Toggle("启用书源", isOn: Binding(
                    get: { src.isEnabled },
                    set: {
                        src.isEnabled = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
                .listRowBackground(Color.dsSurfaceCard)
                Toggle("置顶书源", isOn: Binding(
                    get: { src.isPinned },
                    set: {
                        src.isPinned = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
                .listRowBackground(Color.dsSurfaceCard)
                Toggle("允许发现浏览", isOn: Binding(
                    get: { src.discoverable },
                    set: {
                        src.discoverable = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
                .listRowBackground(Color.dsSurfaceCard)
                Toggle("允许参与搜索", isOn: Binding(
                    get: { src.searchable },
                    set: {
                        src.searchable = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
                .listRowBackground(Color.dsSurfaceCard)
            }

            if src.requiresLogin {
                Section("账号") {
                    LabeledContent("登录状态", value: src.loggedIn ? "已登录" : "未登录")
                        .listRowBackground(Color.dsSurfaceCard)
                    if src.loggedIn {
                        Button("退出登录", role: .destructive) {
                            showLogoutConfirm = true
                        }
                        .listRowBackground(Color.dsSurfaceCard)
                    } else {
                        Button("去登录") {
                            AuthCoordinator.shared.presentLogin(forSourceID: src.id)
                        }
                        .foregroundStyle(Color.dsAccent)
                        .listRowBackground(Color.dsSurfaceCard)
                    }
                }
            }

            if supportsBuiltinParser || BuiltinParserSection.isSupportedSource(src) {
                Section("内置解析") {
                    BuiltinParserSummaryCard(plugin: src, isHighlighted: highlightParser)
                        .id("builtinParserCard")
                        .listRowBackground(Color.dsSurfaceCard)
                }
            }

            Section("元数据") {
                LabeledContent("包 ID", value: src.packageID)
                    .listRowBackground(Color.dsSurfaceCard)
                LabeledContent("版本", value: src.version)
                    .listRowBackground(Color.dsSurfaceCard)
                if !src.author.isEmpty {
                    LabeledContent("作者", value: src.author)
                        .listRowBackground(Color.dsSurfaceCard)
                }
            }

            Section {
                Button("删除书源", role: .destructive) {
                    showDeleteDialog = true
                }
                .listRowBackground(Color.dsSurfaceCard)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.dsSurfaceGrouped)
        .alert("退出书源账号", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                Task {
                    await sourceStore.logoutSource(src)
                    DSHapticPolicy.fire(.success)
                    BannerCenter.shared.show("已退出登录", kind: .info)
                }
            }
        } message: {
            Text("确认退出该书源账号并清除登录凭证？")
        }
        .background {
            Color.clear
                .alert("删除书源「\(src.name)」", isPresented: $showDeleteDialog) {
                    Button("仅删除书源（保留书架与下载）", role: .destructive) {
                        Task {
                            await sourceStore.deleteSources([src.id], alsoRemoveShelfAndDownloads: false)
                            dismiss()
                        }
                    }
                    Button("同时移除书架与下载", role: .destructive) {
                        Task {
                            await sourceStore.deleteSources([src.id], alsoRemoveShelfAndDownloads: true)
                            dismiss()
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("请选择删除该书源时对关联书架与离线下载的处理方式。")
                }
        }
        .onAppear {
            if focus == .builtinParser || AppRouter.shared.consumePendingParserFocus() == src.id {
                highlightParser = true
                proxy.scrollTo("builtinParserCard", anchor: .center)
            }
        }
    }
}
