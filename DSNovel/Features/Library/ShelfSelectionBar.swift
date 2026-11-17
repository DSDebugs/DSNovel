import SwiftUI

struct ShelfSelectionBar: View {
    let selectedCount: Int
    private let onMove: () -> Void
    private let onDownload: () -> Void
    private let onPin: () -> Void
    private let onRemove: () -> Void

    init(
        selectedCount: Int,
        onMove: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.onMove = onMove
        self.onDownload = onDownload
        self.onPin = onPin
        self.onRemove = onRemove
    }

    var body: some View {
        HStack {
            Button(action: onMove) {
                Label("移动", systemImage: "folder")
            }
            .disabled(selectedCount == 0)

            Spacer()

            Button(action: onDownload) {
                Label("下载", systemImage: "arrow.down.circle")
            }
            .disabled(selectedCount == 0)

            Spacer()

            Button(action: onPin) {
                Label("置顶", systemImage: "pin")
            }
            .disabled(selectedCount == 0)

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Label("移出", systemImage: "trash")
            }
            .disabled(selectedCount == 0)
        }
        .font(DSTypography.cardTitle)
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s3)
        .background(.regularMaterial)
    }
}
