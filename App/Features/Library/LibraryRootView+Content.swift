import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

extension LibraryRootView {
    @ViewBuilder
    func downloadedFilterStatusCard(overview: DownloadedShelfOverview) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已下载书籍 · \(overview.bookCount) 本")
                        .font(DSTypography.rowTitle)
                    Text("共 \(overview.completedChapters) 章离线音频 · 占用 \(overview.formattedBytes)")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
                Spacer()
                Button {
                    router.push(.downloads)
                } label: {
                    Text("管理队列")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DSColors.surfaceGrouped))
                }
                .buttonStyle(.plain)
            }
            if overview.activeChapters > 0 {
                HStack(spacing: DSSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在下载 \(overview.activeChapters) 章…")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkPrimary)
                    Spacer()
                }
            }
            if overview.failedChapters > 0 {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DSColors.danger)
                    Text("\(overview.failedChapters) 章下载失败")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.danger)
                    Spacer()
                    Button("全部重试") {
                        Task { await downloads.resumeAll() }
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(DSColors.surfaceCard))
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    @ViewBuilder
    var mainShelfContent: some View {
        if displayedItems.isEmpty && !isLoading {
            if selectedFilter == .downloaded {
                DSStateView(
                    kind: .empty,
                    titleOverride: "暂无已下载书籍",
                    messageOverride: "在书籍详情页点击下载章节后，即可在此离线收听与管理",
                    primaryTitleOverride: "返回全部书架",
                    secondaryTitleOverride: "去首页",
                    onPrimary: { switchFilter(.all) },
                    onSecondary: { router.selectTab(.discover) }
                )
            } else if shelfItems.isEmpty {
                DSStateView(
                    kind: .empty,
                    titleOverride: "书架还是空的",
                    messageOverride: "去首页逛逛或搜索想听的有声书",
                    primaryTitleOverride: "去首页",
                    secondaryTitleOverride: "去搜索",
                    onPrimary: { router.selectTab(.discover) },
                    onSecondary: { router.openSearch() }
                )
            } else {
                DSStateView(
                    kind: .empty,
                    titleOverride: "当前筛选下暂无书籍",
                    messageOverride: "试试切换回全部书架查看",
                    primaryTitleOverride: "查看全部",
                    onPrimary: { switchFilter(.all) },
                    onSecondary: nil
                )
            }
        } else {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                if settings.shelfLayout == .list || selectedFilter == .downloaded {
                    ShelfList(
                        items: displayedItems,
                        playingBookID: playback.currentBook?.id,
                        isEnginePlaying: playback.state.isPlaying,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        isDownloadedFilter: selectedFilter == .downloaded,
                        pipeline: container.coverPipeline,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { item in Task { await playBookImmediately(item) } },
                        onTogglePin: { item in Task { await togglePin(item) } },
                        onDownloadUnread: { item in Task { await downloadUnread(item) } },
                        onRemove: { pendingRemoveBook = $0 }
                    )
                } else {
                    ShelfGrid(
                        items: displayedItems,
                        playingBookID: playback.currentBook?.id,
                        isEnginePlaying: playback.state.isPlaying,
                        isEditing: isEditing,
                        selectedIDs: selectedIDs,
                        pipeline: container.coverPipeline,
                        onSelectBook: { handleCardTap($0) },
                        onPlayBook: { item in Task { await playBookImmediately(item) } },
                        onTogglePin: { item in Task { await togglePin(item) } },
                        onDownloadUnread: { item in Task { await downloadUnread(item) } },
                        onRemove: { pendingRemoveBook = $0 }
                    )
                }
            }
        }
    }
}
