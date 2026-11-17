import SwiftUI

struct DiscoverContent: View {
    let books: [BookRef]
    let shelfBookIDs: Set<String>
    let layoutStyle: DiscoverLayoutStyle
    let isLoadingMore: Bool
    let loadMoreFailed: Bool
    @Binding var scrollAnchor: String?
    private let onSelectBook: (BookRef) -> Void
    private let onAddToShelf: (BookRef) -> Void
    private let onCopyLink: (BookRef) -> Void
    private let onAppearItem: (String) -> Void
    private let onRetryLoadMore: () -> Void

    init(
        books: [BookRef],
        shelfBookIDs: Set<String>,
        layoutStyle: DiscoverLayoutStyle,
        isLoadingMore: Bool,
        loadMoreFailed: Bool,
        scrollAnchor: Binding<String?>,
        onSelectBook: @escaping (BookRef) -> Void,
        onAddToShelf: @escaping (BookRef) -> Void,
        onCopyLink: @escaping (BookRef) -> Void,
        onAppearItem: @escaping (String) -> Void,
        onRetryLoadMore: @escaping () -> Void
    ) {
        self.books = books
        self.shelfBookIDs = shelfBookIDs
        self.layoutStyle = layoutStyle
        self.isLoadingMore = isLoadingMore
        self.loadMoreFailed = loadMoreFailed
        self._scrollAnchor = scrollAnchor
        self.onSelectBook = onSelectBook
        self.onAddToShelf = onAddToShelf
        self.onCopyLink = onCopyLink
        self.onAppearItem = onAppearItem
        self.onRetryLoadMore = onRetryLoadMore
    }

    private var columns: [GridItem] {
        switch layoutStyle {
        case .grid:
            return Array(repeating: GridItem(.flexible(), spacing: Spacing.gridColumnSpacing), count: 3)
        case .largeCard:
            return Array(repeating: GridItem(.flexible(), spacing: Spacing.gridColumnSpacing), count: 2)
        case .list:
            return [GridItem(.flexible())]
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.gridRowSpacing) {
                ForEach(books) { ref in
                    let inShelf = shelfBookIDs.contains(ref.id)
                    let model = BookCardModel(
                        id: ref.id,
                        title: ref.title,
                        author: ref.author,
                        coverURL: ref.cover,
                        progressSubtitle: ref.discoverSubtitle,
                        inShelf: inShelf
                    )
                    Group {
                        if layoutStyle == .list {
                            DSBookRow(
                                model: model,
                                onSelect: { onSelectBook(ref) }
                            )
                        } else {
                            DSBookCard(
                                model: model,
                                side: layoutStyle == .largeCard ? 156 : 108,
                                onAction: { onSelectBook(ref) }
                            )
                            .containerRelativeFrame(
                                .horizontal,
                                count: layoutStyle == .largeCard ? 2 : 3,
                                spacing: Spacing.gridColumnSpacing
                            )
                        }
                    }
                    .id(ref.id)
                    .onAppear { onAppearItem(ref.id) }
                    .contextMenu {
                        Button {
                            onAddToShelf(ref)
                        } label: {
                            Label(inShelf ? "已在书架" : "加入书架", systemImage: inShelf ? "checkmark" : "plus.circle")
                        }
                        .disabled(inShelf)

                        Button {
                            onCopyLink(ref)
                        } label: {
                            Label("复制链接", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Spacing.pageHorizontal)

            if isLoadingMore {
                DSSkeleton(mode: .list(rows: 2))
                    .padding(.vertical, Spacing.s3)
            } else if loadMoreFailed {
                Button("加载失败，点按重试", action: onRetryLoadMore)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(Color.dsAccent)
                    .padding(.vertical, Spacing.s4)
            }
        }
        .scrollPosition(id: $scrollAnchor)
    }
}
