import SwiftUI

struct BookCardModel: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var author: String
    var sourceName: String
    var coverURL: String
    var progressFraction: Double
    var lastChapterIndex: Int
    var totalChapters: Int
    var progressSubtitle: String
    var isDownloaded: Bool
    var hasUpdate: Bool
    var isVIP: Bool
    var isPinned: Bool
    var inShelf: Bool
    var isPlaying: Bool

    init(
        id: String,
        title: String,
        author: String = "",
        sourceName: String = "",
        coverURL: String = "",
        progressFraction: Double = 0,
        lastChapterIndex: Int = 0,
        totalChapters: Int = 0,
        progressSubtitle: String = "",
        isDownloaded: Bool = false,
        hasUpdate: Bool = false,
        isVIP: Bool = false,
        isPinned: Bool = false,
        inShelf: Bool = false,
        isPlaying: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.sourceName = sourceName
        self.coverURL = coverURL
        self.progressFraction = progressFraction
        self.lastChapterIndex = lastChapterIndex
        self.totalChapters = totalChapters
        self.progressSubtitle = progressSubtitle
        self.isDownloaded = isDownloaded
        self.hasUpdate = hasUpdate
        self.isVIP = isVIP
        self.isPinned = isPinned
        self.inShelf = inShelf
        self.isPlaying = isPlaying
    }

    var badges: [DSCoverBadge] {
        var list: [DSCoverBadge] = []
        if progressFraction > 0 { list.append(.progress(progressFraction)) }
        if isDownloaded { list.append(.downloaded) }
        if hasUpdate { list.append(.updated) }
        if isVIP { list.append(.vip) }
        return list
    }

    var accessibilitySummary: String {
        let authorPart = author.isEmpty ? "未知作者" : author
        if lastChapterIndex > 0 {
            return "\(title)，\(authorPart)，已听到第 \(lastChapterIndex) 章"
        }
        return "\(title)，\(authorPart)"
    }
}

struct DSBookCard: View {
    let model: BookCardModel
    let side: CGFloat
    let isEditing: Bool
    let isSelected: Bool
    let usesSoftCoverShadow: Bool
    private let onAction: () -> Void
    private let onNarratorTap: ((String) -> Void)?

    init(
        model: BookCardModel,
        side: CGFloat = 108,
        isEditing: Bool = false,
        isSelected: Bool = false,
        usesSoftCoverShadow: Bool = false,
        onAction: @escaping () -> Void = {},
        onNarratorTap: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.side = side
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.usesSoftCoverShadow = usesSoftCoverShadow
        self.onAction = onAction
        self.onNarratorTap = onNarratorTap
    }

    private var isLargeCard: Bool {
        side >= 145
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            Button(action: onAction) {
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    ZStack(alignment: .topLeading) {
                        DSCover(
                            url: model.coverURL,
                            title: model.title,
                            side: side,
                            badges: model.badges,
                            showsBorder: !usesSoftCoverShadow,
                            showsSoftShadow: usesSoftCoverShadow
                        )

                        if isEditing {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.headline)
                                .foregroundStyle(isSelected ? Color.dsAccent : .white)
                                .padding(Spacing.s2)
                                .shadow(radius: 2)
                        } else if model.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                                .padding(Spacing.s1)
                        }
                    }

                    Text(model.title)
                        .font(isLargeCard ? DSTypography.cardTitle : .footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: side, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            if model.progressSubtitle.isEmpty && !model.author.isEmpty && !isEditing {
                Button {
                    if let onNarratorTap {
                        onNarratorTap(model.author)
                    } else {
                        AppRouter.shared.searchByNarrator(model.author)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "mic.fill")
                            .font(DSTypography.caption2)
                        Text(model.author)
                            .lineLimit(1)
                    }
                    .font(isLargeCard ? DSTypography.numericCaption : DSTypography.caption2.monospacedDigit())
                    .foregroundStyle(Color.dsAccent)
                    .frame(width: side, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Text(model.progressSubtitle.isEmpty ? model.author : model.progressSubtitle)
                    .font(isLargeCard ? DSTypography.numericCaption : DSTypography.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: side, alignment: .leading)
            }
        }
        .frame(width: side, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilitySummary)
    }
}
