import DSStorage
import SwiftUI

/// 书架导航栏工具条（1:1 复刻 v2.8：checkmark.circle + ellipsis.circle 菜单含排序/网格列表切换/全部历史/下载管理）
struct ShelfToolbar: ToolbarContent {
    let isEditing: Bool
    let allSelected: Bool
    let isShelfEmpty: Bool
    let isDownloadedFilter: Bool
    @Binding var sortOrder: ShelfSortOrder
    @Binding var layoutStyle: ShelfLayoutMode
    private let onToggleEdit: () -> Void
    private let onToggleSelectAll: () -> Void
    private let onOpenHistory: () -> Void
    private let onOpenDownloads: () -> Void

    init(
        isEditing: Bool,
        allSelected: Bool,
        isShelfEmpty: Bool = false,
        isDownloadedFilter: Bool = false,
        sortOrder: Binding<ShelfSortOrder>,
        layoutStyle: Binding<ShelfLayoutMode>,
        onToggleEdit: @escaping () -> Void,
        onToggleSelectAll: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void
    ) {
        self.isEditing = isEditing
        self.allSelected = allSelected
        self.isShelfEmpty = isShelfEmpty
        self.isDownloadedFilter = isDownloadedFilter
        self._sortOrder = sortOrder
        self._layoutStyle = layoutStyle
        self.onToggleEdit = onToggleEdit
        self.onToggleSelectAll = onToggleSelectAll
        self.onOpenHistory = onOpenHistory
        self.onOpenDownloads = onOpenDownloads
    }

    var body: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "取消全选" : "全选", action: onToggleSelectAll)
                    .frame(minHeight: 44)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成", action: onToggleEdit)
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onToggleEdit) {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(isShelfEmpty)
                .accessibilityLabel("选择")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序方式", selection: $sortOrder) {
                        ForEach(ShelfSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    if isDownloadedFilter {
                        Button {} label: {
                            Label("列表（已下载筛选固定）", systemImage: "list.bullet")
                        }
                        .disabled(true)
                    } else {
                        Picker("视图布局", selection: $layoutStyle) {
                            Text("网格").tag(ShelfLayoutMode.grid)
                            Text("列表").tag(ShelfLayoutMode.list)
                        }
                    }
                    Divider()
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
