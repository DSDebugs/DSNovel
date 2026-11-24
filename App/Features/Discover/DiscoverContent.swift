import DSCore
import DSDesignSystem
import SwiftUI

/// 发现页多布局内容流（1:1 复刻 v2.8 DiscoverContent：3 列网格 / 2 列大图 / 列表 + 长按菜单 + 下拉刷新 + 尾部分页）
struct DiscoverContent: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion

    let books: [BookSummaryDTO]
    let shelfBookIDs: Set<String>
    let pipeline: CoverImagePipeline
    let layoutStyle: DiscoverLayoutStyle
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let loadMoreError: String?
    let scrollResetToken: String
    let scrollToTopCount: Int
    let showRankBadges: Bool
    let categoryHeaderTitle: String
    let sortOption: DiscoverSortOption
    let supportsSort: Bool

    private let onRefresh: (() async -> Void)?
    private let onSelectSort: ((DiscoverSortOption) -> Void)?
    private let onSelectBook: (BookSummaryDTO) -> Void
    private let onSelectNarrator: (String) -> Void
    private let onAddToShelf: (BookSummaryDTO) -> Void
    private let onCopyLink: (BookSummaryDTO) -> Void
    private let onReachLoadMoreTrigger: (String) -> Void
    private let onRetryLoadMore: () -> Void

    @State private var containerWidth: CGFloat = 393

    init(
        books: [BookSummaryDTO],
        shelfBookIDs: Set<String>,
        pipeline: CoverImagePipeline,
        layoutStyle: DiscoverLayoutStyle,
        canLoadMore: Bool = false,
        isLoadingMore: Bool = false,
        loadMoreError: String? = nil,
        scrollResetToken: String = "",
        scrollToTopCount: Int = 0,
        showRankBadges: Bool = false,
        categoryHeaderTitle: String = "",
        sortOption: DiscoverSortOption = .hot,
        supportsSort: Bool = false,
        onSelectSort: ((DiscoverSortOption) -> Void)? = nil,
        onRefresh: (() async -> Void)? = nil,
        onSelectBook: @escaping (BookSummaryDTO) -> Void,
        onSelectNarrator: @escaping (String) -> Void,
        onAddToShelf: @escaping (BookSummaryDTO) -> Void,
        onCopyLink: @escaping (BookSummaryDTO) -> Void,
        onReachLoadMoreTrigger: @escaping (String) -> Void,
        onRetryLoadMore: @escaping () -> Void
    ) {
        self.books = books
        self.shelfBookIDs = shelfBookIDs
        self.pipeline = pipeline
        self.layoutStyle = layoutStyle
        self.canLoadMore = canLoadMore
        self.isLoadingMore = isLoadingMore
        self.loadMoreError = loadMoreError
        self.scrollResetToken = scrollResetToken
        self.scrollToTopCount = scrollToTopCount
        self.showRankBadges = showRankBadges
        self.categoryHeaderTitle = categoryHeaderTitle
        self.sortOption = sortOption
        self.supportsSort = supportsSort
        self.onSelectSort = onSelectSort
        self.onRefresh = onRefresh
        self.onSelectBook = onSelectBook
        self.onSelectNarrator = onSelectNarrator
        self.onAddToShelf = onAddToShelf
        self.onCopyLink = onCopyLink
        self.onReachLoadMoreTrigger = onReachLoadMoreTrigger
        self.onRetryLoadMore = onRetryLoadMore
    }

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var columns: [GridItem] {
        switch layoutStyle {
        case .grid:
            return Array(repeating: GridItem(.flexible(), spacing: DSSpacing.gridColumnSpacing, alignment: .top), count: 3)
        case .largeCard:
            return Array(repeating: GridItem(.flexible(), spacing: DSSpacing.gridColumnSpacing, alignment: .top), count: 2)
        case .list:
            return [GridItem(.flexible(), alignment: .top)]
        }
    }

    private var computedCoverSide: CGFloat {
        let usableWidth = max(240, containerWidth - DSSpacing.pageHorizontal * 2)
        switch layoutStyle {
        case .grid:
            return floor((usableWidth - DSSpacing.gridColumnSpacing * 2) / 3.0)
        case .largeCard:
            return floor((usableWidth - DSSpacing.gridColumnSpacing) / 2.0)
        case .list:
            return 64
        }
    }

    private var tailTriggerThreshold: Int {
        max(0, books.count - 6)
    }

    var body: some View {
        let side = computedCoverSide
        let rowSpacing = layoutStyle == .largeCard ? DSSpacing.largeCardRowSpacing : DSSpacing.gridRowSpacing
        let threshold = tailTriggerThreshold

        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id("discover-top")

                if supportsSort && !categoryHeaderTitle.isEmpty {
                    HStack(alignment: .center, spacing: DSSpacing.xs) {
                        Text(categoryHeaderTitle)
                            .font(DSTypography.sectionHeader)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                        Spacer()
                        Menu {
                            ForEach(DiscoverSortOption.allCases) { option in
                                Button {
                                    onSelectSort?(option)
                                } label: {
                                    HStack {
                                        Text(option.title)
                                        if option == sortOption {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(sortOption.title)
                                    .font(DSTypography.footnote.weight(.semibold))
                                Image(systemName: "chevron.down")
                                    .font(DSTypography.caption2.weight(.semibold))
                            }
                            .foregroundStyle(DSColors.accent)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .tint(DSColors.accent)
                        .accessibilityIdentifier("discover.sortMenu")
                    }
                    .padding(.horizontal, DSSpacing.pageHorizontal)
                    .padding(.top, DSSpacing.xs)
                }

                LazyVGrid(columns: columns, spacing: rowSpacing) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        let inShelf = shelfBookIDs.contains(book.id)
                        bookCell(book: book, side: side, inShelf: inShelf, rankNumber: showRankBadges ? (index + 1) : nil)
                            .onAppear {
                                if canLoadMore && !isLoadingMore && loadMoreError == nil && index >= threshold {
                                    onReachLoadMoreTrigger(book.id)
                                }
                            }
                            .contextMenu {
                                Button {
                                    onAddToShelf(book)
                                } label: {
                                    Label(inShelf ? "已在书架" : "加入书架", systemImage: inShelf ? "checkmark" : "plus.circle")
                                }
                                .disabled(inShelf)

                                Button {
                                    onCopyLink(book)
                                } label: {
                                    Label("复制链接", systemImage: "doc.on.doc")
                                }
                            }
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .padding(.top, DSSpacing.xs)

                bottomLoadMoreFooter
            }
            .scrollDismissesKeyboard(.immediately)
            .contentMargins(.bottom, DSSpacing.md, for: .scrollContent)
            .refreshable {
                await onRefresh?()
            }
            .onChange(of: scrollResetToken) { _, _ in
                proxy.scrollTo("discover-top", anchor: .top)
            }
            .onChange(of: scrollToTopCount) { _, _ in
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                    proxy.scrollTo("discover-top", anchor: .top)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if abs(newWidth - containerWidth) > 1 {
                containerWidth = newWidth
            }
        }
    }

    @ViewBuilder
    private func bookCell(book: BookSummaryDTO, side: CGFloat, inShelf: Bool, rankNumber: Int?) -> some View {
        switch layoutStyle {
        case .list:
            DiscoverListRow(
                book: book,
                pipeline: pipeline,
                inShelf: inShelf,
                rankNumber: rankNumber,
                onTap: { onSelectBook(book) },
                onNarratorTap: onSelectNarrator
            )
        case .largeCard:
            DiscoverLargeCard(
                book: book,
                pipeline: pipeline,
                side: side,
                inShelf: inShelf,
                rankNumber: rankNumber,
                onTap: { onSelectBook(book) },
                onNarratorTap: onSelectNarrator
            )
        case .grid:
            DiscoverGridCard(
                book: book,
                pipeline: pipeline,
                side: side,
                inShelf: inShelf,
                rankNumber: rankNumber,
                onTap: { onSelectBook(book) },
                onNarratorTap: onSelectNarrator
            )
        }
    }

    @ViewBuilder
    private var bottomLoadMoreFooter: some View {
        Group {
            if isLoadingMore {
                HStack(spacing: DSSpacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载更多…")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            } else if loadMoreError != nil {
                Button(action: onRetryLoadMore) {
                    Text("加载失败，点按重试")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, DSSpacing.xs)
                        .background(Capsule().fill(DSColors.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            } else if canLoadMore {
                Color.clear
                    .onAppear {
                        if let lastID = books.last?.id {
                            onReachLoadMoreTrigger(lastID)
                        }
                    }
            } else if !books.isEmpty {
                Text("已加载全部")
                    .font(DSTypography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .padding(.top, DSSpacing.xs)
    }
}
