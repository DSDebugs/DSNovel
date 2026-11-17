import SwiftUI

struct DSBookRow: View {
    let model: BookCardModel
    let isEditing: Bool
    let isSelected: Bool
    private let onSelect: () -> Void
    private let onPlayTap: (() -> Void)?
    private let onNarratorTap: ((String) -> Void)?

    init(
        model: BookCardModel,
        isEditing: Bool = false,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {},
        onPlayTap: (() -> Void)? = nil,
        onNarratorTap: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onPlayTap = onPlayTap
        self.onNarratorTap = onNarratorTap
    }

    var body: some View {
        let authorLine = [model.author, model.sourceName].filter { !$0.isEmpty }.joined(separator: " · ")
        let showProgressLine = !model.progressSubtitle.isEmpty
            && model.progressSubtitle != model.author
            && model.progressSubtitle != authorLine

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
                }
            }
            .buttonStyle(.dsCard)

            VStack(alignment: .leading, spacing: Spacing.s1) {
                Button(action: onSelect) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !authorLine.isEmpty {
                    HStack(spacing: 4) {
                        if !model.author.isEmpty && !isEditing {
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
                                .font(DSTypography.subtitle)
                                .foregroundStyle(Color.dsAccent)
                            }
                            .buttonStyle(.plain)
                        } else if !model.author.isEmpty {
                            Text(model.author)
                                .font(DSTypography.subtitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !model.sourceName.isEmpty {
                            Text(model.author.isEmpty ? model.sourceName : "· \(model.sourceName)")
                                .font(DSTypography.subtitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if showProgressLine {
                    Button(action: onSelect) {
                        Text(model.progressSubtitle)
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(model.isPlaying ? Color.dsAccent : .secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
