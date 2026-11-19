import SwiftUI
import SwiftData
import UIKit

struct SourceListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var sourceStore = SourceStore.shared
    @State private var isOrganizing = false
    @State private var selectedIDs: Set<String> = []
    @State private var showImportSheet = false
    @State private var showGroupEditor = false
    @State private var showMoveGroupSheet = false
    @State private var showBatchDeleteConfirm = false
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

    private var groupedSections: [GroupedSourceSection] {
        sourceStore.groupedSections(from: sourceStore.filteredSources, includeEmptyGroups: true)
    }

    private var organizeRows: [SourceOrganizeRow] {
        sourceStore.buildOrganizeRows()
    }

    private var allOrganizeSelected: Bool {
        !sourceStore.allSources.isEmpty && selectedIDs.count == sourceStore.allSources.count
    }

    private var navigationTitleText: String {
        if isOrganizing {
            return selectedIDs.isEmpty ? "整理书源" : "已选 \(selectedIDs.count) 项"
        }
        return "书源"
    }

    var body: some View {
        Group {
            if sourceStore.allSources.isEmpty {
                DSStateView(
                    kind: .noSource,
                    onPrimary: { showImportSheet = true },
                    onSecondary: nil
                )
            } else if isOrganizing {
                organizeListView
            } else {
                browseListView
            }
        }
        .background(Color.dsSurfaceGrouped)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !sourceStore.allSources.isEmpty && !isOrganizing {
                DSChipBar(
                    items: filterChips,
                    selection: $sourceStore.filter
                )
                .padding(.vertical, Spacing.s2)
                .background(.bar)
            }
        }
        .searchable(text: $sourceStore.searchKeyword, prompt: "搜索书源名称或域名")
        .onChange(of: isOrganizing) { _, organizing in
            AppRouter.shared.isBottomBarHidden = organizing
            if organizing {
                sourceStore.filter = .all
                sourceStore.searchKeyword = ""
            } else {
                selectedIDs.removeAll()
            }
        }
        .toolbar {
            if isOrganizing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allOrganizeSelected ? "取消全选" : "全选") {
                        if allOrganizeSelected {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(sourceStore.allSources.map(\.id))
                        }
                        DSHapticPolicy.fire(.selection)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        isOrganizing = false
                        selectedIDs.removeAll()
                    }
                    .fontWeight(.semibold)
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
                        Button {
                            Task { await sourceStore.checkSources() }
                        } label: {
                            Label("检测全部", systemImage: "stethoscope")
                        }
                        Button {
                            isOrganizing = true
                        } label: {
                            Label("整理书源", systemImage: "arrow.up.arrow.down")
                        }
                        Button {
                            showGroupEditor = true
                        } label: {
                            Label("管理分组", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isOrganizing {
                BatchSelectionBar(
                    selectedCount: selectedIDs.count,
                    onEnable: {
                        sourceStore.setEnabled(true, forIDs: selectedIDs)
                        selectedIDs.removeAll()
                        DSHapticPolicy.fire(.success)
                        BannerCenter.shared.show("已启用选中书源", kind: .success)
                    },
                    onDisable: {
                        sourceStore.setEnabled(false, forIDs: selectedIDs)
                        selectedIDs.removeAll()
                        DSHapticPolicy.fire(.success)
                        BannerCenter.shared.show("已停用选中书源", kind: .info)
                    },
                    onMoveGroup: { showMoveGroupSheet = true },
                    onDelete: { showBatchDeleteConfirm = true }
                )
            }
        }
        .sheet(isPresented: $showImportSheet) {
            SourceImportFlow(onClose: { showImportSheet = false })
        }
        .sheet(isPresented: $showGroupEditor) {
            SourceGroupEditor(sourceStore: sourceStore, onClose: { showGroupEditor = false })
        }
        .sheet(isPresented: $showMoveGroupSheet) {
            SourceMoveGroupSheet(
                sourceStore: sourceStore,
                selectedIDs: selectedIDs,
                onMoved: { groupTitle in
                    selectedIDs.removeAll()
                    BannerCenter.shared.show("已移至「\(groupTitle)」", kind: .success)
                },
                onClose: { showMoveGroupSheet = false }
            )
        }
        .alert(
            "删除书源",
            isPresented: Binding(
                get: { pendingDeleteSource != nil },
                set: { if !$0 { pendingDeleteSource = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingDeleteSource = nil }
            Button("删除书源", role: .destructive) {
                if let target = pendingDeleteSource {
                    pendingDeleteSource = nil
                    Task { await sourceStore.deleteSources([target.id]) }
                }
            }
        } message: {
            Text("确认删除书源「\(pendingDeleteSource?.name ?? "")」？")
        }
        .background {
            Color.clear
                .alert("删除已选书源", isPresented: $showBatchDeleteConfirm) {
                    Button("取消", role: .cancel) {}
                    Button("删除 \(selectedIDs.count) 个书源", role: .destructive) {
                        let ids = selectedIDs
                        selectedIDs.removeAll()
                        Task {
                            await sourceStore.deleteSources(ids)
                            DSHapticPolicy.fire(.success)
                            BannerCenter.shared.show("已删除 \(ids.count) 个书源", kind: .info)
                        }
                    }
                } message: {
                    Text("确认删除已选的 \(selectedIDs.count) 个书源？书架与下载记录将保留。")
                }
        }
        .onAppear {
            sourceStore.modelContext = modelContext
        }
        .onDisappear {
            if isOrganizing {
                AppRouter.shared.isBottomBarHidden = false
            }
        }
    }

    // MARK: - 整理模式（支持按住上下拖动改顺序与跨分组 + 勾选批量操作）

    private var organizeListView: some View {
        let rows = organizeRows
        return List {
            Section {
                ForEach(rows) { row in
                    switch row {
                    case .groupHeader(_, let title, let count):
                        HStack {
                            Text(title)
                                .font(DSTypography.cardTitle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(count)")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, Spacing.s2)
                        .padding(.bottom, 2)
                        .listRowBackground(Color.dsSurfaceGrouped)
                        .listRowSeparator(.hidden)
                        .moveDisabled(true)
                        .deleteDisabled(true)

                    case .source(let src):
                        SourceRow(
                            source: src,
                            isChecking: sourceStore.checkingSourceIDs.contains(src.id),
                            isBatchSelecting: true,
                            isSelected: selectedIDs.contains(src.id),
                            onSelect: {
                                if selectedIDs.contains(src.id) {
                                    selectedIDs.remove(src.id)
                                } else {
                                    selectedIDs.insert(src.id)
                                }
                                DSHapticPolicy.fire(.selection)
                            }
                        )
                        .listRowBackground(Color.dsSurfaceCard)
                        .deleteDisabled(true)
                    }
                }
                .onMove { offsets, destination in
                    sourceStore.applyOrganizeMove(rows: rows, from: offsets, to: destination)
                    DSHapticPolicy.fire(.selection)
                }
            } header: {
                Text("按住书源或右侧手柄上下拖动即可调整顺序与所属分组，点按勾选可批量操作")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - 日常浏览模式

    private var browseListView: some View {
        List {
            if !sourceStore.pinnedSources.isEmpty {
                Section("已置顶") {
                    ForEach(sourceStore.pinnedSources) { src in
                        browseRow(src)
                            .listRowBackground(Color.dsSurfaceCard)
                    }
                }
            }

            ForEach(groupedSections) { section in
                Section {
                    if section.sources.isEmpty {
                        Text("暂无书源，可在「整理书源」中拖入此分组")
                            .font(DSTypography.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Spacing.s2)
                            .listRowBackground(Color.dsSurfaceCard)
                    } else {
                        ForEach(section.sources) { src in
                            browseRow(src)
                                .listRowBackground(Color.dsSurfaceCard)
                        }
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text("\(section.sources.count)")
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, Spacing.s4, for: .scrollContent)
    }

    private func browseRow(_ src: PluginRecord) -> some View {
        SourceRow(
            source: src,
            isChecking: sourceStore.checkingSourceIDs.contains(src.id),
            isBatchSelecting: false,
            isSelected: false,
            onSelect: {
                AppRouter.shared.open(.sourceDetail(id: src.id, focus: nil))
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
    }
}
