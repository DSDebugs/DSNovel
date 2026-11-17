import SwiftUI

struct ShelfGrid: View {
    let models: [BookCardModel]
    let isEditing: Bool
    let selectedIDs: Set<String>
    private let onSelectBook: (BookCardModel) -> Void
    private let onPlayBook: (BookCardModel) -> Void
    private let onTogglePin: (BookCardModel) -> Void
    private let onMoveCategory: (BookCardModel) -> Void
    private let onDownloadUnread: (BookCardModel) -> Void
    private let onRemove: (BookCardModel) -> Void

    @State private var containerWidth: CGFloat = 393

    init(
        models: [BookCardModel],
        isEditing: Bool,
        selectedIDs: Set<String>,
        onSelectBook: @escaping (BookCardModel) -> Void,
        onPlayBook: @escaping (BookCardModel) -> Void,
        onTogglePin: @escaping (BookCardModel) -> Void,
        onMoveCategory: @escaping (BookCardModel) -> Void,
        onDownloadUnread: @escaping (BookCardModel) -> Void,
        onRemove: @escaping (BookCardModel) -> Void
    ) {
        self.models = models
        self.isEditing = isEditing
        self.selectedIDs = selectedIDs
        self.onSelectBook = onSelectBook
        self.onPlayBook = onPlayBook
        self.onTogglePin = onTogglePin
        self.onMoveCategory = onMoveCategory
        self.onDownloadUnread = onDownloadUnread
        self.onRemove = onRemove
    }

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.gridColumnSpacing, alignment: .top),
        GridItem(.flexible(), spacing: Spacing.gridColumnSpacing, alignment: .top),
        GridItem(.flexible(), spacing: Spacing.gridColumnSpacing, alignment: .top)
    ]

    private var computedSide: CGFloat {
        let usable = max(240, containerWidth - Spacing.pageHorizontal * 2)
        return floor((usable - Spacing.gridColumnSpacing * 2) / 3.0)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.gridRowSpacing) {
            ForEach(models) { item in
                DSBookCard(
                    model: item,
                    side: computedSide,
                    isEditing: isEditing,
                    isSelected: selectedIDs.contains(item.id),
                    onAction: { onSelectBook(item) }
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
                        onMoveCategory(item)
                    } label: {
                        Label("移动到分类", systemImage: "folder")
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
        .padding(.horizontal, Spacing.pageHorizontal)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if abs(newWidth - containerWidth) > 1 {
                containerWidth = newWidth
            }
        }
    }
}
