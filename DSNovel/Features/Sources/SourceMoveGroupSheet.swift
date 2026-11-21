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

    private func submitNewGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let created = sourceStore.createGroup(named: trimmed) {
            newGroupName = ""
            validationError = nil
            moveAndFinish(toGroupID: created.id, groupTitle: created.name)
        } else {
            validationError = "分组名称为空或已存在"
            DSHapticPolicy.fire(.error)
        }
    }

    private func inlineErrorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DSTypography.subtitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(DSTypography.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                validationError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.leading, Spacing.s3)
        .padding(.trailing, Spacing.s1)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.pageHorizontal)
        .padding(.top, Spacing.s2)
        .padding(.bottom, Spacing.s1)
    }

    var body: some View {
        DSSheetScaffold(title: "移动至分组", onClose: onClose) {
            VStack(spacing: 0) {
                if let validationError {
                    inlineErrorBanner(validationError)
                }

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
                                .submitLabel(.done)
                                .onSubmit {
                                    submitNewGroup()
                                }
                            Button("创建并移入") {
                                submitNewGroup()
                            }
                            .foregroundStyle(Color.dsAccent)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .listRowBackground(Color.dsSurfaceCard)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.dsSurfaceGrouped)
                .onChange(of: newGroupName) { _, _ in
                    if validationError != nil { validationError = nil }
                }
            }
            .background(Color.dsSurfaceGrouped)
        }
        .presentationDetents([.medium, .large])
    }
}
