import SwiftUI

struct DSContinueCard: View {
    let model: BookCardModel
    private let onOpenDetail: () -> Void
    private let onTogglePlay: () -> Void

    init(
        model: BookCardModel,
        onOpenDetail: @escaping () -> Void = {},
        onTogglePlay: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onOpenDetail = onOpenDetail
        self.onTogglePlay = onTogglePlay
    }

    var body: some View {
        HStack(spacing: Spacing.s4) {
            Button(action: onOpenDetail) {
                HStack(spacing: Spacing.s4) {
                    DSCover(
                        url: model.coverURL,
                        title: model.title,
                        side: 80,
                        badges: model.badges
                    )

                    VStack(alignment: .leading, spacing: Spacing.s1) {
                        HStack(spacing: Spacing.s2) {
                            Text("继续收听")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                            if model.isPlaying {
                                DSEqualizer(isPlaying: true)
                            }
                        }

                        Text(model.title)
                            .font(DSTypography.bookTitleMedium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(model.progressSubtitle.isEmpty ? model.author : model.progressSubtitle)
                            .font(DSTypography.numericFootnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            Button(action: onTogglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .foregroundStyle(Color.dsOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.dsAccent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "暂停播放" : "继续收听")
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Radius.heroCard, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.heroCard, style: .continuous)
                .strokeBorder(Color.dsSeparator.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview("Light") {
    DSContinueCard(model: BookCardModel(id: "1", title: "诡秘之主", author: "8082Audio", progressFraction: 0.4, lastChapterIndex: 102, totalChapters: 2059, progressSubtitle: "第 102/2059 章 · 02:45", isPlaying: true))
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSContinueCard(model: BookCardModel(id: "2", title: "道德经", author: "国学经典", progressSubtitle: "第 3/6 章 · 05:12"))
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSContinueCard(model: BookCardModel(id: "3", title: "全唐诗-李白", author: "白云出岫", progressSubtitle: "第 18/1002 章"))
        .padding()
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
