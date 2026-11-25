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

    private static let coverSide: CGFloat = 108

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

    private var cleanStatusTag: String? {
        let raw = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let first = raw.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        if first.contains("完结") { return "已完结" }
        if first.contains("连载") { return "连载中" }
        return first.isEmpty ? nil : first
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
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.xs + 2)
                        .frame(minHeight: 26)
                        .background(Capsule().fill(DSColors.accent.opacity(0.14)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, DSSpacing.xs)
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
                    if let status = cleanStatusTag {
                        DSBadge(status, style: .neutral)
                    }
                }
                .padding(.top, DSSpacing.xs)
            }
            .frame(maxWidth: .infinity, minHeight: Self.coverSide, alignment: .topLeading)
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }
}
