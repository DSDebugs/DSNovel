import SwiftUI

struct SearchProgressHeader: View {
    let isSearching: Bool
    let completedCount: Int
    let totalCount: Int
    let resultCount: Int
    let elapsedSeconds: Double
    let failedCount: Int
    let pendingHigherRelevanceCount: Int
    private let onStop: () -> Void
    private let onOpenFailedSheet: () -> Void
    private let onResort: () -> Void

    init(
        isSearching: Bool,
        completedCount: Int,
        totalCount: Int,
        resultCount: Int,
        elapsedSeconds: Double,
        failedCount: Int,
        pendingHigherRelevanceCount: Int,
        onStop: @escaping () -> Void,
        onOpenFailedSheet: @escaping () -> Void,
        onResort: @escaping () -> Void
    ) {
        self.isSearching = isSearching
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.resultCount = resultCount
        self.elapsedSeconds = elapsedSeconds
        self.failedCount = failedCount
        self.pendingHigherRelevanceCount = pendingHigherRelevanceCount
        self.onStop = onStop
        self.onOpenFailedSheet = onOpenFailedSheet
        self.onResort = onResort
    }

    var body: some View {
        VStack(spacing: Spacing.s2) {
            HStack {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                    Text("已检索 \(completedCount)/\(totalCount) 个书源 · 找到 \(resultCount) 本")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onStop) {
                        Text("停止")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if totalCount > 0 {
                    Text(String(format: "共 %d 本 · 用时 %.1f 秒", resultCount, elapsedSeconds))
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if failedCount > 0 {
                        Button(action: onOpenFailedSheet) {
                            Text("\(failedCount) 个书源失败 ›")
                                .font(DSTypography.caption.weight(.medium))
                                .foregroundStyle(.orange)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 32)
            .padding(.horizontal, Spacing.pageHorizontal)

            if pendingHigherRelevanceCount > 0 {
                Button(action: onResort) {
                    Text("有 \(pendingHigherRelevanceCount) 条更相关的结果，点按重新排序")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(Color.dsOnAccent)
                        .padding(.horizontal, Spacing.s4)
                        .padding(.vertical, Spacing.s2)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(Color.dsAccent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
