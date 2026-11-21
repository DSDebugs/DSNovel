import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI

/// 书架整理与筛选辅助器（非 *View.swift，符合规则 #8）
enum LibraryOrganizerHelper {
    static let allGroupName = "全部书籍"

    static func filterBooks(_ books: [BookSummaryDTO], keyword: String) -> [BookSummaryDTO] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.author.localizedCaseInsensitiveContains(q)
                || $0.narrator.localizedCaseInsensitiveContains(q)
        }
    }
}

/// 书架顶部「继续收听」悬浮卡片
struct ContinueListeningCard: View {
    private let book: BookSummaryDTO
    private let chapterTitle: String
    private let isPlaying: Bool
    private let pipeline: CoverImagePipeline
    private let onOpenPlayer: () -> Void
    private let onTogglePlay: () -> Void

    init(
        book: BookSummaryDTO,
        chapterTitle: String,
        isPlaying: Bool,
        pipeline: CoverImagePipeline,
        onOpenPlayer: @escaping () -> Void,
        onTogglePlay: @escaping () -> Void
    ) {
        self.book = book
        self.chapterTitle = chapterTitle
        self.isPlaying = isPlaying
        self.pipeline = pipeline
        self.onOpenPlayer = onOpenPlayer
        self.onTogglePlay = onTogglePlay
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: onOpenPlayer) {
                HStack(spacing: DSSpacing.sm) {
                    DSCoverImage(urlString: book.coverURL, pipeline: pipeline, cornerRadius: DSRadius.sm)
                        .frame(width: 48, height: 64)
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        Text(book.title)
                            .font(DSTypography.headline)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                        Text(chapterTitle)
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                            .lineLimit(1)
                        ContinueProgressTrack()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(DSTypography.largeTitle)
                    .foregroundStyle(DSColors.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "暂停" : "继续播放")
        }
        .padding(DSSpacing.sm)
        .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }
}

/// 书架批量操作栏
struct ShelfBatchSelectionBar: View {
    private let selectedCount: Int
    private let onSelectAll: () -> Void
    private let onRemoveSelected: () -> Void
    private let onCancel: () -> Void

    init(
        selectedCount: Int,
        onSelectAll: @escaping () -> Void,
        onRemoveSelected: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.onSelectAll = onSelectAll
        self.onRemoveSelected = onRemoveSelected
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Button("全选", action: onSelectAll)
                .frame(minHeight: 44)
            Spacer()
            Text("已选 \(selectedCount) 本")
                .font(DSTypography.footnote)
                .foregroundStyle(DSColors.inkSecondary)
            Spacer()
            Button("移出书架", role: .destructive, action: onRemoveSelected)
                .disabled(selectedCount == 0)
                .frame(minHeight: 44)
            Button("完成", action: onCancel)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.md))
    }
}

/// 独立订阅 PlaybackClock 的继续收听进度微视图（UX2-01：避免 LibraryRootView 整页 2Hz 重绘）
private struct ContinueProgressTrack: View {
    @Environment(PlaybackClock.self) private var clock

    var body: some View {
        ProgressView(value: min(1, max(0, clock.progress)))
    }
}
