import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI

/// 书架顶部「继续收听」Hero 区块（1:1 复刻 v2.8：64×64 正方形封面、DSEqualizer、进度条、36pt 橙色圆形播放钮）
struct ContinueSection: View {
    let item: LibraryBookItem
    let isPlaying: Bool
    let isCurrentPlaybackBook: Bool
    let liveChapterTitle: String?
    let pipeline: CoverImagePipeline
    private let onOpenBook: () -> Void
    private let onTogglePlay: () -> Void
    private let onOpenHistory: () -> Void

    init(
        item: LibraryBookItem,
        isPlaying: Bool,
        isCurrentPlaybackBook: Bool,
        liveChapterTitle: String?,
        pipeline: CoverImagePipeline,
        onOpenBook: @escaping () -> Void,
        onTogglePlay: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void
    ) {
        self.item = item
        self.isPlaying = isPlaying
        self.isCurrentPlaybackBook = isCurrentPlaybackBook
        self.liveChapterTitle = liveChapterTitle
        self.pipeline = pipeline
        self.onOpenBook = onOpenBook
        self.onTogglePlay = onTogglePlay
        self.onOpenHistory = onOpenHistory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            DSSectionHeader(
                title: "继续收听",
                actionTitle: "全部历史 ›",
                onAction: onOpenHistory
            )

            if isCurrentPlaybackBook {
                LiveContinueCard(
                    item: item,
                    isPlaying: isPlaying,
                    liveChapterTitle: liveChapterTitle,
                    pipeline: pipeline,
                    onOpenBook: onOpenBook,
                    onTogglePlay: onTogglePlay
                )
                .padding(.horizontal, DSSpacing.pageHorizontal)
            } else {
                DSContinueCard(
                    book: item.book,
                    pipeline: pipeline,
                    progressFraction: item.progressFraction,
                    progressSubtitle: item.progressSubtitle,
                    isPlaying: false,
                    isDownloaded: item.isDownloaded,
                    hasUpdate: item.hasUpdate,
                    onOpenDetail: onOpenBook,
                    onTogglePlay: onTogglePlay
                )
                .padding(.horizontal, DSSpacing.pageHorizontal)
            }
        }
    }
}

/// 独立订阅 PlaybackClock 的继续收听卡片（隔离 2Hz 时钟刷新，避免 LibraryRootView 整页重绘）
private struct LiveContinueCard: View {
    @Environment(PlaybackClock.self) private var clock
    let item: LibraryBookItem
    let isPlaying: Bool
    let liveChapterTitle: String?
    let pipeline: CoverImagePipeline
    let onOpenBook: () -> Void
    let onTogglePlay: () -> Void

    var body: some View {
        let fraction = clock.progress > 0 ? clock.progress : item.progressFraction
        let subtitle = (liveChapterTitle?.isEmpty == false) ? (liveChapterTitle ?? "") : item.progressSubtitle
        DSContinueCard(
            book: item.book,
            pipeline: pipeline,
            progressFraction: fraction,
            progressSubtitle: subtitle,
            isPlaying: isPlaying,
            isDownloaded: item.isDownloaded,
            hasUpdate: item.hasUpdate,
            onOpenDetail: onOpenBook,
            onTogglePlay: onTogglePlay
        )
    }
}
