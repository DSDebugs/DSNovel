import SwiftUI

struct ShelfToolbar: ToolbarContent {
    let isEditing: Bool
    let allSelected: Bool
    @Binding var sortOrder: ShelfSortOrder
    @Binding var layoutStyle: DiscoverLayoutStyle
    private let onToggleEdit: () -> Void
    private let onToggleSelectAll: () -> Void
    private let onManageCategories: () -> Void
    private let onOpenHistory: () -> Void
    private let onOpenDownloads: () -> Void

    init(
        isEditing: Bool,
        allSelected: Bool,
        sortOrder: Binding<ShelfSortOrder>,
        layoutStyle: Binding<DiscoverLayoutStyle>,
        onToggleEdit: @escaping () -> Void,
        onToggleSelectAll: @escaping () -> Void,
        onManageCategories: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void
    ) {
        self.isEditing = isEditing
        self.allSelected = allSelected
        self._sortOrder = sortOrder
        self._layoutStyle = layoutStyle
        self.onToggleEdit = onToggleEdit
        self.onToggleSelectAll = onToggleSelectAll
        self.onManageCategories = onManageCategories
        self.onOpenHistory = onOpenHistory
        self.onOpenDownloads = onOpenDownloads
    }

    var body: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "取消全选" : "全选", action: onToggleSelectAll)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成", action: onToggleEdit)
                    .fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onToggleEdit) {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityLabel("选择")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序方式", selection: $sortOrder) {
                        ForEach(ShelfSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    Picker("视图布局", selection: $layoutStyle) {
                        Text("网格").tag(DiscoverLayoutStyle.grid)
                        Text("列表").tag(DiscoverLayoutStyle.list)
                    }
                    Divider()
                    Button(action: onManageCategories) {
                        Label("新建分类", systemImage: "folder.badge.plus")
                    }
                    Button(action: onOpenHistory) {
                        Label("全部历史", systemImage: "clock.arrow.circlepath")
                    }
                    Button(action: onOpenDownloads) {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
    }
}
