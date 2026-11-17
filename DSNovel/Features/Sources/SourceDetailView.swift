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
                    DSStateView(kind: .empty)
                }
            }
        }
        .navigationTitle(source?.name ?? "书源详情")
        .navigationBarTitleDisplayMode(.inline)
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
                LabeledContent("站点域名", value: src.siteURL)
            }

            if (src.requiresLogin && !src.loggedIn) || src.healthState == .needAuth || src.healthState == .unavailable {
                Section("需要处理") {
                    if src.requiresLogin && !src.loggedIn || src.healthState == .needAuth {
                        Button("去登录") {
                            AuthCoordinator.shared.presentLogin(forSourceID: src.id)
                        }
                        .foregroundStyle(Color.dsAccent)
                    }
                    if src.healthState == .unavailable {
                        Text(src.lastCheckMessage.isEmpty ? "最近一次检测异常，请点击重新检测" : src.lastCheckMessage)
                            .font(DSTypography.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("启用与能力") {
                Toggle("启用书源", isOn: Binding(
                    get: { src.isEnabled },
                    set: {
                        src.isEnabled = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
                Toggle("置顶书源", isOn: Binding(
                    get: { src.isPinned },
                    set: {
                        src.isPinned = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
                Toggle("允许发现浏览", isOn: Binding(
                    get: { src.discoverable },
                    set: {
                        src.discoverable = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
                Toggle("允许参与搜索", isOn: Binding(
                    get: { src.searchable },
                    set: {
                        src.searchable = $0
                        try? modelContext.save()
                        sourceStore.recomputeDerived()
                    }
                ))
            }

            if src.requiresLogin {
                Section("账号") {
                    LabeledContent("登录状态", value: src.loggedIn ? "已登录" : "未登录")
                    Button("去登录") {
                        AuthCoordinator.shared.presentLogin(forSourceID: src.id)
                    }
                    if src.loggedIn {
                        Button("退出登录", role: .destructive) {
                            showLogoutConfirm = true
                        }
                    }
                }
            }

            if BuiltinParserSection.isSupportedSource(src) {
                Section("内置解析") {
                    BuiltinParserSummaryCard(plugin: src, isHighlighted: highlightParser)
                        .id("builtinParserCard")
                }
            }

            Section("元数据") {
                LabeledContent("包 ID", value: src.packageID)
                LabeledContent("版本", value: src.version)
                if !src.author.isEmpty {
                    LabeledContent("作者", value: src.author)
                }
            }

            Section {
                Button("删除书源", role: .destructive) {
                    showDeleteDialog = true
                }
            }
        }
        .confirmationDialog("确认退出该书源账号并清除登录凭证？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                CookieSync.setVerifiedLogin(sourceID: src.id, nickname: nil)
                src.loggedIn = false
                try? modelContext.save()
                sourceStore.recomputeDerived()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除「\(src.name)」时，是否同时移除该书源下的书架与下载条目？",
            isPresented: $showDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("仅删除书源（保留书架与下载）", role: .destructive) {
                Task {
                    await sourceStore.deleteSources([src.id], alsoRemoveShelfAndDownloads: false)
                    dismiss()
                }
            }
            Button("同时移除该书源的书架与下载", role: .destructive) {
                Task {
                    await sourceStore.deleteSources([src.id], alsoRemoveShelfAndDownloads: true)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            if focus == .builtinParser || AppRouter.shared.consumePendingParserFocus() == src.id {
                highlightParser = true
                proxy.scrollTo("builtinParserCard", anchor: .center)
            }
        }
    }
}
