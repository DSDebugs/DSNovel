import DSCore
import DSDesignSystem
import DSStorage
import SwiftUI

/// 新版书源分组与排序管理弹窗（支持直接新建/改名/删组 + 单源下拉换组 + 拖拽排序，实时持久化）
struct SourceOrganizeSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var model = SourceOrganizeModel()
    @State private var showCreateAlert = false
    @State private var createGroupInput = ""
    @State private var renamingGroupName: String?
    @State private var renameGroupInput = ""
    @State private var pendingDeleteGroupName: String?

    private let initialSources: [SourceMetaDTO]
    private let onSaved: () -> Void
    private let onDismiss: () -> Void

    init(sources: [SourceMetaDTO], onSaved: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.initialSources = sources
        self.onSaved = onSaved
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "分组管理", banner: banner, onDismiss: onDismiss) {
            List {
                Section {
                    ForEach(model.groupNames, id: \.self) { groupName in
                        groupRow(groupName)
                            .listRowBackground(DSColors.surfaceCard)
                            .moveDisabled(groupName == SourceListHelper.defaultGroupName)
                    }
                    .onMove { offsets, dest in
                        let ordered = model.moveGroups(from: offsets, to: dest)
                        DSHaptics.selection()
                        settings.reorderCustomSourceGroups(ordered)
                        onSaved()
                    }
                } header: {
                    HStack(spacing: DSSpacing.sm) {
                        Text("书源分组")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                        Spacer()
                        Text("可拖动排序")
                            .font(DSTypography.caption2)
                            .foregroundStyle(DSColors.inkSecondary)
                        Button {
                            DSHaptics.selection()
                            createGroupInput = ""
                            showCreateAlert = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(DSTypography.caption2.weight(.bold))
                                Text("新建分组")
                                    .font(DSTypography.caption.weight(.semibold))
                            }
                            .foregroundStyle(DSColors.onAccent)
                            .padding(.horizontal, DSSpacing.sm)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DSColors.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    .textCase(nil)
                }

                Section {
                    ForEach(model.allSources) { src in
                        sourceAssignRow(src)
                            .listRowBackground(DSColors.surfaceCard)
                    }
                    .onMove { offsets, dest in
                        model.moveAllSources(from: offsets, to: dest)
                        Task { await persistSilently() }
                    }
                } header: {
                    HStack {
                        Text("书源归属与排序")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                        Spacer()
                        Text("长按右侧拖动排序")
                            .font(DSTypography.caption2)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
            .environment(\.editMode, .constant(.active))
        }
        .alert("新建分组", isPresented: $showCreateAlert) {
            TextField("输入分组名称", text: $createGroupInput)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let clean = createGroupInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if model.createGroup(clean) {
                    settings.addCustomSourceGroup(clean)
                    banner.show("已创建分组「\(clean)」", tone: .success)
                } else if !clean.isEmpty {
                    banner.show("分组名已存在或不可用", tone: .info)
                }
            }
        } message: {
            Text("创建后可随时将书源归入该分组。")
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
                    if model.renameGroup(from: oldName, to: clean) {
                        settings.renameCustomSourceGroup(from: oldName, to: clean)
                        Task { await persistSilently(toast: "已重命名为「\(clean)」") }
                    } else {
                        banner.show("分组名无效或已存在", tone: .info)
                    }
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
                if let target = pendingDeleteGroupName, model.deleteGroup(target) {
                    settings.removeCustomSourceGroup(target)
                    Task { await persistSilently(toast: "已删除分组「\(target)」，书源已归回默认分组") }
                }
                pendingDeleteGroupName = nil
            }
        } message: {
            Text("删除后组内书源不会丢失，将自动移入「默认分组」。")
        }
        .onAppear {
            if model.groupNames.isEmpty {
                model.load(from: initialSources, customGroups: settings.customSourceGroups)
            }
        }
    }

    private func groupRow(_ groupName: String) -> some View {
        let isDefault = (groupName == SourceListHelper.defaultGroupName)
        let count = model.count(inGroup: groupName)

        return HStack(spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(groupName)
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Text("\(count) 个书源")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
            Spacer()
            if isDefault {
                Text("系统默认")
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.inkSecondary)
                    .padding(.horizontal, DSSpacing.xs)
                    .padding(.vertical, 4)
                    .background(Capsule().strokeBorder(DSColors.separator.opacity(0.6), lineWidth: 0.6))
            } else {
                Button {
                    DSHaptics.selection()
                    renamingGroupName = groupName
                    renameGroupInput = groupName
                } label: {
                    Image(systemName: "pencil")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重命名分组 \(groupName)")

                Button {
                    DSHaptics.selection()
                    pendingDeleteGroupName = groupName
                } label: {
                    Image(systemName: "trash")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.danger)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除分组 \(groupName)")
            }
        }
        .frame(minHeight: 44)
    }

    private func sourceAssignRow(_ src: SourceMetaDTO) -> some View {
        let currentGroup = SourceListHelper.normalizedGroupName(src.groupName)
        return HStack(spacing: DSSpacing.sm) {
            DSSourceAvatar(name: src.name, size: 32)
            Text(src.name)
                .font(DSTypography.subheadline.weight(.medium))
                .foregroundStyle(DSColors.inkPrimary)
                .lineLimit(1)
            Spacer()
            Menu {
                ForEach(model.groupNames, id: \.self) { g in
                    Button {
                        DSHaptics.selection()
                        model.assignSource(id: src.id, toGroup: g)
                        Task { await persistSilently() }
                    } label: {
                        HStack {
                            Text(g)
                            if g == currentGroup {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentGroup)
                        .font(DSTypography.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(DSTypography.caption2)
                }
                .foregroundStyle(DSColors.accent)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, 6)
                .background(Capsule().fill(DSColors.accent.opacity(0.14)))
            }
            .tint(DSColors.accent)
        }
        .frame(minHeight: 44)
    }

    private func persistSilently(toast: String? = nil) async {
        let updates = model.flattenedForSave()
        do {
            try await container.persistence.updateSourcesOrganizationBatch(updates)
            let all = try await container.persistence.fetchAllSources()
            await container.pluginRuntime.registerSources(all)
            container.notifySourcesChanged()
            onSaved()
            if let toast {
                banner.show(toast, tone: .success)
            }
        } catch {
            banner.show("保存失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
