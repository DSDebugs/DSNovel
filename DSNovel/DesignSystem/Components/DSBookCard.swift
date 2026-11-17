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
    private let onAction: () -> Void

    init(
        model: BookCardModel,
        side: CGFloat = 104,
        isEditing: Bool = false,
        isSelected: Bool = false,
        onAction: @escaping () -> Void = {}
    ) {
        self.model = model
        self.side = side
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.onAction = onAction
    }

    var body: some View {
        Button(action: onAction) {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                ZStack(alignment: .topLeading) {
                    DSCover(
                        url: model.coverURL,
                        title: model.title,
                        side: side,
                        badges: model.badges
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
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: side, alignment: .leading)

                Text(model.progressSubtitle.isEmpty ? model.author : model.progressSubtitle)
                    .font(DSTypography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: side, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilitySummary)
    }
}

#Preview("Light") {
    DSBookCard(model: BookCardModel(id: "1", title: "诡秘之主", author: "爱潜水的乌贼", progressFraction: 0.35, lastChapterIndex: 102, totalChapters: 2059, progressSubtitle: "第 102/2059 章", isDownloaded: true))
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSBookCard(model: BookCardModel(id: "2", title: "人间失格", author: "太宰治", hasUpdate: true, isPinned: true), isEditing: true, isSelected: true)
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSBookCard(model: BookCardModel(id: "3", title: "全唐诗", author: "李白"))
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
