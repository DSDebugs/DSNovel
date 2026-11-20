import SwiftUI

struct SourceMoveGroupSheet: View {
    let sourceStore: SourceStore
    let selectedIDs: Set<String>
    private let onMoved: (String) -> Void
    private let onClose: () -> Void

    @State private var newGroupName: String = ""
    @State private var validationError: String?

    init(
        sourceStore: SourceStore = .shared,
        selectedIDs: Set<String>,
        onMoved: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.sourceStore = sourceStore
        self.selectedIDs = selectedIDs
        self.onMoved = onMoved
        self.onClose = onClose
    }

    private func moveAndFinish(toGroupID groupID: String?, groupTitle: String) {
        sourceStore.moveSources(selectedIDs, toGroupID: groupID)
        DSHapticPolicy.fire(.success)
        onMoved(groupTitle)
        onClose()
    }

    var body: some View {
        DSSheetScaffold(title: "移动至分组", onClose: onClose) {
            List {
                Section {
                    ForEach(sourceStore.sortedGroups) { grp in
                        Button {
                            moveAndFinish(toGroupID: grp.id, groupTitle: grp.name)
                        } label: {
                            HStack {
                                Text(grp.name)
                                    .font(DSTypography.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(sourceStore.memberCount(forGroupID: grp.id))")
                                    .font(DSTypography.numericCaption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.dsSurfaceCard)
                    }

                    Button {
                        moveAndFinish(toGroupID: nil, groupTitle: "未分组")
                    } label: {
                        HStack {
                            Text("未分组")
                                .font(DSTypography.body)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(sourceStore.memberCount(forGroupID: nil))")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.dsSurfaceCard)
                } header: {
                    Text("将已选的 \(selectedIDs.count) 个书源移至")
                }

                Section("新建分组并移入") {
                    HStack(spacing: Spacing.s2) {
                        TextField("输入新分组名称", text: $newGroupName)
                        Button("创建并移入") {
                            if let created = sourceStore.createGroup(named: newGroupName) {
                                newGroupName = ""
                                validationError = nil
                                moveAndFinish(toGroupID: created.id, groupTitle: created.name)
                            } else {
                                validationError = "分组名称为空或已存在"
                                DSHapticPolicy.fire(.error)
                                BannerCenter.shared.show("分组名称为空或已存在", kind: .warning)
                            }
                        }
                        .foregroundStyle(Color.dsAccent)
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .listRowBackground(Color.dsSurfaceCard)

                    if let validationError {
                        Text(validationError)
                            .font(DSTypography.caption)
                            .foregroundStyle(.red)
                            .listRowBackground(Color.dsSurfaceCard)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
            .onChange(of: newGroupName) { _, _ in
                if validationError != nil { validationError = nil }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
