import DSCore
import DSDesignSystem
import SwiftUI

/// 播放页章节目录单行组件（精修版：在播圆角高亮卡 + 无冗余副标题 + 行尾绿色已下载钩 / 透明圆形单章下载钮）
struct ChapterListRow: View {
    let row: IndexedChapterRow
    let isCurrent: Bool
    let isPlaying: Bool
    let record: DownloadRecordSnapshot?
    let isLast: Bool
    private let onSelect: () -> Void
    private let onDownload: () -> Void

    init(
        row: IndexedChapterRow,
        isCurrent: Bool,
        isPlaying: Bool,
        record: DownloadRecordSnapshot?,
        isLast: Bool,
        onSelect: @escaping () -> Void,
        onDownload: @escaping () -> Void = {}
    ) {
        self.row = row
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.record = record
        self.isLast = isLast
        self.onSelect = onSelect
        self.onDownload = onDownload
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

    private var isCompleted: Bool { record?.state == .completed }

    private var isInProgress: Bool {
        guard let state = record?.state else { return false }
        return state == .queued || state == .resolving || state == .downloading
    }

    var body: some View {
        let sizeText = isCompleted
            ? (record.map { Self.formatFileSize($0.totalBytes > 0 ? $0.totalBytes : $0.downloadedBytes) } ?? "")
            : ""
        let qualityText = isCompleted ? (record?.qualityTier.displayName ?? "") : ""

        VStack(spacing: 0) {
            HStack(spacing: DSSpacing.xs) {
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

                            if isCurrent || isCompleted || isInProgress {
                                metaSubtitle(sizeText: sizeText, qualityText: qualityText)
                            }
                        }

                        if isCurrent {
                            DSEqualizer(isPlaying: isPlaying)
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                trailingDownloadControl
            }
            .padding(.leading, isCurrent ? 10 : DSSpacing.pageHorizontal)
            .padding(.trailing, isCurrent ? 8 : 10)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DSColors.accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(DSColors.accent.opacity(0.32), lineWidth: 0.8)
                        )
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(DSColors.accent)
                                .frame(width: 3)
                                .padding(.vertical, 8)
                                .padding(.leading, 2)
                        }
                }
            }
            .padding(.horizontal, isCurrent ? 8 : 0)
            .padding(.vertical, isCurrent ? 3 : 0)

            if !isLast && !isCurrent {
                Divider()
                    .overlay(DSColors.separator.opacity(0.24))
                    .padding(.leading, 58)
            }
        }
    }

    @ViewBuilder
    private var trailingDownloadControl: some View {
        if isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .font(DSTypography.title)
                .foregroundStyle(DSColors.success)
                .frame(width: 38, height: 38)
                .accessibilityLabel("已下载")
        } else if isInProgress {
            ZStack {
                Circle()
                    .strokeBorder(DSColors.accent.opacity(0.35), lineWidth: 1)
                    .frame(width: 24, height: 24)
                ProgressView()
                    .controlSize(.mini)
                    .tint(DSColors.accent)
            }
            .frame(width: 38, height: 38)
            .accessibilityLabel("下载中")
        } else {
            Button(action: onDownload) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.03))
                        .frame(width: 24, height: 24)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.9)
                        .frame(width: 24, height: 24)
                    Image(systemName: "arrow.down")
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(DSColors.inkSecondary)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下载本章")
        }
    }

    private func metaSubtitle(sizeText: String, qualityText: String) -> some View {
        let items = subtitleParts(sizeText: sizeText, qualityText: qualityText)
        return Text(items.joined(separator: " · "))
            .font(DSTypography.caption2.monospacedDigit())
            .foregroundStyle(isCurrent ? DSColors.accent.opacity(0.90) : DSColors.inkSecondary)
            .lineLimit(1)
    }

    private func subtitleParts(sizeText: String, qualityText: String) -> [String] {
        var parts: [String] = []
        if isCurrent {
            parts.append(isPlaying ? "播放中" : "当前暂停")
        }
        if isCompleted {
            if !sizeText.isEmpty {
                parts.append(sizeText)
            } else if !isCurrent {
                parts.append("已下载")
            }
            if !qualityText.isEmpty && qualityText != "自适应" {
                parts.append(qualityText)
            }
        } else if isInProgress {
            parts.append("下载中")
        }
        return parts
    }
}
