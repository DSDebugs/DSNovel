import DSDesignSystem
import SwiftUI

/// 书架编辑态底部液态玻璃胶囊操作栏（1:1 复刻 v2.8：下载 / 置顶 / 移出）
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
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.xxs)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.bottom, DSSpacing.xs)
    }
}
