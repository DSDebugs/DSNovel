import DSDesignSystem
import SwiftUI

/// 书架 3 列正方形网格（1:1 复刻 v2.8：DSBookCard + 置顶 pin.fill + 编辑勾选 + 长按菜单）
struct ShelfGrid: View {
    let items: [LibraryBookItem]
    let playingBookID: String?
    let isEnginePlaying: Bool
    let isEditing: Bool
    let selectedIDs: Set<String>
    let pipeline: CoverImagePipeline
    private let onSelectBook: (LibraryBookItem) -> Void
    private let onPlayBook: (LibraryBookItem) -> Void
    private let onTogglePin: (LibraryBookItem) -> Void
    private let onDownloadUnread: (LibraryBookItem) -> Void
    private let onRemove: (LibraryBookItem) -> Void

    @State private var containerWidth: CGFloat = 393

    init(
        items: [LibraryBookItem],
        playingBookID: String?,
        isEnginePlaying: Bool,
        isEditing: Bool,
        selectedIDs: Set<String>,
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
        self.pipeline = pipeline
        self.onSelectBook = onSelectBook
        self.onPlayBook = onPlayBook
        self.onTogglePin = onTogglePin
        self.onDownloadUnread = onDownloadUnread
        self.onRemove = onRemove
    }

    private let columns = [
        GridItem(.flexible(), spacing: DSSpacing.gridColumnSpacing, alignment: .top),
        GridItem(.flexible(), spacing: DSSpacing.gridColumnSpacing, alignment: .top),
        GridItem(.flexible(), spacing: DSSpacing.gridColumnSpacing, alignment: .top)
    ]

    private var computedSide: CGFloat {
        let usable = max(240, containerWidth - DSSpacing.pageHorizontal * 2)
        return floor((usable - DSSpacing.gridColumnSpacing * 2) / 3.0)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: DSSpacing.gridRowSpacing) {
            ForEach(items) { item in
                let isPlayingThis = (playingBookID == item.id && isEnginePlaying)
                DSBookCard(
                    book: item.book,
                    pipeline: pipeline,
                    side: computedSide,
                    isPinned: item.isPinned,
                    isEditing: isEditing,
                    isSelected: selectedIDs.contains(item.id),
                    progressFraction: item.progressFraction,
                    isDownloaded: item.isDownloaded,
                    hasUpdate: item.hasUpdate,
                    isPlaying: isPlayingThis,
                    progressSubtitle: item.progressSubtitle,
                    onTap: { onSelectBook(item) }
                )
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
                        Label("移出书架", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            if abs(newWidth - containerWidth) > 1 {
                containerWidth = newWidth
            }
        }
    }
}
