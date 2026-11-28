import DSCore
import DSDesignSystem
import SwiftUI

/// 播放页章节目录单行组件（无框精密等宽序号 + 按位数自适应紧凑列宽 + 柔和在播高亮卡 + 行尾已下载钩 / 单章下载钮）
struct ChapterListRow: View {
    let row: IndexedChapterRow
    let isCurrent: Bool
    let isPlaying: Bool
    let record: DownloadRecordSnapshot?
    let isLast: Bool
    let indexColumnWidth: CGFloat
    private let onSelect: () -> Void
    private let onDownload: () -> Void

    private static let indexTitleSpacing: CGFloat = 10
    private static let activeCardOuterInset: CGFloat = 8

    static func columnWidth(forMaxIndex maxIndex: Int) -> CGFloat {
        if maxIndex >= 10_000 { return 42 }
        if maxIndex >= 1_000 { return 36 }
        if maxIndex >= 100 { return 28 }
        return 22
    }

    init(
        row: IndexedChapterRow,
        isCurrent: Bool,
        isPlaying: Bool,
        record: DownloadRecordSnapshot?,
        isLast: Bool,
        indexColumnWidth: CGFloat = 36,
        onSelect: @escaping () -> Void,
        onDownload: @escaping () -> Void = {}
    ) {
        self.row = row
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.record = record
        self.isLast = isLast
        self.indexColumnWidth = indexColumnWidth
        self.onSelect = onSelect
        self.onDownload = onDownload
    }

    static func formatFileSize(_ bytes: Int64) -> String { bytes.dsCompactByteSize }

    private var isCompleted: Bool { record?.state == .completed }

    private var isInProgress: Bool {
        guard let state = record?.state else { return false }
        return state == .queued || state == .resolving || state == .downloading
    }

    var body: some View {
        let sizeText = isCompleted
            ? (record.map { Self.formatFileSize($0.totalBytes > 0 ? $0.totalBytes : $0.downloadedBytes) } ?? "")
            : ""
        let qualityTier: AudioQualityTier? = isCompleted ? record?.qualityTier : nil
        let activeLeadingInset = max(0, DSSpacing.pageHorizontal - Self.activeCardOuterInset)

        VStack(spacing: 0) {
            HStack(spacing: DSSpacing.xs) {
                Button(action: onSelect) {
                    HStack(spacing: Self.indexTitleSpacing) {
                        indexLabel

                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.chapter.title)
                                .font(DSTypography.subheadline.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkPrimary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if isCurrent || isCompleted || isInProgress {
                                metaSubtitle(sizeText: sizeText, qualityTier: qualityTier)
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
            .padding(.leading, isCurrent ? activeLeadingInset : DSSpacing.pageHorizontal)
            .padding(.trailing, isCurrent ? 4 : 12)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DSColors.accent.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(DSColors.accent.opacity(0.24), lineWidth: 0.6)
                        )
                }
            }
            .padding(.horizontal, isCurrent ? Self.activeCardOuterInset : 0)
            .padding(.vertical, isCurrent ? 3 : 0)

            if !isLast && !isCurrent {
                Divider()
                    .overlay(DSColors.separator.opacity(0.24))
                    .padding(.leading, DSSpacing.pageHorizontal + indexColumnWidth + Self.indexTitleSpacing)
            }
        }
    }

    private var indexLabel: some View {
        Text(verbatim: "\(row.physicalIndex + 1)")
            .font(DSTypography.numericCaption.weight(isCurrent ? .bold : .regular).monospacedDigit())
            .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkSecondary.opacity(0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .allowsTightening(true)
            .frame(width: indexColumnWidth, alignment: .trailing)
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

    private func metaSubtitle(sizeText: String, qualityTier: AudioQualityTier?) -> some View {
        let items = subtitleParts(sizeText: sizeText, hasQualityBadge: qualityTier != nil && qualityTier != .auto)
        return HStack(spacing: 5) {
            if let tier = qualityTier, tier != .auto {
                DSQualityMicroBadge(tier: tier)
            }
            if !items.isEmpty {
                Text(items.joined(separator: " · "))
                    .font(DSTypography.caption2.monospacedDigit())
                    .foregroundStyle(isCurrent ? DSColors.accent.opacity(0.90) : DSColors.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
            }
        }
    }

    private func subtitleParts(sizeText: String, hasQualityBadge: Bool) -> [String] {
        var parts: [String] = []
        if isCurrent {
            parts.append(isPlaying ? "播放中" : "当前暂停")
        }
        if isCompleted {
            if !sizeText.isEmpty {
                parts.append(sizeText)
            } else if !isCurrent && !hasQualityBadge {
                parts.append("已下载")
            }
        } else if isInProgress {
            parts.append("下载中")
        }
        return parts
    }
}
