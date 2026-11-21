import SwiftUI

struct ShelfSelectionBar: View {
    let selectedCount: Int
    let isDownloadedFilter: Bool
    private let onDownload: () -> Void
    private let onPin: () -> Void
    private let onRemove: () -> Void

    init(
        selectedCount: Int,
        isDownloadedFilter: Bool = false,
        onDownload: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.isDownloadedFilter = isDownloadedFilter
        self.onDownload = onDownload
        self.onPin = onPin
        self.onRemove = onRemove
    }

    var body: some View {
        HStack {
            Button(action: onDownload) {
                Label("下载", systemImage: "arrow.down.circle")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedCount == 0)

            Spacer()

            Button(action: onPin) {
                Label("置顶", systemImage: "pin")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedCount == 0)

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Label(isDownloadedFilter ? "删离线" : "移出", systemImage: "trash")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
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
