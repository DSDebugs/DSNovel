import DSCore
import SwiftUI
import UIKit

/// 异步封面视图（无边框柔和阴影，接入 CoverImagePipeline）
public struct DSCoverImage: View {
    private let urlString: String
    private let pipeline: CoverImagePipeline
    private let cornerRadius: CGFloat
    @State private var image: UIImage?

    public init(urlString: String, pipeline: CoverImagePipeline, cornerRadius: CGFloat = DSRadius.sm) {
        self.urlString = urlString
        self.pipeline = pipeline
        self.cornerRadius = cornerRadius
        _image = State(initialValue: pipeline.cachedImageSync(for: urlString))
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DSColors.surfaceCard)
            .overlay {
                if let uiImage = image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "headphones")
                        .font(DSTypography.headline)
                        .foregroundStyle(DSColors.inkSecondary.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            .task(id: urlString) {
                let cached = pipeline.cachedImageSync(for: urlString)
                image = cached
                if cached != nil { return }
                let loaded = await pipeline.image(for: urlString)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

/// 纯橙色单字书源头像（AUD-60：接入 ScaledMetric 适配动态字号并防截断）
public struct DSSourceAvatar: View {
    private let name: String
    @ScaledMetric(relativeTo: .caption) private var avatarSize: CGFloat = 24

    public init(name: String) {
        self.name = name
    }

    public var body: some View {
        let initial = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
        Text(initial.isEmpty ? "源" : initial)
            .font(DSTypography.caption.weight(.bold))
            .foregroundStyle(DSColors.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: avatarSize, height: avatarSize)
            .background(DSColors.accent, in: Circle())
            .accessibilityHidden(true)
    }
}

/// 书架/发现通用卡片（紧凑 4pt 标题到演播间距，零 onTapGesture，AX1–AX5 自适应）
public struct DSBookCard: View {
    private let book: BookSummaryDTO
    private let pipeline: CoverImagePipeline
    private let onTap: () -> Void

    public init(book: BookSummaryDTO, pipeline: CoverImagePipeline, onTap: @escaping () -> Void) {
        self.book = book
        self.pipeline = pipeline
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                DSCoverImage(urlString: book.coverURL, pipeline: pipeline, cornerRadius: DSRadius.md)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                Text(book.title)
                    .font(DSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !book.narrator.isEmpty || !book.author.isEmpty {
                    Text(book.narrator.isEmpty ? book.author : book.narrator)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// 列表行书籍视图（最小 44pt 触控高度）
public struct DSBookRow: View {
    private let book: BookSummaryDTO
    private let subtitle: String?
    private let pipeline: CoverImagePipeline
    private let onTap: () -> Void

    public init(
        book: BookSummaryDTO,
        subtitle: String? = nil,
        pipeline: CoverImagePipeline,
        onTap: @escaping () -> Void
    ) {
        self.book = book
        self.subtitle = subtitle
        self.pipeline = pipeline
        self.onTap = onTap
    }

    private var metaText: String {
        switch (book.author.isEmpty, book.narrator.isEmpty) {
        case (false, false): return "\(book.author) · \(book.narrator)"
        case (false, true): return book.author
        case (true, false): return book.narrator
        case (true, true): return ""
        }
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: DSSpacing.sm) {
                DSCoverImage(urlString: book.coverURL, pipeline: pipeline, cornerRadius: DSRadius.sm)
                    .frame(width: 54, height: 72)
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(book.title)
                        .font(DSTypography.headline)
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(2)
                    let meta = metaText
                    if !meta.isEmpty {
                        Text(meta)
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                            .lineLimit(1)
                    }
                    if let sub = subtitle ?? (book.latestChapter.isEmpty ? nil : book.latestChapter) {
                        Text(sub)
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 统一空态 / 错误态视图
public struct DSStateView: View {
    private let icon: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: icon)
                .font(DSTypography.largeTitle)
                .foregroundStyle(DSColors.inkSecondary)
            Text(title)
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.inkPrimary)
            Text(message)
                .font(DSTypography.footnote)
                .foregroundStyle(DSColors.inkSecondary)
                .multilineTextAlignment(.center)
            if let btnTitle = actionTitle, let act = action {
                Button(btnTitle, action: act)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}

/// 带 44pt 一键清空按钮的通用搜索/筛选输入框（UX2-05/AUD-60）
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
        .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }
}
