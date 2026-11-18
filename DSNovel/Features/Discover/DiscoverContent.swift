import SwiftUI

struct DiscoverContent: View {
    let books: [BookRef]
    let shelfBookIDs: Set<String>
    let layoutStyle: DiscoverLayoutStyle
    let isLoadingMore: Bool
    let loadMoreFailed: Bool
    private let onRefresh: (() async -> Void)?
    private let onSelectBook: (BookRef) -> Void
    private let onAddToShelf: (BookRef) -> Void
    private let onCopyLink: (BookRef) -> Void
    private let onReachLoadMoreTrigger: (String) -> Void
    private let onRetryLoadMore: () -> Void

    @State private var containerWidth: CGFloat = 393

    init(
        books: [BookRef],
        shelfBookIDs: Set<String>,
        layoutStyle: DiscoverLayoutStyle,
        isLoadingMore: Bool,
        loadMoreFailed: Bool,
        localScrollAnchor: Binding<String?> = .constant(nil),
        onRefresh: (() async -> Void)? = nil,
        onSelectBook: @escaping (BookRef) -> Void,
        onAddToShelf: @escaping (BookRef) -> Void,
        onCopyLink: @escaping (BookRef) -> Void,
        onReachLoadMoreTrigger: @escaping (String) -> Void,
        onRetryLoadMore: @escaping () -> Void
    ) {
        self.books = books
        self.shelfBookIDs = shelfBookIDs
        self.layoutStyle = layoutStyle
        self.isLoadingMore = isLoadingMore
        self.loadMoreFailed = loadMoreFailed
        _ = localScrollAnchor
        self.onRefresh = onRefresh
        self.onSelectBook = onSelectBook
        self.onAddToShelf = onAddToShelf
        self.onCopyLink = onCopyLink
        self.onReachLoadMoreTrigger = onReachLoadMoreTrigger
        self.onRetryLoadMore = onRetryLoadMore
    }

    private var columns: [GridItem] {
        switch layoutStyle {
        case .grid:
            return Array(repeating: GridItem(.flexible(), spacing: Spacing.gridColumnSpacing, alignment: .top), count: 3)
        case .largeCard:
            return Array(repeating: GridItem(.flexible(), spacing: Spacing.gridColumnSpacing, alignment: .top), count: 2)
        case .list:
            return [GridItem(.flexible(), alignment: .top)]
        }
    }

    private var computedCoverSide: CGFloat {
        let usableWidth = max(240, containerWidth - Spacing.pageHorizontal * 2)
        switch layoutStyle {
        case .grid:
            return floor((usableWidth - Spacing.gridColumnSpacing * 2) / 3.0)
        case .largeCard:
            return floor((usableWidth - Spacing.gridColumnSpacing) / 2.0)
        case .list:
            return 72
        }
    }

    private var triggerBookID: String? {
        guard !books.isEmpty else { return nil }
        let idx = max(0, books.count - 6)
        return books[idx].id
    }

    var body: some View {
        let _ = DiscoverRenderCounter.shared.recordContent()
        let side = computedCoverSide
        let rowSpacing = layoutStyle == .largeCard ? Spacing.largeCardRowSpacing : Spacing.gridRowSpacing

        ScrollView {
            LazyVGrid(columns: columns, spacing: rowSpacing) {
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
                                side: side,
                                onAction: { onSelectBook(ref) }
                            )
                        }
                    }
                    .id(ref.id)
                    .onAppear {
                        if ref.id == triggerBookID {
                            onReachLoadMoreTrigger(ref.id)
                        }
                    }
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
            .padding(.horizontal, Spacing.pageHorizontal)
            .padding(.top, Spacing.s2)

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
        .refreshable {
            await onRefresh?()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if abs(newWidth - containerWidth) > 1 {
                containerWidth = newWidth
            }
        }
    }
}
