import SwiftUI

struct BatchSelectionBar: View {
    let selectedCount: Int
    private let onEnable: () -> Void
    private let onDisable: () -> Void
    private let onMoveGroup: () -> Void
    private let onDelete: () -> Void

    init(
        selectedCount: Int,
        onEnable: @escaping () -> Void,
        onDisable: @escaping () -> Void,
        onMoveGroup: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.onEnable = onEnable
        self.onDisable = onDisable
        self.onMoveGroup = onMoveGroup
        self.onDelete = onDelete
    }

    var body: some View {
        HStack {
            Button("启用", action: onEnable)
                .disabled(selectedCount == 0)
            Spacer()
            Button("停用", action: onDisable)
                .disabled(selectedCount == 0)
            Spacer()
            Button("移组", action: onMoveGroup)
                .disabled(selectedCount == 0)
            Spacer()
            Button("删除", role: .destructive, action: onDelete)
                .disabled(selectedCount == 0)
        }
        .font(DSTypography.cardTitle)
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s3)
        .background(.regularMaterial)
    }
}
