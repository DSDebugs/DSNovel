import SwiftUI

enum MiniPlayerDensity: Equatable, Sendable {
    case expanded
    case compact
}

#if DEBUG
/// 仅供既有单元测试 `AppRouterAndShellTests` 保持向后兼容，Release 构建自动剔除
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
#endif

struct MiniPlayer: View {
    let player: PlayerEngine
    let continueBook: Book?
    @State private var router = AppRouter.shared
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
                size: 46,
                isObscured: router.isPlayerPresented
            )
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .buttonStyle(.dsCard)
        .contextMenu {
            if player.currentBook != nil {
                Button {
                    DSHapticPolicy.fire(.playPause)
                    player.togglePlayPause()
                } label: {
                    Label(
                        player.state == .playing ? "暂停播放" : "继续播放",
                        systemImage: player.state == .playing ? "pause.fill" : "play.fill"
                    )
                }
                if player.canPlayPreviousChapter {
                    Button {
                        DSHapticPolicy.fire(.chapterSwitch)
                        player.playPreviousChapter()
                    } label: {
                        Label("上一章", systemImage: "backward.end.fill")
                    }
                }
                if player.nextChapterAvailability != .none {
                    Button {
                        DSHapticPolicy.fire(.chapterSwitch)
                        player.playNextChapter()
                    } label: {
                        Label("下一章", systemImage: "forward.end.fill")
                    }
                }
                Button {
                    onOpenFullPlayer()
                } label: {
                    Label("展开播放器", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            } else if let recent = continueBook {
                Button {
                    DSHapticPolicy.fire(.playPause)
                    LibraryCardMapper.playBookImmediately(recent, player: player)
                } label: {
                    Label("继续播放《\(recent.title)》", systemImage: "play.fill")
                }
                Button {
                    prepareRecentBookPaused(recent)
                    onOpenFullPlayer()
                } label: {
                    Label("展开播放器", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
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
            let status = player.state == .playing ? "正在播放" : "已暂停"
            return "\(status)：\(ch.title)，\(book.title)，点按打开播放器，长按可快速播放或暂停"
        }
        if let recent = continueBook {
            return "上次收听：\(recent.title)，点按打开播放器"
        }
        return "打开播放器"
    }

    /// U4：单击中心圆盘仅静默展开全屏播放器，保持当前播放/暂停状态不变（不在暂停态强行外放）
    private func handleCenterDiscTap() {
        DSHapticPolicy.fire(.selection)
        if player.currentBook != nil {
            onOpenFullPlayer()
        } else if let recent = continueBook {
            prepareRecentBookPaused(recent)
            onOpenFullPlayer()
        } else {
            onFallbackDiscover()
        }
    }

    /// 冷启动无活跃队列时仅恢复最近书籍到暂停态，展开后由用户决定是否起播
    private func prepareRecentBookPaused(_ book: Book) {
        let downloadedSnaps = DownloadManager.shared.bookSnapshots(for: book.id)
        if let chapters = ChapterCacheStore.loadChapters(for: book.id), !chapters.isEmpty {
            let target: ChapterDTO
            if let lastID = book.lastChapterID,
               let matched = chapters.first(where: { $0.id == lastID }) {
                target = matched
            } else if let firstDownloaded = chapters.first(where: {
                downloadedSnaps["\(book.id)::\($0.id)"]?.state == "completed"
            }) {
                target = firstDownloaded
            } else {
                target = chapters[0]
            }
            let posMs = (target.id == book.lastChapterID)
                ? book.lastPositionMs
                : (ChapterProgressCache.shared.progress(bookID: book.id, chapterID: target.id)?.positionMs ?? 0)
            player.prepare(
                book: book.bookRef,
                chapters: chapters,
                chapter: target,
                positionMs: posMs
            )
            return
        }
        for snap in downloadedSnaps.values where snap.state == "completed" {
            let ch = ChapterDTO(index: 0, title: snap.chapterTitle, url: snap.chapterID)
            player.prepare(
                book: book.bookRef,
                chapters: [ch],
                chapter: ch,
                positionMs: 0
            )
            return
        }
    }
}
