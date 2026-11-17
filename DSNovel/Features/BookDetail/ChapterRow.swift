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
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(snapshot.displayIndex)")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Spacing.s1) {
                            Text(snapshot.chapter.title)
                                .font(DSTypography.body.weight(snapshot.isCurrentPlayingChapter ? .semibold : .regular))
                                .foregroundStyle(snapshot.isCurrentPlayingChapter ? Color.dsAccent : .primary)
                                .lineLimit(2)
                            if snapshot.isVIP {
                                Image(systemName: "lock.fill")
                                    .font(DSTypography.caption2)
                                    .foregroundStyle(Color.dsAccent)
                            }
                        }

                        if !snapshot.subtitleText.isEmpty {
                            Text(snapshot.subtitleText)
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(.secondary)
                        }

                        if snapshot.progressFraction > 0 && !snapshot.isFinished {
                            DSProgress(value: snapshot.progressFraction, style: .bar(height: 2))
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
        }
        .padding(.horizontal, Spacing.pageHorizontal)
        .padding(.vertical, Spacing.s2)
        .background(
            snapshot.isCurrentPlayingChapter
                ? Color.dsAccent.opacity(0.08)
                : Color.clear
        )
    }

    @ViewBuilder
    private var downloadStatusIcon: some View {
        switch snapshot.downloadState {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading(let p):
            DSProgress(value: p, style: .ring(size: 20, lineWidth: 2))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
