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
        HStack(spacing: Spacing.s3) {
            DSCover(
                url: coverURL,
                title: bookTitle,
                side: density == .expanded ? 36 : 28
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.s1) {
                    if isFailed {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                    }
                    Text(isFailed ? "播放失败 · 点按重试" : chapterTitle)
                        .font(DSTypography.cardTitle)
                        .foregroundStyle(isFailed ? .red : .primary)
                        .lineLimit(1)
                }

                if density == .expanded {
                    Text(bookTitle)
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct MiniPlayer: View {
    let player: PlayerEngine
    let density: MiniPlayerDensity
    private let onExpand: () -> Void

    init(
        player: PlayerEngine = .shared,
        density: MiniPlayerDensity = .expanded,
        onExpand: @escaping () -> Void
    ) {
        self.player = player
        self.density = density
        self.onExpand = onExpand
    }

    private var isFailed: Bool {
        if case .failed = player.state { return true }
        return false
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
                    MiniPlayerStaticContent(
                        bookTitle: book.title,
                        coverURL: book.cover,
                        chapterTitle: chapter.title,
                        isFailed: isFailed,
                        density: density
                    )
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                MiniPlayerProgressRing(
                    clock: player.clock,
                    isPlaying: player.state == .playing,
                    isBuffering: player.isBuffering,
                    onTogglePlay: {
                        DSHapticPolicy.fire(.playPause)
                        player.togglePlayPause()
                    }
                )

                if density == .expanded {
                    Button {
                        DSHapticPolicy.fire(.selection)
                        player.skipForward(30)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(DSTypography.body)
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快进 30 秒")
                }
            }
            .padding(.horizontal, Spacing.s3)
            .padding(.vertical, Spacing.s2)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.dsSeparator.opacity(0.28), lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.pageHorizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在播放：\(chapter.title)，\(book.title)")
            .accessibilityAction(named: "播放或暂停") {
                player.togglePlayPause()
            }
            .accessibilityAction(named: "下一章") {
                player.playNextChapter()
            }
            .accessibilityAction(named: "展开播放器") {
                onExpand()
            }
        }
    }
}
