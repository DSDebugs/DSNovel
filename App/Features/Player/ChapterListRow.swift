import DSCore
import DSDesignSystem
import SwiftUI

/// 播放页章节目录单行组件（支持在播微暖高亮 + 左侧赤陶竖条 + 绿色离线勾选 + 体积与简洁音质标）
struct ChapterListRow: View {
    let row: IndexedChapterRow
    let isCurrent: Bool
    let isPlaying: Bool
    let record: DownloadRecordSnapshot?
    let isLast: Bool
    private let onSelect: () -> Void

    init(
        row: IndexedChapterRow,
        isCurrent: Bool,
        isPlaying: Bool,
        record: DownloadRecordSnapshot?,
        isLast: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.row = row
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.record = record
        self.isLast = isLast
        self.onSelect = onSelect
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.2fGB", mb / 1024.0)
        }
        if mb >= 0.1 {
            return String(format: "%.1fMB", mb)
        }
        let kb = max(1, Int((Double(bytes) / 1024.0).rounded()))
        return "\(kb)KB"
    }

    var body: some View {
        let sizeText = record.map { Self.formatFileSize($0.totalBytes > 0 ? $0.totalBytes : $0.downloadedBytes) } ?? ""
        let qualityText = record?.qualityTier.displayName ?? ""

        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: DSSpacing.sm) {
                    Text("\(row.physicalIndex + 1)")
                        .font(DSTypography.numericCaption.weight(isCurrent ? .bold : .regular))
                        .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkSecondary)
                        .frame(width: 34, alignment: .center)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.chapter.title)
                            .font(DSTypography.subheadline.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if isCurrent || record != nil {
                            metaSubtitle(isDownloaded: record != nil, sizeText: sizeText, qualityText: qualityText)
                        }
                    }

                    if isCurrent {
                        DSEqualizer(isPlaying: isPlaying)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .padding(.vertical, 11)
                .background(isCurrent ? DSColors.accent.opacity(0.11) : Color.clear)
                .overlay(alignment: .leading) {
                    if isCurrent {
                        Capsule()
                            .fill(DSColors.accent)
                            .frame(width: 3)
                            .padding(.vertical, 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider()
                    .overlay(DSColors.separator.opacity(0.24))
                    .padding(.leading, 58)
            }
        }
    }

    private func metaSubtitle(isDownloaded: Bool, sizeText: String, qualityText: String) -> some View {
        HStack(spacing: 5) {
            if isCurrent {
                Text(isPlaying ? "播放中" : "当前暂停")
                    .foregroundStyle(DSColors.accent.opacity(0.90))
            }
            if isDownloaded {
                if isCurrent {
                    Text("·")
                        .foregroundStyle(DSColors.inkSecondary)
                }
                Image(systemName: "checkmark.circle.fill")
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.success)
                if !sizeText.isEmpty {
                    Text(sizeText)
                        .foregroundStyle(DSColors.inkSecondary)
                } else if !isCurrent {
                    Text("已下载")
                        .foregroundStyle(DSColors.inkSecondary)
                }
                if !qualityText.isEmpty && qualityText != "自适应" {
                    Text("· \(qualityText)")
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
        }
        .font(DSTypography.caption2.monospacedDigit())
        .lineLimit(1)
    }
}
