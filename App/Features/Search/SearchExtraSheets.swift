import DSCore
import DSDesignSystem
import SwiftUI

/// 搜索页热门书籍推荐区（1:1 复刻 v2.8 HotBooksSection：榜单排名 + 52pt 封面 + 可点演播人胶囊）
struct HotBooksSection: View {
    let books: [BookSummaryDTO]
    let sourceName: String
    let isLoading: Bool
    let pipeline: CoverImagePipeline
    private let onSelectBook: (BookSummaryDTO) -> Void
    private let onSelectNarrator: (String) -> Void
    private let onRefresh: () -> Void

    init(
        books: [BookSummaryDTO],
        sourceName: String,
        isLoading: Bool,
        pipeline: CoverImagePipeline,
        onSelectBook: @escaping (BookSummaryDTO) -> Void,
        onSelectNarrator: @escaping (String) -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.books = books
        self.sourceName = sourceName
        self.isLoading = isLoading
        self.pipeline = pipeline
        self.onSelectBook = onSelectBook
        self.onSelectNarrator = onSelectNarrator
        self.onRefresh = onRefresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            DSSectionHeader(
                title: "热门书籍",
                subtitle: sourceName.isEmpty ? nil : "来自 \(sourceName)",
                actionTitle: books.isEmpty ? nil : "刷新",
                onAction: books.isEmpty ? nil : onRefresh
            )

            if isLoading && books.isEmpty {
                DSSkeleton(mode: .list(rows: 5))
            } else if !books.isEmpty {
                LazyVStack(spacing: DSSpacing.xs) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        hotBookRow(rank: index + 1, book: book)
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
            }
        }
    }

    private func hotBookRow(rank: Int, book: BookSummaryDTO) -> some View {
        let rawNarrator = book.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        let narrator = rawNarrator.isEmpty ? book.author.trimmingCharacters(in: .whitespacesAndNewlines) : rawNarrator

        return HStack(spacing: DSSpacing.sm) {
            Text("\(rank)")
                .font(DSTypography.numericCaption.weight(.bold))
                .foregroundStyle(rank <= 3 ? DSColors.accent : DSColors.inkSecondary)
                .frame(width: 24, alignment: .center)

            DSCover(
                url: book.coverURL,
                title: book.title,
                pipeline: pipeline,
                side: 52
            )

            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(book.title)
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !narrator.isEmpty {
                    Button {
                        onSelectNarrator(narrator)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(DSTypography.caption2)
                            Text(narrator)
                                .lineLimit(1)
                        }
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.xs)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DSColors.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityLabel("搜索演播 \(narrator)")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpacing.xs)
        .padding(.horizontal, DSSpacing.sm)
        .background(
            Button {
                onSelectBook(book)
            } label: {
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(DSColors.surfaceCard)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开书籍：\(book.title)")
        )
        .accessibilityAction(named: "打开书籍") {
            onSelectBook(book)
        }
    }
}

/// 搜索页热门推荐词组件（热门书籍列表为空时的兜底推荐）
struct HotBooksPanel: View {
    private let keywords: [String]
    private let onPick: (String) -> Void

    init(
        keywords: [String] = ["凡人修仙传", "三体", "雪中悍刀行", "诡秘之主", "盗墓笔记", "明朝那些事儿"],
        onPick: @escaping (String) -> Void
    ) {
        self.keywords = keywords
        self.onPick = onPick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            DSSectionHeader(title: "热门搜索")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: DSSpacing.xs)], spacing: DSSpacing.xs) {
                ForEach(keywords, id: \.self) { kw in
                    Button {
                        onPick(kw)
                    } label: {
                        Text(kw)
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(DSColors.surfaceCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
        }
    }
}

/// 搜索失败书源详情弹窗（1:1 复刻 v2.8 FailedSourcesSheet：展示原因、暂时跳过与全部重试）
struct FailedSourcesSheet: View {
    @Environment(DSBannerCoordinator.self) private var banner
    private let failedItems: [SearchFailedSourceItem]
    private let onSkipSource: ((SearchFailedSourceItem) -> Void)?
    private let onRetryAll: () -> Void
    private let onDismiss: () -> Void

    init(
        failedItems: [SearchFailedSourceItem],
        onSkipSource: ((SearchFailedSourceItem) -> Void)? = nil,
        onRetryAll: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.failedItems = failedItems
        self.onSkipSource = onSkipSource
        self.onRetryAll = onRetryAll
        self.onDismiss = onDismiss
    }

    init(failedSourceNames: [String], onRetryAll: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.failedItems = failedSourceNames.enumerated().map { idx, name in
            SearchFailedSourceItem(id: "\(idx)-\(name)", sourceID: "\(idx)-\(name)", sourceName: name, reason: "请求超时或解析异常")
        }
        self.onSkipSource = nil
        self.onRetryAll = onRetryAll
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "失败书源详情（\(failedItems.count)）", banner: banner, onDismiss: onDismiss) {
            List {
                Section("本次搜索超时或解析异常的书源") {
                    ForEach(failedItems) { item in
                        HStack(spacing: DSSpacing.sm) {
                            DSSourceAvatar(name: item.sourceName)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.sourceName)
                                    .font(DSTypography.rowTitle)
                                Text(item.reason)
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.inkSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if let onSkipSource {
                                Button("暂时跳过") {
                                    onSkipSource(item)
                                }
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.inkSecondary)
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(minHeight: 44)
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }
                Section {
                    Button("全部重试") {
                        onDismiss()
                        onRetryAll()
                    }
                    .font(DSTypography.body.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .listRowBackground(DSColors.surfaceCard)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
        }
    }
}
