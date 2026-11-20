import SwiftUI

struct ShelfList: View {
    let models: [BookCardModel]
    let isEditing: Bool
    let selectedIDs: Set<String>
    let isDownloadedFilter: Bool
    private let onSelectBook: (BookCardModel) -> Void
    private let onPlayBook: (BookCardModel) -> Void
    private let onTogglePin: (BookCardModel) -> Void
    private let onDownloadUnread: (BookCardModel) -> Void
    private let onRemove: (BookCardModel) -> Void

    init(
        models: [BookCardModel],
        isEditing: Bool,
        selectedIDs: Set<String>,
        isDownloadedFilter: Bool = false,
        onSelectBook: @escaping (BookCardModel) -> Void,
        onPlayBook: @escaping (BookCardModel) -> Void,
        onTogglePin: @escaping (BookCardModel) -> Void,
        onDownloadUnread: @escaping (BookCardModel) -> Void = { _ in },
        onRemove: @escaping (BookCardModel) -> Void
    ) {
        self.models = models
        self.isEditing = isEditing
        self.selectedIDs = selectedIDs
        self.isDownloadedFilter = isDownloadedFilter
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
        LazyVStack(spacing: Spacing.s2) {
            ForEach(models) { item in
                HStack(spacing: Spacing.s1) {
                    DSBookRow(
                        model: item,
                        isEditing: isEditing,
                        isSelected: selectedIDs.contains(item.id),
                        onSelect: { onSelectBook(item) },
                        onPlayTap: { onPlayBook(item) }
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
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("更多操作：\(item.title)")
                    }
                }
                .padding(.horizontal, Spacing.pageHorizontal)
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
