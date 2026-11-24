import DSCore
import DSDesignSystem
import SwiftUI

/// 发现页专属书籍展示数据整理（与搜索/书架解耦，统一书名、可点主播、连载状态与书架丝带）
enum DiscoverBookDisplayHelper {
    static func narratorText(for book: BookSummaryDTO) -> String {
        let n = book.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        return book.author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func statusLine(for book: BookSummaryDTO) -> String {
        let raw = book.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            return raw.replacingOccurrences(of: "\u{96C6}", with: "章")
        }
        if book.totalChapters > 0 {
            return "\(book.totalChapters) 章"
        }
        return ""
    }
}

/// 封面右上角斜角「已在书架」丝带（严格裁剪在封面圆角内）
struct DiscoverCoverWithShelfRibbon: View {
    let book: BookSummaryDTO
    let pipeline: CoverImagePipeline
    let side: CGFloat
    let inShelf: Bool
    let showsSoftShadow: Bool
    var rankNumber: Int? = nil

    private var cornerRadius: CGFloat { DSRadius.cover(forSide: side) }
    private var ribbonWidth: CGFloat { max(56, min(96, side * 0.68)) }
    private var ribbonHeight: CGFloat { side >= 145 ? 18 : (side >= 95 ? 15 : 13) }
    private var ribbonOffsetX: CGFloat { side >= 145 ? 20 : (side >= 95 ? 16 : 14) }
    private var ribbonOffsetY: CGFloat { side >= 145 ? 11 : (side >= 95 ? 9 : 7.5) }

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
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: ribbonWidth, height: ribbonHeight)
                    .background(DSColors.accent)
                    .rotationEffect(.degrees(45))
                    .offset(x: ribbonOffsetX, y: ribbonOffsetY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if let rank = rankNumber {
                Text("\(rank)")
                    .font(DSTypography.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(rankBadgeColor(for: rank))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: showsSoftShadow ? Color.black.opacity(0.10) : .clear,
            radius: showsSoftShadow ? 6 : 0,
            y: showsSoftShadow ? 3 : 0
        )
    }

    private func rankBadgeColor(for rank: Int) -> Color {
        switch rank {
        case 1: return DSColors.warning
        case 2: return DSColors.inkSecondary
        case 3: return DSColors.accent
        default: return Color.black.opacity(0.62)
        }
    }
}

/// 发现页 3 列网格卡片（方案 A 紧贴流式：书名最多 2 行紧贴可点主播与状态行，零书源名）
struct DiscoverGridCard: View {
    let book: BookSummaryDTO
    let pipeline: CoverImagePipeline
    let side: CGFloat
    let inShelf: Bool
    var rankNumber: Int? = nil
    let onTap: () -> Void
    let onNarratorTap: (String) -> Void

    var body: some View {
        let narrator = DiscoverBookDisplayHelper.narratorText(for: book)
        let status = DiscoverBookDisplayHelper.statusLine(for: book)

        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    DiscoverCoverWithShelfRibbon(
                        book: book,
                        pipeline: pipeline,
                        side: side,
                        inShelf: inShelf,
                        showsSoftShadow: true,
                        rankNumber: rankNumber
                    )

                    Text(book.title)
                        .font(DSTypography.footnote.weight(.semibold))
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            if !narrator.isEmpty {
                Button {
                    onNarratorTap(narrator)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "mic.fill")
                            .font(DSTypography.caption2.weight(.semibold))
                        Text(narrator)
                            .font(DSTypography.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(DSColors.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索主播 \(narrator)")
            }

            if !status.isEmpty {
                Text(status)
                    .font(DSTypography.caption2.monospacedDigit())
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, narrator.isEmpty ? 3 : 1)
            }
        }
        .frame(width: side, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(inShelf ? "\(book.title)，已在书架" : book.title)
    }
}

/// 发现页 2 列大图卡片（方案 A 紧贴流式：与 3 列网格、列表严格统一的 4 项信息，零书源名）
struct DiscoverLargeCard: View {
    let book: BookSummaryDTO
    let pipeline: CoverImagePipeline
    let side: CGFloat
    let inShelf: Bool
    var rankNumber: Int? = nil
    let onTap: () -> Void
    let onNarratorTap: (String) -> Void

    var body: some View {
        let narrator = DiscoverBookDisplayHelper.narratorText(for: book)
        let status = DiscoverBookDisplayHelper.statusLine(for: book)

        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    DiscoverCoverWithShelfRibbon(
                        book: book,
                        pipeline: pipeline,
                        side: side,
                        inShelf: inShelf,
                        showsSoftShadow: true,
                        rankNumber: rankNumber
                    )

                    Text(book.title)
                        .font(DSTypography.callout.weight(.semibold))
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索主播 \(narrator)")
            }

            if !status.isEmpty {
                Text(status)
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, narrator.isEmpty ? 4 : 1)
            }
        }
        .frame(width: side, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(inShelf ? "\(book.title)，已在书架" : book.title)
    }
}

/// 发现页列表行（方案 A 紧贴流式：左 72pt 封面带书架丝带 + 右书名/可点主播/状态行，零书源名）
struct DiscoverListRow: View {
    let book: BookSummaryDTO
    let pipeline: CoverImagePipeline
    let inShelf: Bool
    var rankNumber: Int? = nil
    let onTap: () -> Void
    let onNarratorTap: (String) -> Void

    private static let coverSide: CGFloat = 72

    var body: some View {
        let narrator = DiscoverBookDisplayHelper.narratorText(for: book)
        let status = DiscoverBookDisplayHelper.statusLine(for: book)

        HStack(alignment: .center, spacing: DSSpacing.sm) {
            Button(action: onTap) {
                DiscoverCoverWithShelfRibbon(
                    book: book,
                    pipeline: pipeline,
                    side: Self.coverSide,
                    inShelf: inShelf,
                    showsSoftShadow: false,
                    rankNumber: rankNumber
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

                if !status.isEmpty {
                    Text(status)
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
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
