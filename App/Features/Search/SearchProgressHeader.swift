import DSDesignSystem
import SwiftUI

/// 搜索进度与统计顶栏（1:1 复刻 v2.8 SearchProgressHeader：检索中显示进度与停止按钮，完成后显示总数/耗时及失败书源入口）
struct SearchProgressHeader: View {
    let isSearching: Bool
    let completedCount: Int
    let totalCount: Int
    let resultCount: Int
    let elapsedSeconds: Double
    let failedCount: Int
    private let onStop: () -> Void
    private let onOpenFailedSheet: () -> Void

    init(
        isSearching: Bool,
        completedCount: Int,
        totalCount: Int,
        resultCount: Int,
        elapsedSeconds: Double,
        failedCount: Int,
        onStop: @escaping () -> Void,
        onOpenFailedSheet: @escaping () -> Void
    ) {
        self.isSearching = isSearching
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.resultCount = resultCount
        self.elapsedSeconds = elapsedSeconds
        self.failedCount = failedCount
        self.onStop = onStop
        self.onOpenFailedSheet = onOpenFailedSheet
    }

    var body: some View {
        HStack {
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                Text("已检索 \(completedCount)/\(totalCount) 个书源 · 找到 \(resultCount) 本")
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(DSColors.inkSecondary)
                Spacer()
                Button(action: onStop) {
                    Text("停止")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if totalCount > 0 {
                Text(String(format: "共 %d 本 · 用时 %.1f 秒", resultCount, elapsedSeconds))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(DSColors.inkSecondary)
                Spacer()
                if failedCount > 0 {
                    Button(action: onOpenFailedSheet) {
                        Text("\(failedCount) 个书源失败 ›")
                            .font(DSTypography.caption.weight(.medium))
                            .foregroundStyle(DSColors.warning)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }
}
