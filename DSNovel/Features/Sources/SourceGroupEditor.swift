import SwiftUI

struct SourceGroupEditor: View {
    let sourceStore: SourceStore
    @State private var newGroupName: String = ""
    @State private var renamingGroup: PluginGroup?
    @State private var renameDraft: String = ""
    @State private var pendingDeleteGroup: PluginGroup?
    private let onClose: () -> Void

    init(sourceStore: SourceStore = .shared, onClose: @escaping () -> Void) {
        self.sourceStore = sourceStore
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "管理书源分组", onClose: onClose) {
            List {
                Section("新建分组") {
                    HStack(spacing: Spacing.s2) {
                        TextField("输入分组名称", text: $newGroupName)
                        Button("添加") {
                            if sourceStore.createGroup(named: newGroupName) != nil {
                                newGroupName = ""
                                DSHapticPolicy.fire(.success)
                            } else {
                                DSHapticPolicy.fire(.error)
                                BannerCenter.shared.show("分组名称为空或已存在", kind: .warning)
                            }
                        }
                        .foregroundStyle(Color.dsAccent)
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .listRowBackground(Color.dsSurfaceCard)
                }

                Section {
                    if sourceStore.sortedGroups.isEmpty {
                        Text("暂无自定义分组")
                            .font(DSTypography.caption)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.dsSurfaceCard)
                    } else {
                        ForEach(sourceStore.sortedGroups) { grp in
                            HStack(spacing: Spacing.s3) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(grp.name)
                                        .font(DSTypography.body)
                                        .foregroundStyle(.primary)
                                    Text("\(sourceStore.memberCount(forGroupID: grp.id)) 个书源")
                                        .font(DSTypography.numericCaption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    renamingGroup = grp
                                    renameDraft = grp.name
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(DSTypography.subtitle)
                                        .foregroundStyle(Color.dsAccent)
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("重命名 \(grp.name)")

                                Button(role: .destructive) {
                                    pendingDeleteGroup = grp
                                } label: {
                                    Image(systemName: "trash")
                                        .font(DSTypography.subtitle)
                                        .foregroundStyle(.red)
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除分组 \(grp.name)")
                            }
                            .deleteDisabled(true)
                            .listRowBackground(Color.dsSurfaceCard)
                        }
                        .onMove { offsets, destination in
                            sourceStore.reorderGroups(from: offsets, to: destination)
                            DSHapticPolicy.fire(.selection)
                        }
                    }
                } header: {
                    Text("已有分组")
                } footer: {
                    Text("拖动右侧手柄可调整分组顺序；删除分组后，组内书源将自动归入「未分组」。")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
            .environment(\.editMode, .constant(.active))
        }
        .alert(
            "重命名分组",
            isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            )
        ) {
            TextField("分组名称", text: $renameDraft)
            Button("取消", role: .cancel) { renamingGroup = nil }
            Button("保存") {
                if let target = renamingGroup {
                    if sourceStore.renameGroup(target, to: renameDraft) {
                        DSHapticPolicy.fire(.success)
                    } else {
                        DSHapticPolicy.fire(.error)
                        BannerCenter.shared.show("分组名称为空或已存在", kind: .warning)
                    }
                }
                renamingGroup = nil
            }
        }
        .background {
            Color.clear
                .alert(
                    "删除分组",
                    isPresented: Binding(
                        get: { pendingDeleteGroup != nil },
                        set: { if !$0 { pendingDeleteGroup = nil } }
                    )
                ) {
                    Button("取消", role: .cancel) { pendingDeleteGroup = nil }
                    Button("删除分组", role: .destructive) {
                        if let target = pendingDeleteGroup {
                            sourceStore.deleteGroup(target)
                            DSHapticPolicy.fire(.success)
                        }
                        pendingDeleteGroup = nil
                    }
                } message: {
                    Text("确认删除分组「\(pendingDeleteGroup?.name ?? "")」？该分组下的书源将自动归入「未分组」，不会被删除。")
                }
        }
    }
}
