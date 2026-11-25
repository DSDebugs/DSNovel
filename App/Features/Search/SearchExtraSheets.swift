import DSCore
import DSDesignSystem
import SwiftUI

/// 紧凑无框热门书籍推荐区（42pt 封面 + 前三赤陶序号 + 极简演播与书源文字标 + 细分隔线，单屏可见约 9 本）
struct HotBooksSection: View {
    let books: [BookSummaryDTO]
    let isLoading: Bool
    let priorityCaption: String
    let shelfBookIDs: Set<String>
    let pipeline: CoverImagePipeline
    private let onSelectBook: (BookSummaryDTO) -> Void
    private let onSelectNarrator: (String) -> Void

    init(
        books: [BookSummaryDTO],
        isLoading: Bool,
        priorityCaption: String = "",
        shelfBookIDs: Set<String> = [],
        pipeline: CoverImagePipeline,
        onSelectBook: @escaping (BookSummaryDTO) -> Void,
        onSelectNarrator: @escaping (String) -> Void
    ) {
        self.books = books
        self.isLoading = isLoading
        self.priorityCaption = priorityCaption
        self.shelfBookIDs = shelfBookIDs
        self.pipeline = pipeline
        self.onSelectBook = onSelectBook
        self.onSelectNarrator = onSelectNarrator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("热门书籍")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer(minLength: 8)
                if !priorityCaption.isEmpty {
                    Text(priorityCaption)
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)

            if isLoading && books.isEmpty {
                DSSkeleton(mode: .list(rows: 6))
            } else if !books.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        hotBookRow(rank: index + 1, book: book)
                        if index + 1 < books.count {
                            Divider()
                                .overlay(DSColors.separator.opacity(0.28))
                                .padding(.leading, 74)
                        }
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
            }
        }
    }

    private func hotBookRow(rank: Int, book: BookSummaryDTO) -> some View {
        let rawNarrator = book.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        let narrator = rawNarrator.isEmpty ? book.author.trimmingCharacters(in: .whitespacesAndNewlines) : rawNarrator
        let sourceName = book.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: DSSpacing.sm) {
            Text("\(rank)")
                .font(DSTypography.callout.weight(rank <= 3 ? .bold : .medium).monospacedDigit())
                .foregroundStyle(rank <= 3 ? DSColors.accent : DSColors.inkSecondary)
                .frame(width: 22, alignment: .center)

            SearchCoverWithShelfRibbon(
                book: book,
                pipeline: pipeline,
                side: 44,
                inShelf: shelfBookIDs.contains(book.id)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(DSTypography.subtitle.weight(.medium))
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: DSSpacing.xs) {
                    if !narrator.isEmpty {
                        Button {
                            onSelectNarrator(narrator)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "mic.fill")
                                    .font(DSTypography.caption2)
                                Text(narrator)
                                    .lineLimit(1)
                            }
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.accent.opacity(0.92))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("搜索演播 \(narrator)")
                    }

                    Spacer(minLength: 6)

                    if !sourceName.isEmpty {
                        Text(sourceName)
                            .font(DSTypography.caption2)
                            .foregroundStyle(DSColors.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            Button {
                onSelectBook(book)
            } label: {
                Color.clear
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开书籍：\(book.title)")
        )
        .accessibilityAction(named: "打开书籍") {
            onSelectBook(book)
        }
    }
}

/// 搜索页热门推荐词组件（全源离线或无热门书籍时的兜底推荐）
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

/// 失败书源详情半屏弹窗（支持查看原因、单源本次跳过与一键重试）
struct FailedSourcesSheet: View {
    let failedItems: [SearchFailedSourceItem]
    private let onSkipSource: (SearchFailedSourceItem) -> Void
    private let onRetryAll: () -> Void
    private let onDismiss: () -> Void

    init(
        failedItems: [SearchFailedSourceItem],
        onSkipSource: @escaping (SearchFailedSourceItem) -> Void,
        onRetryAll: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.failedItems = failedItems
        self.onSkipSource = onSkipSource
        self.onRetryAll = onRetryAll
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            List {
                Section("失败明细（\(failedItems.count) 个书源）") {
                    ForEach(failedItems) { item in
                        HStack(alignment: .top, spacing: DSSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DSColors.warning)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.sourceName)
                                    .font(DSTypography.rowTitle)
                                    .foregroundStyle(DSColors.inkPrimary)
                                Text(item.reason)
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.inkSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Button {
                                DSHaptics.selection()
                                onSkipSource(item)
                            } label: {
                                Text("本次跳过")
                                    .font(DSTypography.caption.weight(.semibold))
                                    .foregroundStyle(DSColors.accent)
                                    .padding(.horizontal, DSSpacing.xs)
                                    .frame(minHeight: 34)
                                    .background(Capsule().fill(DSColors.accent.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
            .navigationTitle("书源失败详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("重试全部") {
                        onDismiss()
                        onRetryAll()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
