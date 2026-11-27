import DSCore
import SwiftUI
import UIKit

/// 列表行书籍视图（1:1 正方形 64pt 封面、最小 44pt 触控高度、兼容 v3.0 全部调用）
public struct DSBookRow: View {
    private let book: BookSummaryDTO
    private let subtitle: String?
    private let pipeline: CoverImagePipeline
    private let sourceName: String?
    private let isPinned: Bool
    private let isEditing: Bool
    private let isSelected: Bool
    private let progressFraction: Double
    private let isDownloaded: Bool
    private let hasUpdate: Bool
    private let isVIP: Bool
    private let isPlaying: Bool
    private let onPlayTap: (() -> Void)?
    private let onNarratorTap: ((String) -> Void)?
    private let onCoverLoaded: ((UIImage) -> Void)?
    private let onTap: () -> Void

    public init(
        book: BookSummaryDTO,
        subtitle: String? = nil,
        pipeline: CoverImagePipeline,
        sourceName: String? = nil,
        isPinned: Bool = false,
        isEditing: Bool = false,
        isSelected: Bool = false,
        progressFraction: Double = 0,
        isDownloaded: Bool = false,
        hasUpdate: Bool = false,
        isVIP: Bool = false,
        isPlaying: Bool = false,
        onPlayTap: (() -> Void)? = nil,
        onNarratorTap: ((String) -> Void)? = nil,
        onCoverLoaded: ((UIImage) -> Void)? = nil,
        onTap: @escaping () -> Void
    ) {
        self.book = book
        self.subtitle = subtitle
        self.pipeline = pipeline
        self.sourceName = sourceName
        self.isPinned = isPinned
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.progressFraction = progressFraction
        self.isDownloaded = isDownloaded
        self.hasUpdate = hasUpdate
        self.isVIP = isVIP
        self.isPlaying = isPlaying
        self.onPlayTap = onPlayTap
        self.onNarratorTap = onNarratorTap
        self.onCoverLoaded = onCoverLoaded
        self.onTap = onTap
    }

    private var coverBadges: [DSCoverBadge] {
        var list: [DSCoverBadge] = []
        if progressFraction > 0 { list.append(.progress(progressFraction)) }
        if isDownloaded { list.append(.downloaded) }
        if hasUpdate { list.append(.updated) }
        if isVIP { list.append(.vip) }
        return list
    }

    private var metaText: String {
        let a = DSMetadataSanitizer.cleanPersonName(book.author)
        let n = DSMetadataSanitizer.cleanPersonName(book.narrator)
        switch (a.isEmpty, n.isEmpty) {
        case (false, false): return a.lowercased() == n.lowercased() ? n : "\(a) · \(n)"
        case (false, true): return a
        case (true, false): return n
        case (true, true): return ""
        }
    }

    private var resolvedSourceName: String {
        if let sourceName, !sourceName.isEmpty { return sourceName }
        return book.sourceName
    }

    private var resolvedSubtitle: String? {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return book.latestChapter.isEmpty ? nil : book.latestChapter
    }

    private var narratorTarget: String {
        DSMetadataSanitizer.displayNarratorOrAuthor(author: book.author, narrator: book.narrator)
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: onTap) {
                HStack(spacing: DSSpacing.sm) {
                    if isEditing {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkSecondary)
                    }
                    DSCover(
                        url: book.coverURL,
                        title: book.title,
                        pipeline: pipeline,
                        side: 64,
                        badges: coverBadges,
                        onImageLoaded: onCoverLoaded
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Button(action: onTap) {
                    HStack(spacing: DSSpacing.xxs) {
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(DSTypography.caption2)
                                .foregroundStyle(DSColors.accent)
                        }
                        Text(book.title)
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                authorSection

                if !resolvedSourceName.isEmpty || resolvedSubtitle != nil || isPlaying {
                    Button(action: onTap) {
                        HStack(spacing: DSSpacing.xs) {
                            if !resolvedSourceName.isEmpty {
                                DSSourceBadge(
                                    name: resolvedSourceName,
                                    latencyMs: nil,
                                    showHealthAndLatency: false
                                )
                                .layoutPriority(1)
                            }
                            if let sub = resolvedSubtitle {
                                Text(sub)
                                    .font(DSTypography.numericCaption)
                                    .foregroundStyle(isPlaying ? DSColors.accent : DSColors.inkSecondary)
                                    .lineLimit(1)
                            } else if isPlaying {
                                Text("正在播放")
                                    .font(DSTypography.numericCaption)
                                    .foregroundStyle(DSColors.accent)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onPlayTap, !isEditing {
                Button(action: onPlayTap) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(DSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(DSColors.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(DSColors.accent))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "暂停 \(book.title)" : "继续收听 \(book.title)")
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, DSSpacing.xxs)
    }

    @ViewBuilder
    private var authorSection: some View {
        let meta = metaText
        let target = narratorTarget
        if !meta.isEmpty {
            if let onNarratorTap, !target.isEmpty, !isEditing {
                HStack(spacing: 0) {
                    Button {
                        onNarratorTap(target)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "mic.fill")
                                .font(DSTypography.caption2)
                            Text(meta)
                                .lineLimit(1)
                        }
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.accent)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: onTap) {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: onTap) {
                    Text(meta)
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
