import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 播放器 7 个弹窗统一路由枚举
enum PlayerSheetRoute: String, Identifiable {
    case chapters
    case sleep
    case speed
    case skip
    case effects
    case quality
    case download

    var id: String { rawValue }
}

/// 纯竖屏全屏播放器（.preferredColorScheme(.dark)、干净无角标封面、真实码率徽标、7 弹窗协调、零横屏分栏）
struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(AppSettingsStore.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var activeSheet: PlayerSheetRoute?
    @State private var supportsQualitySelection = false
    @State private var isInShelf = false

    private var hasNoBook: Bool {
        playback.currentBook == nil
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, DSColors.accent.opacity(0.28), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: DSSpacing.md) {
                topHeader
                Spacer(minLength: DSSpacing.xs)
                coverSection
                Spacer(minLength: DSSpacing.xs)
                titleAndMetaSection
                PlayerScrubberSection()
                    .disabled(hasNoBook)
                    .opacity(hasNoBook ? 0.45 : 1)
                primaryTransportRow
                    .disabled(hasNoBook)
                    .opacity(hasNoBook ? 0.45 : 1)
                secondaryActionRow
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.md)
        }
        .overlay(alignment: .top) {
            if activeSheet == nil, let msg = banner.current {
                DSBannerPill(message: msg)
                    .padding(.top, DSSpacing.xs)
            }
        }
        .overlay {
            if settings.nightDimEnabled {
                DSColors.nightDimOverlay
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await refreshShelfStatus() }
        }
        .task(id: "\(playback.currentBook?.sourceID ?? "")|\(playback.currentChapter?.url ?? "")") {
            let sid = playback.currentBook?.sourceID ?? ""
            let curl = playback.currentChapter?.url ?? ""
            supportsQualitySelection = await container.isMultiQualitySupported(sourceID: sid, chapterURL: curl)
        }
        .sheet(item: $activeSheet) { route in
            switch route {
            case .chapters:
                ChapterListSheet { activeSheet = nil }
            case .sleep:
                SleepTimerSheet { activeSheet = nil }
            case .speed:
                SpeedSheet { activeSheet = nil }
            case .skip:
                SkipSheet { activeSheet = nil }
            case .effects:
                AudioEffectsSheet { activeSheet = nil }
            case .quality:
                AudioQualitySheet { activeSheet = nil }
            case .download:
                PlayerDownloadSheet { activeSheet = nil }
            }
        }
    }

    private var topHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(DSTypography.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("收起播放器")

            Spacer()

            VStack(spacing: 2) {
                Text(playback.currentBook.map { BookTitleFormatter.cleanTitle($0.title) } ?? "未在播放")
                    .font(DSTypography.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                if supportsQualitySelection, playback.currentBook != nil {
                    Button {
                        activeSheet = .quality
                    } label: {
                        Text(playback.activeStream?.displayBitrateBadge ?? playback.preferredQuality.displayName)
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.accent)
                            .padding(.horizontal, DSSpacing.xs)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("切换播放音质")
                }
            }

            Spacer()

            Button {
                activeSheet = .download
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(DSTypography.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .disabled(hasNoBook)
            .opacity(hasNoBook ? 0.45 : 1)
            .accessibilityLabel("下载章节")
        }
    }

    @ViewBuilder
    private var coverSection: some View {
        if hasNoBook {
            VStack(spacing: DSSpacing.md) {
                Image(systemName: "headphones.circle")
                    .font(DSTypography.largeTitle)
                    .foregroundStyle(.white.opacity(0.72))
                Text("还没有正在收听的书籍")
                    .font(DSTypography.headline)
                    .foregroundStyle(.white)
                Button("前往书架选书") {
                    dismiss()
                    router.selectTab(.library)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
            }
            .padding(DSSpacing.lg)
        } else {
            DSCoverImage(
                urlString: playback.currentBook?.coverURL ?? "",
                pipeline: container.coverPipeline,
                cornerRadius: DSRadius.lg
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 280)
            .shadow(color: DSColors.accent.opacity(0.35), radius: 28, y: 12)
            .padding(.vertical, DSSpacing.sm)
        }
    }

    private var titleAndMetaSection: some View {
        VStack(spacing: DSSpacing.xxs) {
            Text(playback.currentChapter?.title ?? "请先选择章节开始收听")
                .font(DSTypography.title)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let narrator = playback.currentBook?.narrator, !narrator.isEmpty {
                Text(narrator)
                    .font(DSTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            if let book = playback.currentBook {
                Button {
                    Task { await toggleCurrentBookShelf(book) }
                } label: {
                    Label(isInShelf ? "已在书架" : "加入书架", systemImage: isInShelf ? "bookmark.fill" : "bookmark")
                        .font(DSTypography.caption)
                        .foregroundStyle(isInShelf ? DSColors.accent : .white.opacity(0.85))
                        .padding(.horizontal, DSSpacing.sm)
                        .frame(minHeight: 36)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if case .failed(_, let message) = playback.state {
                VStack(spacing: DSSpacing.xxs) {
                    Text(message)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.danger)
                        .lineLimit(2)
                    Button("重新解析播放") {
                        playback.retryCurrentChapter()
                    }
                    .font(DSTypography.caption)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 36)
                }
            }
        }
        .task(id: playback.currentBook?.id) {
            await refreshShelfStatus()
        }
    }

    private func refreshShelfStatus() async {
        guard let bookID = playback.currentBook?.id else {
            isInShelf = false
            return
        }
        if let shelf = try? await container.persistence.fetchShelfBooks() {
            isInShelf = shelf.contains(where: { $0.id == bookID })
        }
    }

    private func toggleCurrentBookShelf(_ book: BookSummaryDTO) async {
        let next = !isInShelf
        do {
            try await container.persistence.upsertBook(book, addToShelf: next)
            isInShelf = next
            container.notifyLibraryChanged()
            banner.show(next ? "已加入书架" : "已移出书架", tone: .success)
        } catch {
            banner.show("更新书架失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private var primaryTransportRow: some View {
        HStack(spacing: DSSpacing.lg) {
            Button {
                playback.skipBy(-15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(DSTypography.title)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("快退 15 秒")

            Button {
                playback.previousChapter()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(DSTypography.title)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("上一章")

            Button {
                playback.togglePlayPause()
            } label: {
                Group {
                    if playback.state.isBuffering {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(DSTypography.title)
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 68, height: 68)
                .background(Color.white, in: Circle())
            }
            .accessibilityLabel(playback.state.isPlaying ? "暂停" : "播放")

            Button {
                playback.nextChapter()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(DSTypography.title)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("下一章")

            Button {
                playback.skipBy(30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(DSTypography.title)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("快进 30 秒")
        }
    }

    private var secondaryActionRow: some View {
        HStack {
            secondaryButton(icon: "list.bullet", label: "目录", route: .chapters, disabled: hasNoBook)
            secondaryButton(icon: "moon.zzz", label: playback.sleepTimer.displayBadge ?? "定时", route: .sleep)
            secondaryButton(icon: "speedometer", label: PlayerSpeedFormatter.format(playback.playbackRate), route: .speed)
            secondaryButton(icon: "forward.frame", label: playback.bookSkipConfig.isEnabled ? "已跳过" : "跳过", route: .skip, disabled: hasNoBook)
            secondaryButton(icon: "slider.horizontal.3", label: "音效", route: .effects)
        }
        .padding(.top, DSSpacing.xs)
    }

    private func secondaryButton(icon: String, label: String, route: PlayerSheetRoute, disabled: Bool = false) -> some View {
        Button {
            activeSheet = route
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(DSTypography.headline)
                Text(label)
                    .font(DSTypography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(disabled ? 0.35 : 0.86))
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 独立订阅 PlaybackClock 的播放器进度条微视图（UX2-01：避免全屏封面与按钮区 2Hz 重绘）
private struct PlayerScrubberSection: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(PlaybackClock.self) private var clock

    var body: some View {
        DSScrubber(
            currentSeconds: clock.currentSeconds,
            durationSeconds: clock.durationSeconds
        ) { target in
            playback.seek(to: target)
        }
    }
}
