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
        HStack(spacing: Spacing.s3) {
            Button(action: onOpenDetail) {
                HStack(spacing: Spacing.s3) {
                    DSCover(
                        url: model.coverURL,
                        title: model.title,
                        side: 64,
                        badges: model.badges
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: Spacing.s2) {
                            Text(model.isPlaying ? "正在播放" : "继续收听")
                                .font(DSTypography.caption2.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.dsAccent.opacity(0.12)))

                            if model.isPlaying {
                                DSEqualizer(isPlaying: true)
                            }
                        }

                        Text(model.title)
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(model.progressSubtitle.isEmpty ? model.author : model.progressSubtitle)
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if model.progressFraction > 0 {
                            DSProgress(value: model.progressFraction, style: .bar(height: 3))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            Button(action: onTogglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dsOnAccent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.dsAccent))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "暂停播放" : "继续收听")
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.dsAccent.opacity(0.18), lineWidth: 1)
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
