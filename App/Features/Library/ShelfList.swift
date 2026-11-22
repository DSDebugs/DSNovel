import DSDesignSystem
import SwiftUI

/// 书架 64pt 正方形列表视图（1:1 复刻 v2.8：DSBookRow + 行内直播钮 + ellipsis 菜单 + 长按菜单）
struct ShelfList: View {
    let items: [LibraryBookItem]
    let playingBookID: String?
    let isEnginePlaying: Bool
    let isEditing: Bool
    let selectedIDs: Set<String>
    let isDownloadedFilter: Bool
    let pipeline: CoverImagePipeline
    private let onSelectBook: (LibraryBookItem) -> Void
    private let onPlayBook: (LibraryBookItem) -> Void
    private let onTogglePin: (LibraryBookItem) -> Void
    private let onDownloadUnread: (LibraryBookItem) -> Void
    private let onRemove: (LibraryBookItem) -> Void

    init(
        items: [LibraryBookItem],
        playingBookID: String?,
        isEnginePlaying: Bool,
        isEditing: Bool,
        selectedIDs: Set<String>,
        isDownloadedFilter: Bool = false,
        pipeline: CoverImagePipeline,
        onSelectBook: @escaping (LibraryBookItem) -> Void,
        onPlayBook: @escaping (LibraryBookItem) -> Void,
        onTogglePin: @escaping (LibraryBookItem) -> Void,
        onDownloadUnread: @escaping (LibraryBookItem) -> Void,
        onRemove: @escaping (LibraryBookItem) -> Void
    ) {
        self.items = items
        self.playingBookID = playingBookID
        self.isEnginePlaying = isEnginePlaying
        self.isEditing = isEditing
        self.selectedIDs = selectedIDs
        self.isDownloadedFilter = isDownloadedFilter
        self.pipeline = pipeline
        self.onSelectBook = onSelectBook
        self.onPlayBook = onPlayBook
        self.onTogglePin = onTogglePin
        self.onDownloadUnread = onDownloadUnread
        self.onRemove = onRemove
    }

    private var removeLabel: String {
        isDownloadedFilter ? "删除离线" : "移出书架"
    }

    var body: some View {
        LazyVStack(spacing: DSSpacing.xs) {
            ForEach(items) { item in
                let isPlayingThis = (playingBookID == item.id && isEnginePlaying)
                HStack(spacing: DSSpacing.xxs) {
                    DSBookRow(
                        book: item.book,
                        subtitle: item.progressSubtitle.isEmpty ? nil : item.progressSubtitle,
                        pipeline: pipeline,
                        isPinned: item.isPinned,
                        isEditing: isEditing,
                        isSelected: selectedIDs.contains(item.id),
                        progressFraction: item.progressFraction,
                        isDownloaded: item.isDownloaded,
                        hasUpdate: item.hasUpdate,
                        isPlaying: isPlayingThis,
                        onPlayTap: { onPlayBook(item) },
                        onTap: { onSelectBook(item) }
                    )

                    if !isEditing {
                        Menu {
                            Button {
                                onTogglePin(item)
                            } label: {
                                Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
                            }
                            Button {
                                onDownloadUnread(item)
                            } label: {
                                Label("下载未听章节", systemImage: "arrow.down.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                onRemove(item)
                            } label: {
                                Label(removeLabel, systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(DSTypography.body.weight(.medium))
                                .foregroundStyle(DSColors.inkSecondary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("更多操作：\(item.book.title)")
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .contextMenu {
                    Button {
                        onPlayBook(item)
                    } label: {
                        Label("继续播放", systemImage: "play.fill")
                    }
                    Button {
                        onTogglePin(item)
                    } label: {
                        Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
                    }
                    Button {
                        onDownloadUnread(item)
                    } label: {
                        Label("下载未听章节", systemImage: "arrow.down.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onRemove(item)
                    } label: {
                        Label(removeLabel, systemImage: "trash")
                    }
                }
            }
        }
    }
}
