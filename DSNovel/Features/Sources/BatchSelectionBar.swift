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
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(selectedCount == 0)
            Spacer()
            Button("停用", action: onDisable)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(selectedCount == 0)
            Spacer()
            Button("移组", action: onMoveGroup)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(selectedCount == 0)
            Spacer()
            Button("删除", role: .destructive, action: onDelete)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(selectedCount == 0)
        }
        .font(DSTypography.cardTitle)
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s1)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .padding(.horizontal, Spacing.pageHorizontal)
        .padding(.bottom, Spacing.s2)
    }
}
