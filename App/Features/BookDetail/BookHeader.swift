import DSCore
import DSDesignSystem
import SwiftUI
import UIKit

/// 书籍详情头部（1:1 复刻 v2.8：128×128 正方形封面 + 右侧 4 层信息）
struct BookHeader: View {
    let book: BookSummaryDTO
    let pipeline: CoverImagePipeline
    let sourceName: String
    let totalChapters: Int
    let statusText: String
    private let onTapNarrator: (String) -> Void
    private let onCoverLoaded: (UIImage) -> Void

    private static let coverSide: CGFloat = 128

    init(
        book: BookSummaryDTO,
        pipeline: CoverImagePipeline,
        sourceName: String,
        totalChapters: Int,
        statusText: String,
        onTapNarrator: @escaping (String) -> Void,
        onCoverLoaded: @escaping (UIImage) -> Void = { _ in }
    ) {
        self.book = book
        self.pipeline = pipeline
        self.sourceName = sourceName
        self.totalChapters = totalChapters
        self.statusText = statusText
        self.onTapNarrator = onTapNarrator
        self.onCoverLoaded = onCoverLoaded
    }

    private var titleParts: (main: String, tags: [String]) {
        BookTitleFormatter.split(BookTitleFormatter.cleanTitle(book.title))
    }

    private var narratorTarget: String {
        let n = book.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        return book.author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var narratorLabel: String {
        BookTitleFormatter.narratorDisplay(author: book.author, narrator: book.narrator)
    }

    private var chapterCountText: String? {
        var parts: [String] = []
        let trimmedStatus = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStatus.isEmpty { parts.append(trimmedStatus) }
        if totalChapters > 0 { parts.append("\(totalChapters) 章") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        let parts = titleParts
        let target = narratorTarget
        let label = narratorLabel

        HStack(alignment: .top, spacing: DSSpacing.md) {
            DSCover(
                url: book.coverURL,
                title: book.title,
                pipeline: pipeline,
                side: Self.coverSide,
                badges: [],
                onImageLoaded: onCoverLoaded
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 0) {
                Text(parts.main)
                    .font(DSTypography.bookTitleLarge)
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !parts.tags.isEmpty {
                    Text(parts.tags.joined(separator: " · "))
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(2)
                        .padding(.top, 3)
                }

                Spacer(minLength: DSSpacing.xs)

                if !target.isEmpty {
                    Button {
                        onTapNarrator(target)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(DSTypography.caption2)
                            Text(label.isEmpty ? target : label)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2)
                        }
                        .font(DSTypography.subtitle.weight(.medium))
                        .foregroundStyle(DSColors.accent)
                        .frame(minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("搜索演播人 \(target)")
                }

                HStack(spacing: DSSpacing.xs) {
                    if !sourceName.isEmpty {
                        DSSourceBadge(
                            name: sourceName,
                            health: .untested,
                            latencyMs: nil,
                            showHealthAndLatency: false
                        )
                        .layoutPriority(1)
                    }
                    if let chapterCountText {
                        Text(chapterCountText)
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(DSColors.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, DSSpacing.xs)
            }
            .frame(maxWidth: .infinity, minHeight: Self.coverSide, alignment: .topLeading)
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }
}
