import DSDesignSystem
import Foundation
import SwiftUI

/// 存储空间概览卡片（1:1 复刻 v2.8：已下载 / 预缓存 / 剩余空间 + 清理预缓存胶囊）
struct StorageOverviewCard: View {
    let manualBytes: Int64
    let precacheBytes: Int64
    let freeDiskBytes: Int64
    private let onClearPrecache: () -> Void

    init(
        manualBytes: Int64,
        precacheBytes: Int64,
        freeDiskBytes: Int64,
        onClearPrecache: @escaping () -> Void
    ) {
        self.manualBytes = manualBytes
        self.precacheBytes = precacheBytes
        self.freeDiskBytes = freeDiskBytes
        self.onClearPrecache = onClearPrecache
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("存储概览")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Text("已下载 \(fmt(manualBytes)) · 预缓存 \(fmt(precacheBytes)) · 剩余 \(fmt(freeDiskBytes))")
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
            Spacer()
            if precacheBytes > 0 {
                Button("清理预缓存", action: onClearPrecache)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, DSSpacing.xs)
                    .background(Capsule().fill(DSColors.surfaceGrouped))
                    .buttonStyle(.plain)
            }
        }
        .padding(DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
    }
}
