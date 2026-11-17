import SwiftUI

enum MiniPlayerDensity: Equatable, Sendable {
    case expanded
    case compact
}

final class MiniPlayerRenderCounter: @unchecked Sendable {
    static let shared = MiniPlayerRenderCounter()
    private(set) var staticBodyEvaluations: Int = 0

    func recordEvaluation() {
        staticBodyEvaluations += 1
    }

    func reset() {
        staticBodyEvaluations = 0
    }
}

struct MiniPlayerStaticContent: View, Equatable {
    let bookTitle: String
    let coverURL: String
    let chapterTitle: String
    let isFailed: Bool
    let density: MiniPlayerDensity

    init(
        bookTitle: String,
        coverURL: String,
        chapterTitle: String,
        isFailed: Bool,
        density: MiniPlayerDensity
    ) {
        self.bookTitle = bookTitle
        self.coverURL = coverURL
        self.chapterTitle = chapterTitle
        self.isFailed = isFailed
        self.density = density
    }

    static func == (lhs: MiniPlayerStaticContent, rhs: MiniPlayerStaticContent) -> Bool {
        lhs.bookTitle == rhs.bookTitle &&
        lhs.coverURL == rhs.coverURL &&
        lhs.chapterTitle == rhs.chapterTitle &&
        lhs.isFailed == rhs.isFailed &&
        lhs.density == rhs.density
    }

    var body: some View {
        let _ = MiniPlayerRenderCounter.shared.recordEvaluation()
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Spacing.s1) {
                if isFailed {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                }
                Text(chapterTitle)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            if density == .expanded {
                Text(isFailed ? "播放失败 · 点按重试" : bookTitle)
                    .font(DSTypography.caption)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct MiniPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let player: PlayerEngine
    private let onExpand: () -> Void

    init(
        player: PlayerEngine = .shared,
        onExpand: @escaping () -> Void
    ) {
        self.player = player
        self.onExpand = onExpand
    }

    private var density: MiniPlayerDensity {
        placement == .inline ? .compact : .expanded
    }

    private var isFailed: Bool {
        if case .failed = player.state { return true }
        return false
    }

    private var canPlayPrev: Bool {
        player.canPlayPreviousChapter
    }

    private var canPlayNext: Bool {
        player.nextChapterAvailability != .none
    }

    var body: some View {
        if let book = player.currentBook, let chapter = player.currentChapter {
            HStack(spacing: Spacing.s2) {
                Button {
                    if isFailed {
                        player.retryCurrentChapter()
                    } else {
                        onExpand()
                    }
                } label: {
                    HStack(spacing: Spacing.s2) {
                        MiniPlayerProgressRing(
                            clock: player.clock,
                            coverURL: book.cover,
                            bookTitle: book.title,
                            size: density == .expanded ? 40 : 28
                        )

                        MiniPlayerStaticContent(
                            bookTitle: book.title,
                            coverURL: book.cover,
                            chapterTitle: chapter.title,
                            isFailed: isFailed,
                            density: density
                        )
                        .equatable()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if density == .expanded && value.translation.height < -30 {
                                onExpand()
                            } else if density == .compact && abs(value.translation.width) > 36 {
                                DSHapticPolicy.fire(.chapterSwitch)
                                if value.translation.width < 0 && canPlayNext {
                                    player.playNextChapter()
                                } else if value.translation.width > 0 && canPlayPrev {
                                    player.playPreviousChapter()
                                }
                            }
                        }
                )

                if density == .expanded {
                    Button {
                        DSHapticPolicy.fire(.chapterSwitch)
                        player.playPreviousChapter()
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(DSTypography.subtitle.weight(.semibold))
                            .foregroundStyle(canPlayPrev ? .primary : .tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPlayPrev)
                    .accessibilityLabel("上一章")
                    .accessibilityIdentifier("miniplayer.prev")
                }

                Button {
                    if isFailed {
                        player.retryCurrentChapter()
                    } else {
                        DSHapticPolicy.fire(.playPause)
                        player.togglePlayPause()
                    }
                } label: {
                    Group {
                        if player.isBuffering {
                            ProgressView()
                                .controlSize(.small)
                        } else if isFailed {
                            Image(systemName: "arrow.clockwise")
                                .font(DSTypography.body.weight(.semibold))
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                                .font(DSTypography.body.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFailed ? "重试" : (player.state == .playing ? "暂停" : "播放"))
                .accessibilityIdentifier("miniplayer.play")

                Button {
                    DSHapticPolicy.fire(.chapterSwitch)
                    player.playNextChapter()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(DSTypography.subtitle.weight(.semibold))
                        .foregroundStyle(canPlayNext ? .primary : .tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canPlayNext)
                .accessibilityLabel("下一章")
                .accessibilityIdentifier("miniplayer.next")
            }
            .padding(.horizontal, Spacing.s3)
            .frame(height: density == .expanded ? 52 : 44)
            .accessibilityIdentifier("miniplayer.root")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("正在播放：\(chapter.title)，\(book.title)")
            .accessibilityAction(named: "播放或暂停") {
                player.togglePlayPause()
            }
            .accessibilityAction(named: "上一章") {
                if canPlayPrev { player.playPreviousChapter() }
            }
            .accessibilityAction(named: "下一章") {
                if canPlayNext { player.playNextChapter() }
            }
            .accessibilityAction(named: "展开播放器") {
                onExpand()
            }
        }
    }
}
