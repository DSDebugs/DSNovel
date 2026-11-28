import DSDesignSystem
import Foundation
import SwiftUI

/// 下载管理顶部概览卡（仅展示离线已下载体积、书籍/章数、设备可用空间与队列状态，移除冗余清理预缓存按钮）
struct StorageOverviewCard: View {
    let manualBytes: Int64
    let bookCount: Int
    let completedChapterCount: Int
    let activeCount: Int
    let freeDiskBytes: Int64
    let hasPausedTasks: Bool
    private let onTogglePauseResumeAll: () -> Void

    init(
        manualBytes: Int64,
        bookCount: Int,
        completedChapterCount: Int,
        activeCount: Int,
        freeDiskBytes: Int64,
        hasPausedTasks: Bool,
        onTogglePauseResumeAll: @escaping () -> Void
    ) {
        self.manualBytes = manualBytes
        self.bookCount = bookCount
        self.completedChapterCount = completedChapterCount
        self.activeCount = activeCount
        self.freeDiskBytes = freeDiskBytes
        self.hasPausedTasks = hasPausedTasks
        self.onTogglePauseResumeAll = onTogglePauseResumeAll
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        HStack(alignment: .center, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text("离线已下载")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
                Text(fmt(manualBytes))
                    .font(DSTypography.title.monospacedDigit().weight(.semibold))
                    .foregroundStyle(DSColors.inkPrimary)
                    .contentTransition(.numericText())
                Text("共 \(bookCount) 本 · \(completedChapterCount) 章离线音频")
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(DSColors.inkSecondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text("可用 \(fmt(freeDiskBytes))")
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(DSColors.inkSecondary)

                if activeCount > 0 {
                    Button(action: onTogglePauseResumeAll) {
                        Text(hasPausedTasks ? "继续全部 (\(activeCount))" : "暂停全部 (\(activeCount))")
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DSColors.accent.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("无进行中任务")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DSColors.surfaceGrouped))
                }
            }
        }
        .padding(DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
    }
}
