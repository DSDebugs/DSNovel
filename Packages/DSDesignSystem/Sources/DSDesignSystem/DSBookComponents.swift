import DSCore
import SwiftUI
import UIKit

/// 纯橙色单字书源头像（兼容 v3.0 `DSSourceAvatar(name:)` 与 v2.8 `DSSourceAvatar(name:size:)`）
public struct DSSourceAvatar: View {
    private let name: String
    private let fixedSize: CGFloat?
    @ScaledMetric(relativeTo: .caption) private var scaledSize: CGFloat = 24

    public init(name: String, size: CGFloat? = nil) {
        self.name = name
        self.fixedSize = size
    }

    public static func initialCharacter(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "源" }
        return String(first)
    }

    public var body: some View {
        let size = fixedSize ?? scaledSize
        let font: Font = size >= 30 ? DSTypography.cardTitle : DSTypography.caption.weight(.bold)
        Text(Self.initialCharacter(for: name))
            .font(font)
            .foregroundStyle(DSColors.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(DSColors.accent, in: Circle())
            .accessibilityHidden(true)
    }
}

/// 书架/发现通用卡片（1:1 正方形封面、按压缩放、编辑/置顶/演播点击，完全向后兼容 v3.0 调用）
public struct DSBookCard: View {
    private let book: BookSummaryDTO
    private let pipeline: CoverImagePipeline
    private let side: CGFloat?
    private let isPinned: Bool
    private let isEditing: Bool
    private let isSelected: Bool
    private let progressFraction: Double
    private let isDownloaded: Bool
    private let hasUpdate: Bool
    private let isVIP: Bool
    private let isPlaying: Bool
    private let progressSubtitle: String
    private let sourceName: String?
    private let showsSoftShadow: Bool
    private let onNarratorTap: ((String) -> Void)?
    private let onCoverLoaded: ((UIImage) -> Void)?
    private let onTap: () -> Void

    public init(
        book: BookSummaryDTO,
        pipeline: CoverImagePipeline,
        side: CGFloat? = nil,
        isPinned: Bool = false,
        isEditing: Bool = false,
        isSelected: Bool = false,
        progressFraction: Double = 0,
        isDownloaded: Bool = false,
        hasUpdate: Bool = false,
        isVIP: Bool = false,
        isPlaying: Bool = false,
        progressSubtitle: String = "",
        sourceName: String? = nil,
        showsSoftShadow: Bool = false,
        onNarratorTap: ((String) -> Void)? = nil,
        onCoverLoaded: ((UIImage) -> Void)? = nil,
        onTap: @escaping () -> Void
    ) {
        self.book = book
        self.pipeline = pipeline
        self.side = side
        self.isPinned = isPinned
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.progressFraction = progressFraction
        self.isDownloaded = isDownloaded
        self.hasUpdate = hasUpdate
        self.isVIP = isVIP
        self.isPlaying = isPlaying
        self.progressSubtitle = progressSubtitle
        self.sourceName = sourceName
        self.showsSoftShadow = showsSoftShadow
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

    private var narratorOrAuthor: String {
        DSMetadataSanitizer.displayNarratorOrAuthor(author: book.author, narrator: book.narrator)
    }

    private var isLargeCard: Bool {
        (side ?? 112) >= 145
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    ZStack(alignment: .topLeading) {
                        coverView
                        stateOverlay
                    }

                    Text(book.title)
                        .font(isLargeCard ? DSTypography.cardTitle : DSTypography.footnote.weight(.medium))
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            subtitleView
        }
        .frame(width: side, alignment: .topLeading)
        .frame(maxWidth: side == nil ? .infinity : nil, alignment: .topLeading)
    }

    @ViewBuilder
    private var coverView: some View {
        if let fixedSide = side {
            DSCover(
                url: book.coverURL,
                title: book.title,
                pipeline: pipeline,
                side: fixedSide,
                badges: coverBadges,
                showsBorder: !showsSoftShadow,
                showsSoftShadow: showsSoftShadow,
                onImageLoaded: onCoverLoaded
            )
        } else {
            DSCoverImage(
                urlString: book.coverURL,
                pipeline: pipeline,
                cornerRadius: DSRadius.coverLarge,
                title: book.title,
                badges: coverBadges,
                showsBorder: !showsSoftShadow,
                showsSoftShadow: showsSoftShadow,
                onCoverLoaded: onCoverLoaded
            )
            .aspectRatio(1, contentMode: .fit)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if isEditing {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(DSTypography.headline)
                .foregroundStyle(isSelected ? DSColors.accent : .white)
                .padding(DSSpacing.xs)
                .shadow(radius: 2)
        } else if isPinned {
            Image(systemName: "pin.fill")
                .font(DSTypography.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .padding(DSSpacing.xxs)
        }
    }

    @ViewBuilder
    private var subtitleView: some View {
        let credit = narratorOrAuthor
        let captionText = progressSubtitle.isEmpty ? credit : progressSubtitle
        if isPlaying {
            Text(captionText.isEmpty ? "正在播放" : captionText)
                .font(isLargeCard ? DSTypography.numericCaption : DSTypography.caption2.monospacedDigit())
                .foregroundStyle(DSColors.accent)
                .lineLimit(1)
        } else if let onNarratorTap, !credit.isEmpty, !isEditing, progressSubtitle.isEmpty {
            Button {
                onNarratorTap(credit)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "mic.fill")
                        .font(DSTypography.caption2)
                    Text(credit)
                        .lineLimit(1)
                }
                .font(DSTypography.numericCaption)
                .foregroundStyle(DSColors.accent)
            }
            .buttonStyle(.plain)
        } else if !captionText.isEmpty {
            Text(captionText)
                .font(isLargeCard ? DSTypography.numericCaption : DSTypography.caption2.monospacedDigit())
                .foregroundStyle(DSColors.inkSecondary)
                .lineLimit(1)
        }
    }
}

/// 带 44pt 一键清空按钮的通用搜索/筛选输入框（v3.0 既有公开组件全量保留）
public struct DSClearableSearchField: View {
    private let placeholder: String
    @Binding private var text: String
    private let onSubmit: (() -> Void)?

    public init(_ placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DSColors.inkSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DSColors.inkSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空输入")
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(minHeight: 44)
        .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous))
    }
}
