import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI

/// 书架顶部「继续收听」Hero 卡 + 「最近在听」舒展 3 列横滑区（去冗余大标题、保持宽敞左右边距与紧凑垂直节奏）
struct ContinueSection: View {
    let item: LibraryBookItem
    let recentItems: [LibraryBookItem]
    let playingBookID: String?
    let isPlaying: Bool
    let isCurrentPlaybackBook: Bool
    let liveChapterTitle: String?
    let pipeline: CoverImagePipeline
    private let onOpenBook: () -> Void
    private let onSelectRecent: (LibraryBookItem) -> Void
    private let onTogglePlay: () -> Void
    private let onOpenHistory: () -> Void

    init(
        item: LibraryBookItem,
        recentItems: [LibraryBookItem] = [],
        playingBookID: String? = nil,
        isPlaying: Bool,
        isCurrentPlaybackBook: Bool,
        liveChapterTitle: String?,
        pipeline: CoverImagePipeline,
        onOpenBook: @escaping () -> Void,
        onSelectRecent: @escaping (LibraryBookItem) -> Void = { _ in },
        onTogglePlay: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void
    ) {
        self.item = item
        self.recentItems = recentItems
        self.playingBookID = playingBookID
        self.isPlaying = isPlaying
        self.isCurrentPlaybackBook = isCurrentPlaybackBook
        self.liveChapterTitle = liveChapterTitle
        self.pipeline = pipeline
        self.onOpenBook = onOpenBook
        self.onSelectRecent = onSelectRecent
        self.onTogglePlay = onTogglePlay
        self.onOpenHistory = onOpenHistory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Group {
                if isCurrentPlaybackBook {
                    LiveContinueCard(
                        item: item,
                        isPlaying: isPlaying,
                        liveChapterTitle: liveChapterTitle,
                        pipeline: pipeline,
                        onOpenBook: onOpenBook,
                        onTogglePlay: onTogglePlay
                    )
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
                }
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)

            if recentItems.count >= 2 {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    DSSectionHeader(
                        title: "最近在听",
                        subtitle: "\(recentItems.count) 本",
                        actionTitle: "全部历史 ›",
                        onAction: onOpenHistory
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: DSSpacing.sm) {
                            ForEach(recentItems) { recent in
                                let isRecentPlaying = (playingBookID == recent.id) && isPlaying
                                DSBookCard(
                                    book: recent.book,
                                    pipeline: pipeline,
                                    side: 94,
                                    progressFraction: recent.progressFraction,
                                    isDownloaded: recent.isDownloaded,
                                    hasUpdate: recent.hasUpdate,
                                    isPlaying: isRecentPlaying,
                                    progressSubtitle: recent.progressSubtitle,
                                    showsSoftShadow: true,
                                    onTap: { onSelectRecent(recent) }
                                )
                            }
                        }
                        .padding(.horizontal, DSSpacing.pageHorizontal)
                    }
                    .contentMargins(.bottom, 0, for: .scrollContent)
                }
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
