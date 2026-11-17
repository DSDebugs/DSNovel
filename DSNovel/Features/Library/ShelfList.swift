import SwiftUI

struct ShelfList: View {
    let models: [BookCardModel]
    let isEditing: Bool
    let selectedIDs: Set<String>
    private let onSelectBook: (BookCardModel) -> Void
    private let onPlayBook: (BookCardModel) -> Void
    private let onTogglePin: (BookCardModel) -> Void
    private let onRemove: (BookCardModel) -> Void

    init(
        models: [BookCardModel],
        isEditing: Bool,
        selectedIDs: Set<String>,
        onSelectBook: @escaping (BookCardModel) -> Void,
        onPlayBook: @escaping (BookCardModel) -> Void,
        onTogglePin: @escaping (BookCardModel) -> Void,
        onRemove: @escaping (BookCardModel) -> Void
    ) {
        self.models = models
        self.isEditing = isEditing
        self.selectedIDs = selectedIDs
        self.onSelectBook = onSelectBook
        self.onPlayBook = onPlayBook
        self.onTogglePin = onTogglePin
        self.onRemove = onRemove
    }

    var body: some View {
        LazyVStack(spacing: Spacing.s2) {
            ForEach(models) { item in
                DSBookRow(
                    model: item,
                    isEditing: isEditing,
                    isSelected: selectedIDs.contains(item.id),
                    onSelect: { onSelectBook(item) },
                    onPlayTap: { onPlayBook(item) }
                )
                .padding(.horizontal, Spacing.pageHorizontal)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        onTogglePin(item)
                    } label: {
                        Label(item.isPinned ? "取消置顶" : "置顶", systemImage: "pin.fill")
                    }
                    .tint(Color.dsAccent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onRemove(item)
                    } label: {
                        Label("移出书架", systemImage: "trash")
                    }
                }
            }
        }
    }
}
