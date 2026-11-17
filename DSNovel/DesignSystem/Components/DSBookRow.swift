import SwiftUI

struct DSBookRow: View {
    let model: BookCardModel
    let isEditing: Bool
    let isSelected: Bool
    private let onSelect: () -> Void
    private let onPlayTap: (() -> Void)?

    init(
        model: BookCardModel,
        isEditing: Bool = false,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {},
        onPlayTap: (() -> Void)? = nil
    ) {
        self.model = model
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onPlayTap = onPlayTap
    }

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Button(action: onSelect) {
                HStack(spacing: Spacing.s3) {
                    if isEditing {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.dsAccent : .secondary)
                    }

                    DSCover(
                        url: model.coverURL,
                        title: model.title,
                        side: 64,
                        badges: model.badges
                    )

                    VStack(alignment: .leading, spacing: Spacing.s1) {
                        HStack(spacing: Spacing.s1) {
                            if model.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.dsAccent)
                            }
                            Text(model.title)
                                .font(DSTypography.rowTitle)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }

                        let authorLine = [model.author, model.sourceName].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !authorLine.isEmpty {
                            Text(authorLine)
                                .font(DSTypography.subtitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        let showProgressLine = !model.progressSubtitle.isEmpty
                            && model.progressSubtitle != model.author
                            && model.progressSubtitle != authorLine
                        if showProgressLine {
                            Text(model.progressSubtitle)
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(model.isPlaying ? Color.dsAccent : .secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            if let onPlayTap, !isEditing {
                Button(action: onPlayTap) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.dsOnAccent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.dsAccent))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPlaying ? "暂停 \(model.title)" : "继续收听 \(model.title)")
            }
        }
        .padding(.vertical, Spacing.s2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilitySummary)
    }
}

#Preview("Light") {
    DSBookRow(model: BookCardModel(id: "1", title: "诡秘之主", author: "8082Audio", sourceName: "有听网", progressSubtitle: "第 102/2059 章 · 02:45"), onPlayTap: {})
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSBookRow(model: BookCardModel(id: "2", title: "人间失格", author: "博看有声", progressSubtitle: "第 2/9 章 · 00:06", isPlaying: true), isEditing: true, isSelected: true)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSBookRow(model: BookCardModel(id: "3", title: "少年说道：水浒传", author: "博看有声", progressSubtitle: "第 1/21 章 · 00:41"))
        .padding()
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
