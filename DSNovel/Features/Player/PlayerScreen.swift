import SwiftUI
import SwiftData
import UIKit

enum PlayerActiveSheet: String, Identifiable {
    case speed
    case sleep
    case chapters
    case soundEffect
    case quality
    case more

    var id: String { rawValue }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dsReduceMotion) private var reduceMotion

    @State private var player = PlayerEngine.shared
    @State private var subtitleEngine = AudioSubtitleEngine.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var settings = AppSettingsStore.shared
    @State private var pageMode: PlayerCenterPageMode = .subtitle
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

            VStack(spacing: Spacing.s3) {
                PlayerHeader(
                    pageMode: $pageMode,
                    sleepOption: player.sleepOption,
                    sleepRemainingSec: player.sleepRemainingSec,
                    onDismiss: { dismiss() },
                    onOpenSleepSheet: { activeSheet = .sleep },
                    onShare: { shareCurrentEpisode() },
                    onOpenMoreSheet: { activeSheet = .more }
                )

                centerStage

                if case .failed = player.state {
                    errorInlineCard
                        .padding(.horizontal, Spacing.pageHorizontal)
                }

                PlayerSecondaryRow(
                    speed: player.speed,
                    isSubtitleActive: pageMode == .subtitle,
                    soundEffectTitle: settings.soundEffectPreset.title,
                    onDownloadCurrent: { downloadCurrentEpisode() },
                    onOpenSpeed: { activeSheet = .speed },
                    onOpenSoundEffect: { activeSheet = .soundEffect },
                    onToggleSubtitle: {
                        DSHapticPolicy.fire(.selection)
                        withAnimation(Motion.snappy) {
                            pageMode = (pageMode == .subtitle) ? .cover : .subtitle
                        }
                    },
                    onOpenMore: { activeSheet = .more }
                )

                DSScrubber(
                    currentTimeSec: player.clock.currentTimeSec,
                    durationSec: player.clock.durationSec,
                    bufferedFraction: player.bufferedRange,
                    qualityLabel: settings.audioQualityTier.shortBadge,
                    onSeek: { sec in player.seek(to: sec) },
                    onSkipBackward: { player.skipBackward(15) },
                    onSkipForward: { player.skipForward(15) },
                    onTapQuality: { activeSheet = .quality }
                )
                .padding(.horizontal, Spacing.pageHorizontal)

                PlayerControls(
                    isPlaying: player.state == .playing,
                    isBuffering: player.isBuffering,
                    canPlayNext: player.nextChapterAvailability != .none,
                    sleepOption: player.sleepOption,
                    sleepRemainingSec: player.sleepRemainingSec,
                    onOpenSleep: { activeSheet = .sleep },
                    onPreviousChapter: {
                        DSHapticPolicy.fire(.chapterSwitch)
                        player.playPreviousChapter()
                    },
                    onTogglePlay: {
                        DSHapticPolicy.fire(.playPause)
                        player.togglePlayPause()
                    },
                    onNextChapter: {
                        DSHapticPolicy.fire(.chapterSwitch)
                        player.playNextChapter()
                    },
                    onOpenChapters: { activeSheet = .chapters }
                )

                PlayerBottomAlbumBar(
                    book: player.currentBook,
                    sourceName: sourceStore.sourceName(for: player.currentBook?.sourceID ?? ""),
                    inShelf: currentBookInShelf,
                    heartBounceCount: heartBounceCount,
                    onOpenBookDetail: { openCurrentBookDetail() },
                    onToggleShelf: { toggleShelf() }
                )
                .padding(.horizontal, Spacing.pageHorizontal)
                .padding(.bottom, Spacing.s2)
            }
            .offset(y: max(0, dragOffset))
            .animation(Motion.resolve(Motion.follow, reduce: reduceMotion), value: dragOffset)
        }
        .environment(\.colorScheme, .dark)
        .sheet(item: $activeSheet) { sheet in
            sheetView(for: sheet)
        }
        .task(id: player.currentChapter?.id) {
            if let book = player.currentBook, let ch = player.currentChapter, subtitleEngine.currentChapterID != ch.id {
                subtitleEngine.loadOrTranscribe(
                    book: book,
                    chapter: ch,
                    asset: nil,
                    playURL: nil,
                    headers: [:],
                    durationHintSec: max(player.clock.durationSec, ch.hintDurationSec)
                )
            }
        }
    }

    @ViewBuilder
    private func sheetView(for sheet: PlayerActiveSheet) -> some View {
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
        case .soundEffect:
            SoundEffectSheet(initialTab: .effect, onClose: { activeSheet = nil })
        case .quality:
            SoundEffectSheet(initialTab: .quality, onClose: { activeSheet = nil })
        case .more:
            MoreSheet(
                player: player,
                inShelf: currentBookInShelf,
                onToggleShelf: { toggleShelf() },
                onOpenSoundEffect: { activeSheet = .soundEffect },
                onOpenSleep: { activeSheet = .sleep },
                onSwitchSource: { openCurrentBookDetail() },
                onSearchNarrator: { narrator in
                    dismiss()
                    AppRouter.shared.searchByNarrator(narrator)
                },
                onClose: { activeSheet = nil }
            )
        }
    }

    @ViewBuilder
    private var centerStage: some View {
        switch pageMode {
        case .cover:
            VStack(spacing: Spacing.s3) {
                Spacer(minLength: 0)
                coverSection
                infoRow
                Spacer(minLength: 0)
            }
        case .subtitle:
            PlayerSubtitleDeck(
                book: player.currentBook,
                chapter: player.currentChapter,
                inShelf: currentBookInShelf,
                cues: subtitleEngine.cues,
                activeCueIndex: subtitleEngine.activeCueIndex(at: player.clock.currentTimeSec),
                engineState: subtitleEngine.state,
                onToggleShelf: { toggleShelf() },
                onOpenBookDetail: { openCurrentBookDetail() },
                onSeekToCue: { cue in player.seek(to: cue.startTimeSec) }
            )
            .frame(maxHeight: .infinity)
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
            side: 256,
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
                        DSHapticPolicy.fire(.selection)
                        withAnimation(Motion.snappy) {
                            pageMode = (pageMode == .cover) ? .subtitle : .cover
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

                if let narrator = player.currentBook?.author, !narrator.isEmpty {
                    Button {
                        dismiss()
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
            onSecondary: { openCurrentBookDetail() }
        )
    }

    private func openCurrentBookDetail() {
        dismiss()
        if let book = player.currentBook {
            AppRouter.shared.open(.book(book))
        }
    }

    private func downloadCurrentEpisode() {
        guard let book = player.currentBook, let ch = player.currentChapter else { return }
        DSHapticPolicy.fire(.success)
        DownloadManager.shared.enqueueChapters([ch], for: book, kind: "manual")
        BannerCenter.shared.show("已加入下载：\(ch.title)", kind: .success)
    }

    private func shareCurrentEpisode() {
        guard let book = player.currentBook, let ch = player.currentChapter else { return }
        UIPasteboard.general.string = "\(book.title) - \(ch.title) \(book.bookURL)"
        DSHapticPolicy.fire(.selection)
        BannerCenter.shared.show("已复制章节分享链接", kind: .info)
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
            BannerCenter.shared.show("已订阅到书架", kind: .success)
            libraryStore.refreshNow()
        }
    }
}
