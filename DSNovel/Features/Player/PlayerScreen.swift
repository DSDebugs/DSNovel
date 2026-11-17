import SwiftUI
import SwiftData

enum PlayerActiveSheet: String, Identifiable {
    case speed
    case sleep
    case chapters
    case more

    var id: String { rawValue }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dsReduceMotion) private var reduceMotion

    @State private var player = PlayerEngine.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var activeSheet: PlayerActiveSheet?
    @State private var ambientColor: Color = .dsAccent
    @State private var heartBounceCount: Int = 0
    @GestureState private var dragOffset: CGFloat = 0

    init() {}

    private var currentBookInShelf: Bool {
        guard let bid = player.currentBookID else { return false }
        return libraryStore.allShelfBooks.contains(where: { $0.id == bid })
    }

    var body: some View {
        ZStack {
            PlayerAmbientBackground(
                primaryColor: ambientColor,
                isPlaying: player.state == .playing
            )

            VStack(spacing: Spacing.s4) {
                PlayerHeader(
                    sleepOption: player.sleepOption,
                    sleepRemainingSec: player.sleepRemainingSec,
                    onDismiss: { dismiss() },
                    onOpenSleepSheet: { activeSheet = .sleep },
                    onOpenMoreSheet: { activeSheet = .more }
                )

                Spacer(minLength: 0)

                coverSection

                if case .failed = player.state {
                    errorInlineCard
                        .padding(.horizontal, Spacing.pageHorizontal)
                }

                infoRow

                DSScrubber(
                    currentTimeSec: player.clock.currentTimeSec,
                    durationSec: player.clock.durationSec,
                    bufferedFraction: player.bufferedRange,
                    onSeek: { sec in player.seek(to: sec) }
                )
                .padding(.horizontal, Spacing.pageHorizontal)

                PlayerControls(
                    isPlaying: player.state == .playing,
                    isBuffering: player.isBuffering,
                    canPlayNext: player.nextChapterAvailability != .none,
                    onPreviousChapter: {
                        DSHapticPolicy.fire(.chapterSwitch)
                        player.playPreviousChapter()
                    },
                    onSkipBackward: { player.skipBackward(15) },
                    onTogglePlay: {
                        DSHapticPolicy.fire(.playPause)
                        player.togglePlayPause()
                    },
                    onSkipForward: { player.skipForward(30) },
                    onNextChapter: {
                        DSHapticPolicy.fire(.chapterSwitch)
                        player.playNextChapter()
                    }
                )

                PlayerSecondaryRow(
                    speed: player.speed,
                    sleepOption: player.sleepOption,
                    onOpenSpeed: { activeSheet = .speed },
                    onOpenSleep: { activeSheet = .sleep },
                    onOpenChapters: { activeSheet = .chapters },
                    onOpenMore: { activeSheet = .more }
                )

                Spacer(minLength: Spacing.s2)
            }
            .offset(y: max(0, dragOffset))
            .animation(Motion.resolve(Motion.follow, reduce: reduceMotion), value: dragOffset)
        }
        .environment(\.colorScheme, .dark)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .speed:
                SpeedSheet(player: player, onClose: { activeSheet = nil })
            case .sleep:
                SleepSheet(player: player, onClose: { activeSheet = nil })
            case .chapters:
                ChapterListView(
                    chapters: player.chapterQueue,
                    currentChapterID: player.currentChapter?.id,
                    isPlaying: player.state == .playing,
                    onSelectChapter: { ch in
                        if let book = player.currentBook {
                            player.startPlayback(book: book, chapters: player.chapterQueue, startChapter: ch)
                        }
                    },
                    onClose: { activeSheet = nil }
                )
            case .more:
                MoreSheet(
                    player: player,
                    onSwitchSource: {
                        dismiss()
                        if let book = player.currentBook {
                            AppRouter.shared.open(.book(book))
                        }
                    },
                    onClose: { activeSheet = nil }
                )
            }
        }
    }

    private var coverSection: some View {
        let scale = PlayerAmbientFallbackPolicy.coverScale(
            for: player.state,
            isPressed: false,
            reduceMotion: reduceMotion
        )
        return DSCover(
            url: player.currentBook?.cover ?? "",
            title: player.currentBook?.title ?? "有声书",
            side: 280,
            onImageLoaded: { img in
                ambientColor = CoverAmbientColor.color(from: img, cacheKey: player.currentBookID)
            }
        )
        .scaleEffect(scale)
        .dsAnimation(Motion.smooth, value: scale)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                DSHapticPolicy.fire(.playPause)
                player.togglePlayPause()
            }
        )
        .gesture(
            DragGesture(minimumDistance: 20)
                .updating($dragOffset) { value, state, _ in
                    if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) {
                        state = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                        dismiss()
                    } else if abs(value.translation.width) > 70 && abs(value.translation.width) > abs(value.translation.height) {
                        DSHapticPolicy.fire(.chapterSwitch)
                        if value.translation.width < 0 {
                            player.playNextChapter()
                        } else {
                            player.playPreviousChapter()
                        }
                    }
                }
        )
    }

    private var infoRow: some View {
        HStack(spacing: Spacing.s3) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    activeSheet = .chapters
                } label: {
                    Text(player.currentChapter?.title ?? "未选择章节")
                        .font(DSTypography.bookTitleMedium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Text(player.currentBook?.title ?? "")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)

                if let narrator = player.currentBook?.author, !narrator.isEmpty {
                    Button {
                        AppRouter.shared.searchByNarrator(narrator)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(DSTypography.caption2)
                            Text(narrator)
                                .lineLimit(1)
                        }
                        .font(DSTypography.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Button {
                toggleShelf()
            } label: {
                Image(systemName: currentBookInShelf ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(currentBookInShelf ? Color.dsAccent : .white.opacity(0.85))
                    .symbolEffect(.bounce, value: heartBounceCount)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(currentBookInShelf ? "已在书架" : "加入书架")
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ViewBuilder
    private var errorInlineCard: some View {
        let sourceID = player.currentBook?.sourceID ?? ""
        let sourceName = sourceStore.sourceName(for: sourceID)
        let kind: DSStateKind = {
            if let pErr = player.lastPluginError {
                return UserFacingError.from(pErr, sourceName: sourceName)
            }
            return .error(detail: nil)
        }()
        DSStateView(
            kind: kind,
            variant: .inline,
            onPrimary: {
                switch kind {
                case .needLogin, .needVerify:
                    AuthCoordinator.shared.presentLogin(forSourceID: sourceID)
                case .vipChapter:
                    dismiss()
                    AppRouter.shared.openBuiltinParser(sourceID: sourceID)
                case .offline:
                    if case .availableDownloaded(let nextCh) = player.nextChapterAvailability,
                       let book = player.currentBook {
                        player.startPlayback(book: book, chapters: player.chapterQueue, startChapter: nextCh)
                    } else {
                        player.retryCurrentChapter()
                    }
                default:
                    player.retryCurrentChapter()
                }
            },
            onSecondary: {
                dismiss()
                if let book = player.currentBook {
                    AppRouter.shared.open(.book(book))
                }
            }
        )
    }

    private func toggleShelf() {
        guard let bookRef = player.currentBook else { return }
        if let existing = libraryStore.allShelfBooks.first(where: { $0.id == bookRef.id }) {
            libraryStore.removeFromShelfDeferred([existing])
        } else {
            let targetBookID = bookRef.id
            let desc = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == targetBookID })
            if let historyRecord = try? modelContext.fetch(desc).first {
                historyRecord.inShelf = true
            } else {
                let newBook = Book(
                    id: bookRef.id,
                    sourceID: bookRef.sourceID,
                    bookURL: bookRef.bookURL,
                    title: bookRef.title,
                    author: bookRef.author,
                    cover: bookRef.cover,
                    intro: bookRef.intro,
                    inShelf: true,
                    totalChapters: player.chapterQueue.count
                )
                modelContext.insert(newBook)
            }
            try? modelContext.save()
            heartBounceCount &+= 1
            DSHapticPolicy.fire(.success)
            BannerCenter.shared.show("已加入书架", kind: .success)
            libraryStore.refreshNow()
        }
    }
}
