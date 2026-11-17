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
        EmptyView()
    }
}

struct MiniPlayer: View {
    let player: PlayerEngine
    let continueBook: Book?
    private let onOpenFullPlayer: () -> Void
    private let onFallbackDiscover: () -> Void

    init(
        player: PlayerEngine = .shared,
        continueBook: Book? = nil,
        onOpenFullPlayer: @escaping () -> Void,
        onFallbackDiscover: @escaping () -> Void = {}
    ) {
        self.player = player
        self.continueBook = continueBook
        self.onOpenFullPlayer = onOpenFullPlayer
        self.onFallbackDiscover = onFallbackDiscover
    }

    private var isFailed: Bool {
        if case .failed = player.state { return true }
        return false
    }

    private var displayTitle: String {
        player.currentBook?.title ?? continueBook?.title ?? "有声书"
    }

    private var displayCover: String {
        player.currentBook?.cover ?? continueBook?.cover ?? ""
    }

    private var hasActiveOrRecent: Bool {
        player.currentBook != nil || continueBook != nil
    }

    var body: some View {
        Button {
            handleCenterDiscTap()
        } label: {
            MiniPlayerProgressRing(
                clock: player.clock,
                coverURL: displayCover,
                bookTitle: displayTitle,
                isPlaying: player.state == .playing,
                isBuffering: player.isBuffering,
                isFailed: isFailed,
                hasActiveBook: hasActiveOrRecent,
                size: 52
            )
            .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        }
        .buttonStyle(.dsCard)
        .offset(y: -4)
        .accessibilityIdentifier("miniplayer.root")
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "播放或暂停") {
            player.togglePlayPause()
        }
        .accessibilityAction(named: "上一章") {
            if player.canPlayPreviousChapter { player.playPreviousChapter() }
        }
        .accessibilityAction(named: "下一章") {
            if player.nextChapterAvailability != .none { player.playNextChapter() }
        }
        .accessibilityAction(named: "展开播放器") {
            onOpenFullPlayer()
        }
    }

    private var accessibilityText: String {
        if let book = player.currentBook, let ch = player.currentChapter {
            return "正在播放：\(ch.title)，\(book.title)，点按打开播放器并继续播放"
        }
        return "打开播放器"
    }

    private func handleCenterDiscTap() {
        DSHapticPolicy.fire(.playPause)
        if player.currentBook != nil {
            if isFailed {
                player.retryCurrentChapter()
            } else if player.state != .playing {
                player.togglePlayPause()
            }
            onOpenFullPlayer()
        } else if let recent = continueBook {
            LibraryCardMapper.playBookImmediately(recent, player: player)
            onOpenFullPlayer()
        } else {
            onFallbackDiscover()
        }
    }
}
