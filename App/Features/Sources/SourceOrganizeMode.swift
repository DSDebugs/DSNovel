import DSCore
import DSDesignSystem
import Observation
import SwiftUI

/// 书源统一整理模式状态模型（组内排序 + 批量移组，独立于 View body）
@Observable
@MainActor
final class SourceOrganizeModel {
    struct GroupBucket: Identifiable {
        let id: String
        var name: String
        var sources: [SourceMetaDTO]
    }

    var groups: [GroupBucket] = []
    var selectedIDs: Set<String> = []
    var newGroupName: String = ""

    func load(from rawSources: [SourceMetaDTO]) {
        let grouped = Dictionary(grouping: rawSources, by: \.groupName)
        groups = grouped
            .map { name, list in
                GroupBucket(id: name, name: name, sources: list.sorted { $0.sortOrder < $1.sortOrder })
            }
            .sorted { $0.name < $1.name }
    }

    func move(inGroup groupID: String, from offsets: IndexSet, to destination: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].sources.move(fromOffsets: offsets, toOffset: destination)
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func moveSelected(toGroup targetGroup: String) {
        let clean = targetGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !selectedIDs.isEmpty else { return }
        var moved: [SourceMetaDTO] = []
        for idx in groups.indices {
            let kept = groups[idx].sources.filter { !selectedIDs.contains($0.id) }
            let picked = groups[idx].sources.filter { selectedIDs.contains($0.id) }
            groups[idx].sources = kept
            moved.append(contentsOf: picked.map {
                SourceMetaDTO(
                    id: $0.id, name: $0.name, version: $0.version, author: $0.author,
                    summary: $0.summary, declaredHosts: $0.declaredHosts,
                    permissionMode: $0.permissionMode, methods: $0.methods,
                    isEnabled: $0.isEnabled, isPinned: $0.isPinned,
                    groupName: clean, sortOrder: $0.sortOrder, loginURL: $0.loginURL
                )
            })
        }
        groups.removeAll { $0.sources.isEmpty }
        if let targetIdx = groups.firstIndex(where: { $0.name == clean }) {
            groups[targetIdx].sources.append(contentsOf: moved)
        } else {
            groups.append(GroupBucket(id: clean, name: clean, sources: moved))
        }
        selectedIDs.removeAll()
    }

    func flattenedForSave() -> [SourceMetaDTO] {
        var out: [SourceMetaDTO] = []
        var order = 0
        for g in groups {
            for s in g.sources {
                out.append(SourceMetaDTO(
                    id: s.id, name: s.name, version: s.version, author: s.author,
                    summary: s.summary, declaredHosts: s.declaredHosts,
                    permissionMode: s.permissionMode, methods: s.methods,
                    isEnabled: s.isEnabled, isPinned: s.isPinned,
                    groupName: g.name, sortOrder: order, loginURL: s.loginURL
                ))
                order += 1
            }
        }
        return out
    }
}

/// 书源统一整理弹窗（支持 .onMove 组内排序 + 批量移组）
struct SourceOrganizeSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var model = SourceOrganizeModel()
    @State private var isSaving = false
    private let initialSources: [SourceMetaDTO]
    private let onSaved: () -> Void
    private let onDismiss: () -> Void

    init(sources: [SourceMetaDTO], onSaved: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.initialSources = sources
        self.onSaved = onSaved
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "整理书源与分组", banner: banner, onDismiss: onDismiss) {
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.xs) {
                    TextField("输入目标分组名", text: $model.newGroupName)
                        .textFieldStyle(.roundedBorder)
                    Button("移入分组") {
                        model.moveSelected(toGroup: model.newGroupName)
                        model.newGroupName = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedIDs.isEmpty || model.newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)

                List {
                    ForEach(model.groups) { bucket in
                        Section(bucket.name) {
                            ForEach(bucket.sources) { src in
                                Button {
                                    model.toggleSelection(src.id)
                                } label: {
                                    HStack {
                                        Image(systemName: model.selectedIDs.contains(src.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(DSColors.accent)
                                        Text(src.name)
                                            .font(DSTypography.subheadline)
                                            .foregroundStyle(DSColors.inkPrimary)
                                        Spacer()
                                    }
                                    .frame(minHeight: 44)
                                }
                                .buttonStyle(.plain)
                            }
                            .onMove { offsets, dest in
                                model.move(inGroup: bucket.id, from: offsets, to: dest)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))

                Button {
                    Task { await persistChanges() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 48)
                    } else {
                        Text("保存排序与分组")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .padding(DSSpacing.md)
            }
        }
        .onAppear {
            if model.groups.isEmpty {
                model.load(from: initialSources)
            }
        }
    }

    private func persistChanges() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let updates = model.flattenedForSave()
        do {
            try await container.persistence.updateSourcesOrganizationBatch(updates)
            let all = try await container.persistence.fetchAllSources()
            await container.pluginRuntime.registerSources(all)
            container.notifySourcesChanged()
            banner.show("书源分组与排序已保存", tone: .success)
            onSaved()
            onDismiss()
        } catch {
            banner.show("保存失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
