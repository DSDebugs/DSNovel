import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

/// 单章列表行（无框精密等宽序号 + 按位数自适应紧凑列宽 + 在播高亮主题色与行尾波形 + 20pt 进度环/完成态菜单）
struct ChapterRow: View, Equatable {
    let snapshot: ChapterRowSnapshot
    let indexColumnWidth: CGFloat
    private let onSelect: () -> Void
    private let onDownloadAction: () -> Void

    private static let indexTitleSpacing: CGFloat = 10

    static func columnWidth(forMaxIndex maxIndex: Int) -> CGFloat {
        if maxIndex >= 10_000 { return 42 }
        if maxIndex >= 1_000 { return 36 }
        if maxIndex >= 100 { return 28 }
        return 22
    }

    init(
        snapshot: ChapterRowSnapshot,
        indexColumnWidth: CGFloat = 36,
        onSelect: @escaping () -> Void = {},
        onDownloadAction: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.indexColumnWidth = indexColumnWidth
        self.onSelect = onSelect
        self.onDownloadAction = onDownloadAction
    }

    nonisolated static func == (lhs: ChapterRow, rhs: ChapterRow) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.indexColumnWidth == rhs.indexColumnWidth
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: onSelect) {
                HStack(spacing: Self.indexTitleSpacing) {
                    indexLabel

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: DSSpacing.xxs) {
                            Text(snapshot.displayTitle)
                                .font(DSTypography.callout.weight(snapshot.isCurrentPlayingChapter ? .semibold : .regular))
                                .foregroundStyle(
                                    snapshot.isCurrentPlayingChapter
                                        ? DSColors.accent
                                        : (snapshot.isFinished ? DSColors.inkSecondary : DSColors.inkPrimary)
                                )
                                .lineLimit(2)
                            if snapshot.isVIP {
                                Image(systemName: "lock.fill")
                                    .font(DSTypography.caption2)
                                    .foregroundStyle(DSColors.accent)
                            }
                        }

                        if snapshot.isCurrentPlayingChapter {
                            LiveChapterSubtitleView(snapshot: snapshot)
                        } else if !snapshot.subtitleText.isEmpty {
                            staticSubtitleRow(text: snapshot.subtitleText)
                        }
                    }

                    Spacer(minLength: 0)

                    if snapshot.isCurrentPlayingChapter {
                        DSEqualizer(isPlaying: snapshot.isEnginePlaying)
                            .padding(.leading, 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailingDownloadControl
        }
        .padding(.leading, DSSpacing.pageHorizontal)
        .padding(.trailing, DSSpacing.xs)
        .padding(.vertical, DSSpacing.xs)
        .frame(minHeight: 58)
        .background {
            if snapshot.isCurrentPlayingChapter {
                RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                    .fill(DSColors.accent.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                            .strokeBorder(DSColors.accent.opacity(0.22), lineWidth: 0.6)
                    )
                    .padding(.horizontal, DSSpacing.xs)
            }
        }
        .overlay(alignment: .bottom) {
            if !snapshot.isCurrentPlayingChapter {
                Rectangle()
                    .fill(DSColors.separator.opacity(0.5))
                    .frame(height: 0.5)
                    .padding(.leading, DSSpacing.pageHorizontal + indexColumnWidth + Self.indexTitleSpacing)
            }
        }
    }

    private var indexLabel: some View {
        let isCurrent = snapshot.isCurrentPlayingChapter
        return Group {
            if snapshot.isFinished && !isCurrent {
                Image(systemName: "checkmark")
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(DSColors.inkSecondary.opacity(0.75))
            } else {
                Text(verbatim: "\(snapshot.displayIndex)")
                    .font(DSTypography.numericCaption.weight(isCurrent ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkSecondary.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            }
        }
        .frame(width: indexColumnWidth, alignment: .trailing)
    }

    @ViewBuilder
    private var trailingDownloadControl: some View {
        if snapshot.downloadState == .completed {
            Menu {
                Button(role: .destructive, action: onDownloadAction) {
                    Label("删除离线文件", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DSTypography.body.weight(.medium))
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("第 \(snapshot.displayIndex) 章已下载，更多操作")
        } else {
            Button(action: onDownloadAction) {
                downloadStatusIcon
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(downloadButtonAccessibilityLabel)
        }
    }

    @ViewBuilder
    private func staticSubtitleRow(text: String) -> some View {
        HStack(spacing: 4) {
            if snapshot.downloadState == .completed {
                Image(systemName: "arrow.down.circle.fill")
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.success)
            } else if snapshot.downloadState == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.danger)
            }
            Text(text)
                .font(DSTypography.numericCaption)
                .foregroundStyle(
                    snapshot.downloadState == .failed
                        ? DSColors.danger
                        : (snapshot.isCurrentPlayingChapter ? DSColors.accent.opacity(0.9) : DSColors.inkSecondary)
                )
        }
    }

    private var downloadButtonAccessibilityLabel: String {
        switch snapshot.downloadState {
        case .notDownloaded:
            return "下载第 \(snapshot.displayIndex) 章"
        case .downloading(let progress):
            return "正在下载 \(Int((progress * 100).rounded()))%"
        case .completed:
            return "第 \(snapshot.displayIndex) 章已下载"
        case .failed:
            return "第 \(snapshot.displayIndex) 章下载失败，点击重试"
        }
    }

    @ViewBuilder
    private var downloadStatusIcon: some View {
        switch snapshot.downloadState {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
        case .downloading(let progress):
            if !snapshot.downloadRecordID.isEmpty {
                ChapterDownloadProgressRing(
                    recordID: snapshot.downloadRecordID,
                    fallbackProgress: progress
                )
            } else {
                DownloadProgressRingView(progress: progress, size: 20, lineWidth: 2.2)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(DSColors.success)
        case .failed:
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(DSTypography.body.weight(.semibold))
                .foregroundStyle(DSColors.danger)
        }
    }
}

/// 隔离观察单章下载进度环（仅叶子视图订阅 DownloadProgressFeed，避免刷新外层列表）
private struct ChapterDownloadProgressRing: View {
    @Environment(DownloadProgressFeed.self) private var progressFeed
    let recordID: String
    let fallbackProgress: Double

    var body: some View {
        let live = progressFeed.progress(for: recordID)
        DownloadProgressRingView(
            progress: live > 0 ? live : fallbackProgress,
            size: 20,
            lineWidth: 2.2
        )
    }
}

/// 隔离观察当前播放章节实时进度（仅叶子视图订阅 PlaybackClock）
private struct LiveChapterSubtitleView: View {
    @Environment(PlaybackClock.self) private var clock
    let snapshot: ChapterRowSnapshot

    var body: some View {
        let livePosMs = clock.currentSeconds.isFinite ? max(0, Int(clock.currentSeconds * 1000)) : 0
        let liveDurMs = clock.durationSeconds.isFinite ? max(0, Int(clock.durationSeconds * 1000)) : 0
        let text = snapshot.subtitleText(
            overridePositionMs: livePosMs > 0 ? livePosMs : snapshot.savedPositionMs,
            overrideDurationMs: liveDurMs > 0 ? liveDurMs : snapshot.durationMs
        )
        if !text.isEmpty {
            HStack(spacing: 4) {
                if snapshot.downloadState == .completed {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.success)
                } else if snapshot.downloadState == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.danger)
                }
                Text(text)
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(
                        snapshot.downloadState == .failed
                            ? DSColors.danger
                            : DSColors.accent.opacity(0.9)
                    )
            }
        }
    }
}
