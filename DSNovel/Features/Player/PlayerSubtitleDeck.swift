import SwiftUI

struct PlayerSubtitleDeck: View {
    let book: BookRef?
    let chapter: ChapterDTO?
    let inShelf: Bool
    let cues: [SubtitleCue]
    let activeCueIndex: Int?
    let engineState: SubtitleEngineState
    private let onToggleShelf: () -> Void
    private let onOpenBookDetail: () -> Void
    private let onSeekToCue: (SubtitleCue) -> Void

    init(
        book: BookRef?,
        chapter: ChapterDTO?,
        inShelf: Bool,
        cues: [SubtitleCue],
        activeCueIndex: Int?,
        engineState: SubtitleEngineState,
        onToggleShelf: @escaping () -> Void,
        onOpenBookDetail: @escaping () -> Void,
        onSeekToCue: @escaping (SubtitleCue) -> Void
    ) {
        self.book = book
        self.chapter = chapter
        self.inShelf = inShelf
        self.cues = cues
        self.activeCueIndex = activeCueIndex
        self.engineState = engineState
        self.onToggleShelf = onToggleShelf
        self.onOpenBookDetail = onOpenBookDetail
        self.onSeekToCue = onSeekToCue
    }

    private var statusBadgeText: String {
        switch engineState {
        case .idle, .preparing:
            return "正在准备字幕…"
        case .transcribing(let prog):
            return "iOS 实时语音转写 \(Int(prog * 100))%"
        case .ready(let source):
            return source
        case .unavailable(let reason):
            return reason
        }
    }

    var body: some View {
        VStack(spacing: Spacing.s3) {
            albumInfoCard
                .padding(.horizontal, Spacing.pageHorizontal)

            subtitleScrollArea
        }
    }

    private var albumInfoCard: some View {
        HStack(spacing: Spacing.s3) {
            Button(action: onOpenBookDetail) {
                HStack(spacing: Spacing.s3) {
                    DSCover(
                        url: book?.cover ?? "",
                        title: book?.title ?? "有声书",
                        side: 48
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(chapter?.title ?? "未选择章节")
                            .font(DSTypography.cardTitle.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(book?.title ?? "")
                            .font(DSTypography.caption)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: Spacing.s2)

            Button(action: onToggleShelf) {
                Text(inShelf ? "已收藏" : "收藏专辑")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(inShelf ? Color.dsAccent.opacity(0.85) : Color.white.opacity(0.16))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
    }

    private var subtitleScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(DSTypography.caption2)
                        Text(statusBadgeText)
                            .font(DSTypography.caption2)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                    ForEach(Array(cues.enumerated()), id: \.element.id) { idx, cue in
                        let isActive = (idx == activeCueIndex)
                        Button {
                            DSHapticPolicy.fire(.selection)
                            onSeekToCue(cue)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cue.text)
                                    .font(isActive ? DSTypography.bookTitleLarge : DSTypography.rowTitle)
                                    .foregroundStyle(isActive ? .white : .white.opacity(0.45))
                                    .multilineTextAlignment(.leading)
                                    .lineSpacing(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if isActive {
                                    Text(PlaybackClock.formatSeconds(cue.startTimeSec))
                                        .font(DSTypography.caption2.monospacedDigit())
                                        .foregroundStyle(Color.dsAccent)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(cue.id)
                    }
                }
                .padding(.horizontal, Spacing.pageHorizontal)
                .padding(.vertical, Spacing.s4)
            }
            .frame(maxHeight: 280)
            .onChange(of: activeCueIndex) { _, newIdx in
                if let newIdx, cues.indices.contains(newIdx) {
                    withAnimation(Motion.smooth) {
                        proxy.scrollTo(cues[newIdx].id, anchor: .center)
                    }
                }
            }
        }
    }
}
