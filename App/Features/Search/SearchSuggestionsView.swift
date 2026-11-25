import DSCore
import DSDesignSystem
import Foundation
import SwiftUI

/// 实时联想搜索视图（顶部 1–3 张直达书籍卡片 + 下方高亮联想词列表，滑动自动收起键盘）
struct SearchSuggestionsView: View {
    let query: String
    let directBooks: [BookSummaryDTO]
    let keywords: [SearchSuggestionItem]
    let isLoading: Bool
    let shelfBookIDs: Set<String>
    let pipeline: CoverImagePipeline
    let onSelectBook: (BookSummaryDTO) -> Void
    let onSelectKeyword: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !directBooks.isEmpty {
                    VStack(spacing: DSSpacing.xs) {
                        ForEach(directBooks) { book in
                            directBookCard(book)
                        }
                    }
                    .padding(.horizontal, DSSpacing.pageHorizontal)
                    .padding(.top, DSSpacing.xs)
                    .padding(.bottom, DSSpacing.sm)

                    if !keywords.isEmpty {
                        Divider()
                            .padding(.horizontal, DSSpacing.pageHorizontal)
                    }
                }

                ForEach(keywords) { item in
                    suggestionRow(item)
                    Divider()
                        .padding(.leading, DSSpacing.pageHorizontal + 26)
                        .padding(.trailing, DSSpacing.pageHorizontal)
                }

                if isLoading && directBooks.isEmpty && keywords.isEmpty {
                    HStack(spacing: DSSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("正在联想相关书籍与关键词…")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpacing.lg)
                } else if !isLoading && directBooks.isEmpty && keywords.isEmpty {
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Button {
                            DSHaptics.selection()
                            onSelectKeyword(trimmed)
                        } label: {
                            HStack(spacing: DSSpacing.sm) {
                                Image(systemName: "magnifyingglass")
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.accent)
                                    .frame(width: 18)
                                Text("直接搜索「\(trimmed)」")
                                    .font(DSTypography.body)
                                    .foregroundStyle(DSColors.accent)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, DSSpacing.pageHorizontal)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("直接搜索 \(trimmed)")
                    }
                }
            }
            .padding(.bottom, DSSpacing.md)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func directBookCard(_ book: BookSummaryDTO) -> some View {
        let narrator = DSMetadataSanitizer.displayNarratorOrAuthor(author: book.author, narrator: book.narrator)
        let sourceName = book.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)

        return Button {
            DSHaptics.selection()
            onSelectBook(book)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                SearchCoverWithShelfRibbon(
                    book: book,
                    pipeline: pipeline,
                    side: 52,
                    inShelf: shelfBookIDs.contains(book.id)
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(highlightedText(book.title, match: query))
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: DSSpacing.xs) {
                        if !narrator.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "mic.fill")
                                    .font(DSTypography.caption2)
                                Text(narrator)
                                    .lineLimit(1)
                            }
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.accent)
                            .padding(.horizontal, DSSpacing.xs)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DSColors.accent.opacity(0.12)))
                        }

                        Spacer(minLength: 4)

                        if !sourceName.isEmpty {
                            Text(sourceName)
                                .font(DSTypography.caption2)
                                .foregroundStyle(DSColors.inkSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(DSColors.surfaceGrouped))
                        }
                    }
                }
            }
            .padding(.vertical, DSSpacing.xs)
            .padding(.horizontal, DSSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(DSColors.surfaceCard)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("直达书籍：\(book.title)")
    }

    private func suggestionRow(_ item: SearchSuggestionItem) -> some View {
        Button {
            DSHaptics.selection()
            onSelectKeyword(item.text)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: item.isFromHistory ? "clock" : "magnifyingglass")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(width: 18)

                Text(highlightedText(item.text, match: query))
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索建议：\(item.text)")
    }

    private func highlightedText(_ source: String, match: String) -> AttributedString {
        var attributed = AttributedString(source)
        let term = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return attributed }

        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: term, options: .caseInsensitive) {
            attributed[range].foregroundColor = DSColors.accent
            searchStart = range.upperBound
        }
        return attributed
    }
}
