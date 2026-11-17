import SwiftUI
import SwiftData
import UIKit

struct SourceListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var sourceStore = SourceStore.shared
    @State private var isBatchMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var showImportSheet = false
    @State private var showGroupEditor = false
    @State private var pendingDeleteSource: PluginRecord?

    init() {}

    private var filterChips: [DSChipItem<SourceListFilter>] {
        let s = sourceStore.healthSummary
        var list: [DSChipItem<SourceListFilter>] = [
            DSChipItem(id: .all, title: "全部", count: s.totalCount),
            DSChipItem(id: .available, title: "可用", count: s.availableCount),
            DSChipItem(id: .needAuth, title: "需登录", count: s.needAuthCount),
            DSChipItem(id: .unavailable, title: "异常", count: s.unavailableCount)
        ]
        if s.untestedCount > 0 {
            list.append(DSChipItem(id: .untested, title: "未检测", count: s.untestedCount))
        }
        if s.stoppedCount > 0 {
            list.append(DSChipItem(id: .disabled, title: "已停用", count: s.stoppedCount))
        }
        return list
    }

    var body: some View {
        Group {
            if sourceStore.allSources.isEmpty {
                DSStateView(
                    kind: .noSource,
                    onPrimary: { showImportSheet = true },
                    onSecondary: nil
                )
            } else {
                List {
                    if !sourceStore.pinnedSources.isEmpty {
                        Section("已置顶") {
                            ForEach(sourceStore.pinnedSources) { src in
                                rowWithActions(src)
                                    .listRowBackground(Color.dsSurfaceCard)
                            }
                        }
                    }

                    Section("书源列表（\(sourceStore.filteredSources.count)）") {
                        ForEach(sourceStore.filteredSources) { src in
                            rowWithActions(src)
                                .listRowBackground(Color.dsSurfaceCard)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.dsSurfaceGrouped)
        .navigationTitle(isBatchMode ? "已选 \(selectedIDs.count) 项" : "书源")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !sourceStore.allSources.isEmpty {
                DSChipBar(
                    items: filterChips,
                    selection: $sourceStore.filter
                )
                .padding(.vertical, Spacing.s2)
                .background(.bar)
            }
        }
        .searchable(text: $sourceStore.searchKeyword, prompt: "搜索书源名称或域名")
        .toolbarVisibility(isBatchMode ? .hidden : .visible, for: .tabBar)
        .toolbar {
            if isBatchMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        isBatchMode = false
                        selectedIDs.removeAll()
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImportSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("导入书源")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("检测全部") {
                            Task { await sourceStore.checkSources() }
                        }
                        Button("批量管理") {
                            isBatchMode = true
                        }
                        Button("管理分组") {
                            showGroupEditor = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isBatchMode {
                BatchSelectionBar(
                    selectedCount: selectedIDs.count,
                    onEnable: {
                        sourceStore.setEnabled(true, forIDs: selectedIDs)
                        isBatchMode = false
                        selectedIDs.removeAll()
                    },
                    onDisable: {
                        sourceStore.setEnabled(false, forIDs: selectedIDs)
                        isBatchMode = false
                        selectedIDs.removeAll()
                    },
                    onMoveGroup: { showGroupEditor = true },
                    onDelete: {
                        let ids = selectedIDs
                        isBatchMode = false
                        selectedIDs.removeAll()
                        Task { await sourceStore.deleteSources(ids) }
                    }
                )
            }
        }
        .sheet(isPresented: $showImportSheet) {
            SourceImportFlow(onClose: { showImportSheet = false })
        }
        .sheet(isPresented: $showGroupEditor) {
            SourceGroupEditor(sourceStore: sourceStore, onClose: { showGroupEditor = false })
        }
        .confirmationDialog(
            "确认删除书源「\(pendingDeleteSource?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteSource != nil },
                set: { if !$0 { pendingDeleteSource = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除书源", role: .destructive) {
                if let target = pendingDeleteSource {
                    pendingDeleteSource = nil
                    Task { await sourceStore.deleteSources([target.id]) }
                }
            }
            Button("取消", role: .cancel) { pendingDeleteSource = nil }
        }
        .onAppear {
            sourceStore.modelContext = modelContext
        }
    }

    private func rowWithActions(_ src: PluginRecord) -> some View {
        SourceRow(
            source: src,
            isChecking: sourceStore.checkingSourceIDs.contains(src.id),
            isBatchSelecting: isBatchMode,
            isSelected: selectedIDs.contains(src.id),
            onSelect: {
                if isBatchMode {
                    if selectedIDs.contains(src.id) {
                        selectedIDs.remove(src.id)
                    } else {
                        selectedIDs.insert(src.id)
                    }
                } else {
                    AppRouter.shared.open(.sourceDetail(id: src.id, focus: nil))
                }
            }
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { _ = await sourceStore.checkSource(src) }
            } label: {
                Label("检测", systemImage: "stethoscope")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeleteSource = src
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                src.isEnabled.toggle()
                try? modelContext.save()
                sourceStore.recomputeDerived()
            } label: {
                Label(src.isEnabled ? "停用" : "启用", systemImage: src.isEnabled ? "pause.circle" : "play.circle")
            }
            Button {
                src.isPinned.toggle()
                try? modelContext.save()
                sourceStore.recomputeDerived()
            } label: {
                Label(src.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(Color.dsAccent)
        }
        .contextMenu {
            Button("检测") { Task { _ = await sourceStore.checkSource(src) } }
            Button(src.isPinned ? "取消置顶" : "置顶") {
                src.isPinned.toggle()
                try? modelContext.save()
                sourceStore.recomputeDerived()
            }
            Button("复制书源地址") {
                UIPasteboard.general.string = src.siteURL
                BannerCenter.shared.show("已复制", kind: .info)
            }
            if src.requiresLogin {
                Button("登录") { AuthCoordinator.shared.presentLogin(forSourceID: src.id) }
            }
            Divider()
            Button("删除", role: .destructive) { pendingDeleteSource = src }
        }
    }
}
