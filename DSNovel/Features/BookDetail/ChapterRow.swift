import SwiftUI

final class ChapterRowRenderCounter: @unchecked Sendable {
    static let shared = ChapterRowRenderCounter()
    private(set) var evaluationsByChapterID: [String: Int] = [:]

    func record(chapterID: String) {
        evaluationsByChapterID[chapterID, default: 0] += 1
    }

    func count(for chapterID: String) -> Int {
        evaluationsByChapterID[chapterID, default: 0]
    }

    func reset() {
        evaluationsByChapterID.removeAll()
    }
}

struct ChapterRow: View, Equatable {
    let snapshot: ChapterRowSnapshot
    private let onSelect: () -> Void
    private let onDownloadAction: () -> Void

    init(
        snapshot: ChapterRowSnapshot,
        onSelect: @escaping () -> Void = {},
        onDownloadAction: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.onSelect = onSelect
        self.onDownloadAction = onDownloadAction
    }

    static func == (lhs: ChapterRow, rhs: ChapterRow) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        let _ = ChapterRowRenderCounter.shared.record(chapterID: snapshot.id)
        HStack(spacing: Spacing.s3) {
            Button(action: onSelect) {
                HStack(spacing: Spacing.s3) {
                    ZStack {
                        if snapshot.isCurrentPlayingChapter {
                            DSEqualizer(isPlaying: snapshot.isEnginePlaying)
                        } else if snapshot.isFinished {
                            Image(systemName: "checkmark")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: "\(snapshot.displayIndex)")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                    .frame(minWidth: 34)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Spacing.s1) {
                            Text(snapshot.chapter.title)
                                .font(DSTypography.body.weight(snapshot.isCurrentPlayingChapter ? .semibold : .regular))
                                .foregroundStyle(
                                    snapshot.isCurrentPlayingChapter
                                        ? Color.dsAccent
                                        : (snapshot.isFinished ? .secondary : .primary)
                                )
                                .lineLimit(2)
                            if snapshot.isVIP {
                                Image(systemName: "lock.fill")
                                    .font(DSTypography.caption2)
                                    .foregroundStyle(Color.dsAccent)
                            }
                        }

                        if snapshot.isCurrentPlayingChapter {
                            LiveChapterSubtitleView(snapshot: snapshot)
                        } else if !snapshot.subtitleText.isEmpty {
                            staticSubtitleRow(text: snapshot.subtitleText)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDownloadAction) {
                downloadStatusIcon
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(snapshot.isDeleting)
            .accessibilityLabel(downloadButtonAccessibilityLabel)
        }
        .padding(.horizontal, Spacing.pageHorizontal)
        .padding(.vertical, 11)
        .background(
            snapshot.isCurrentPlayingChapter
                ? Color.dsAccent.opacity(0.08)
                : Color.clear
        )
    }

    @ViewBuilder
    private func staticSubtitleRow(text: String) -> some View {
        HStack(spacing: 4) {
            if snapshot.downloadState == .completed && !snapshot.isDeleting {
                Image(systemName: "arrow.down.circle.fill")
                    .font(DSTypography.caption2)
                    .foregroundStyle(.green)
            } else if snapshot.downloadState == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DSTypography.caption2)
                    .foregroundStyle(.red)
            }
            Text(text)
                .font(DSTypography.numericCaption)
                .foregroundStyle(
                    snapshot.downloadState == .failed
                        ? .red
                        : (snapshot.isCurrentPlayingChapter ? Color.dsAccent.opacity(0.9) : .secondary)
                )
        }
    }

    private var downloadButtonAccessibilityLabel: String {
        if snapshot.isDeleting {
            return "正在删除离线文件"
        }
        switch snapshot.downloadState {
        case .notDownloaded:
            return "下载第 \(snapshot.displayIndex) 章"
        case .downloading(let p):
            return "正在下载 \(Int((p * 100).rounded()))%"
        case .completed:
            return "第 \(snapshot.displayIndex) 章已下载，点击删除离线文件"
        case .failed:
            return "第 \(snapshot.displayIndex) 章下载失败，点击重试"
        }
    }

    @ViewBuilder
    private var downloadStatusIcon: some View {
        if snapshot.isDeleting {
            ProgressView()
                .controlSize(.small)
        } else {
            switch snapshot.downloadState {
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            case .downloading(let p):
                DSProgress(value: p, style: .ring(size: 20, lineWidth: 2.2))
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }
}

/// 隔离观察当前播放章节的实时进度（仅本叶子视图每秒刷新，绝不触发外层列表或章节范围菜单重建闪烁）
private struct LiveChapterSubtitleView: View {
    let snapshot: ChapterRowSnapshot
    @State private var player = PlayerEngine.shared

    var body: some View {
        let livePosMs = max(0, Int(player.clock.currentTimeSec * 1000))
        let liveDurMs = max(0, Int(player.clock.durationSec * 1000))
        let text = snapshot.subtitleText(
            overridePositionMs: livePosMs > 0 ? livePosMs : snapshot.savedPositionMs,
            overrideDurationMs: liveDurMs > 0 ? liveDurMs : snapshot.durationMs
        )
        if !text.isEmpty {
            HStack(spacing: 4) {
                if snapshot.downloadState == .completed && !snapshot.isDeleting {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(DSTypography.caption2)
                        .foregroundStyle(.green)
                } else if snapshot.downloadState == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DSTypography.caption2)
                        .foregroundStyle(.red)
                }
                Text(text)
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(
                        snapshot.downloadState == .failed
                            ? .red
                            : Color.dsAccent.opacity(0.9)
                    )
            }
        }
    }
}
