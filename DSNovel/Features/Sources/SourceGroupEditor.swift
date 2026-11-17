import SwiftUI
import SwiftData

struct SourceGroupEditor: View {
    @Environment(\.modelContext) private var modelContext
    let sourceStore: SourceStore
    @State private var newGroupName: String = ""
    private let onClose: () -> Void

    init(sourceStore: SourceStore = .shared, onClose: @escaping () -> Void) {
        self.sourceStore = sourceStore
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "管理书源分组", onClose: onClose) {
            List {
                Section("新建分组") {
                    HStack {
                        TextField("输入分组名称", text: $newGroupName)
                        Button("添加") {
                            let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            modelContext.insert(PluginGroup(name: trimmed, order: sourceStore.groups.count))
                            try? modelContext.save()
                            newGroupName = ""
                            sourceStore.refreshNow()
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("已有分组") {
                    ForEach(sourceStore.groups) { grp in
                        HStack {
                            Text(grp.name)
                            Spacer()
                            Button(role: .destructive) {
                                modelContext.delete(grp)
                                try? modelContext.save()
                                sourceStore.refreshNow()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
