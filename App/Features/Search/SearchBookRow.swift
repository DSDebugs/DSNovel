import DSCore
import DSDesignSystem
import SwiftUI

/// 搜索页专属封面 + 右上角斜角「已在书架」丝带（独立于发现页与公共 DSBookRow）
struct SearchCoverWithShelfRibbon: View {
    let book: BookSummaryDTO
    let pipeline: CoverImagePipeline
    let side: CGFloat
    let inShelf: Bool

    private var cornerRadius: CGFloat { DSRadius.cover(forSide: side) }
    private var ribbonWidth: CGFloat { max(46, min(72, side * 0.86)) }
    private var ribbonHeight: CGFloat { side >= 64 ? 14 : 12 }
    private var ribbonOffsetX: CGFloat { side >= 64 ? 15 : 12 }
    private var ribbonOffsetY: CGFloat { side >= 64 ? 8 : 6 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DSCover(
                url: book.coverURL,
                title: book.title,
                pipeline: pipeline,
                side: side,
                badges: [],
                showsBorder: true,
                showsSoftShadow: false
            )

            if inShelf {
                Text("已在书架")
                    .font(DSTypography.caption2.weight(.bold))
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .frame(width: ribbonWidth, height: ribbonHeight)
                    .background(DSColors.accent)
                    .rotationEffect(.degrees(45))
                    .offset(x: ribbonOffsetX, y: ribbonOffsetY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 搜索页专属结果行（72pt 方形封面 + 斜角书架丝带 + 紧贴书名/可点主播/状态行/书源徽章）
struct SearchBookRow: View {
    let book: BookSummaryDTO
    let pipeline: CoverImagePipeline
    let inShelf: Bool
    let onTap: () -> Void
    let onNarratorTap: (String) -> Void

    private static let coverSide: CGFloat = 72

    private var narratorText: String {
        let n = book.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        return book.author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusText: String {
        let raw = book.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            return raw.replacingOccurrences(of: "\u{96C6}", with: "章")
        }
        if book.totalChapters > 0 {
            return "\(book.totalChapters) 章"
        }
        return ""
    }

    private var displaySourceName: String {
        book.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let narrator = narratorText
        let status = statusText
        let sourceName = displaySourceName

        HStack(alignment: .center, spacing: DSSpacing.sm) {
            Button(action: onTap) {
                SearchCoverWithShelfRibbon(
                    book: book,
                    pipeline: pipeline,
                    side: Self.coverSide,
                    inShelf: inShelf
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onTap) {
                    Text(book.title)
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !narrator.isEmpty {
                    Button {
                        onNarratorTap(narrator)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(DSTypography.caption2.weight(.semibold))
                            Text(narrator)
                                .font(DSTypography.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(DSColors.accent)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("搜索主播 \(narrator)")
                }

                if !sourceName.isEmpty || !status.isEmpty {
                    HStack(spacing: DSSpacing.xs) {
                        if !sourceName.isEmpty {
                            DSSourceBadge(name: sourceName, showHealthAndLatency: false)
                                .layoutPriority(1)
                        }
                        if !status.isEmpty {
                            Text(status)
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(DSColors.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DSSpacing.xs)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator.opacity(0.45))
                .frame(height: 0.5)
                .padding(.leading, Self.coverSide + DSSpacing.sm)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(inShelf ? "\(book.title)，已在书架" : book.title)
    }
}
