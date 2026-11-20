import SwiftUI

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

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text("存储概览")
                    .font(DSTypography.rowTitle)
                Text("已下载 \(fmt(manualBytes)) · 预缓存 \(fmt(precacheBytes)) · 剩余 \(fmt(freeDiskBytes))")
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if precacheBytes > 0 {
                Button("清理预缓存", action: onClearPrecache)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, Spacing.s2)
                    .background(Capsule().fill(Color.dsSurfaceGrouped))
                    .buttonStyle(.plain)
            }
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
    }
}
