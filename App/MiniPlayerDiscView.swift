import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 方案 E 精修版：立体书封抽碟组件（左 36pt 圆角书封 + 贴边进度条 + 右半露旋转黑胶）
private struct MiniPlayerSleeveVinyl: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let clock: PlaybackClock
    let pipeline: CoverImagePipeline
    let coverURL: String
    let bookTitle: String
    let isPlaying: Bool
    let isBuffering: Bool
    let isFailed: Bool
    let hasActiveBook: Bool
    let isObscured: Bool
    let accentColor: Color

    @State private var baseAngleDegrees: Double = 0
    @State private var spinStartDate: Date?
    @State private var frozenProgressFraction: Double = 0

    private let coverSize: CGFloat = 36
    private let vinylSize: CGFloat = 34

    private var shouldLiveTrackClock: Bool {
        hasActiveBook && isPlaying && !isObscured && scenePhase == .active
    }

    private var shouldSpin: Bool {
        shouldLiveTrackClock && !reduceMotion
    }

    var body: some View {
        let vinylOffsetX: CGFloat = (hasActiveBook && isPlaying) ? 13 : 6

        ZStack(alignment: .leading) {
            Group {
                if shouldSpin, let start = spinStartDate {
                    TimelineView(.periodic(from: start, by: 1.0 / 30.0)) { context in
                        let elapsed = max(0, context.date.timeIntervalSince(start))
                        let angle = baseAngleDegrees + elapsed * 45.0
                        MiniPlayerVinylDisc(
                            diameter: vinylSize,
                            accentColor: accentColor,
                            isPlaying: isPlaying,
                            isActiveBook: hasActiveBook
                        )
                        .rotationEffect(.degrees(angle))
                    }
                } else {
                    MiniPlayerVinylDisc(
                        diameter: vinylSize,
                        accentColor: accentColor,
                        isPlaying: isPlaying,
                        isActiveBook: hasActiveBook
                    )
                    .rotationEffect(.degrees(baseAngleDegrees))
                }
            }
            .offset(x: vinylOffsetX)
            .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: isPlaying)

            ZStack(alignment: .bottom) {
                if hasActiveBook {
                    DSCover(url: coverURL, title: bookTitle, pipeline: pipeline, side: coverSize, showsBorder: false)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DSColors.surfaceGrouped)
                        .frame(width: coverSize, height: coverSize)
                        .overlay(
                            Image(systemName: "headphones")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(accentColor)
                        )
                }

                coverStateOverlay

                if hasActiveBook {
                    let barColor = isPlaying ? accentColor : accentColor.opacity(0.55)
                    if shouldLiveTrackClock {
                        MiniPlayerLiveProgressBar(clock: clock, width: coverSize - 6, accentColor: barColor)
                            .padding(.bottom, 2.5)
                    } else {
                        MiniPlayerProgressBarTrack(progress: frozenProgressFraction, width: coverSize - 6, accentColor: barColor)
                            .padding(.bottom, 2.5)
                    }
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 3.5, x: 2, y: 0)
        }
        .frame(width: coverSize + 15, height: coverSize, alignment: .leading)
        .onAppear { syncProgressAndSpin() }
        .onChange(of: isPlaying) { _, _ in syncProgressAndSpin() }
        .onChange(of: isObscured) { _, _ in syncProgressAndSpin() }
        .onChange(of: scenePhase) { _, _ in syncProgressAndSpin() }
        .onChange(of: reduceMotion) { _, _ in syncSpinState() }
        .onChange(of: coverURL) { _, _ in
            baseAngleDegrees = 0
            spinStartDate = nil
            syncProgressAndSpin()
        }
        .onChange(of: hasActiveBook) { _, _ in
            baseAngleDegrees = 0
            spinStartDate = nil
            syncProgressAndSpin()
        }
    }

    @ViewBuilder
    private var coverStateOverlay: some View {
        if isBuffering {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.42))
                ProgressView().tint(.white).controlSize(.small)
            }
            .frame(width: coverSize, height: coverSize)
        } else if isFailed {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.48))
                Image(systemName: "arrow.clockwise")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: coverSize, height: coverSize)
        }
    }

    private func syncProgressAndSpin() {
        if !shouldLiveTrackClock {
            frozenProgressFraction = hasActiveBook ? clock.progress : 0
        }
        syncSpinState()
    }

    private func syncSpinState() {
        if shouldSpin {
            if spinStartDate == nil { spinStartDate = Date() }
        } else if let start = spinStartDate {
            let elapsed = max(0, Date().timeIntervalSince(start))
            baseAngleDegrees = (baseAngleDegrees + elapsed * 45.0).truncatingRemainder(dividingBy: 360.0)
            spinStartDate = nil
        }
    }
}

/// 底栏右侧小型播放器（方案 E 精修版：立体书封抽碟 + 轻透主题色播放圆钮）
struct MiniPlayerDisc: View {
    @Environment(\.dsAccentTheme) private var accentTheme
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner
    let onOpenPlayer: () -> Void

    private var isBuffering: Bool {
        if case .buffering = playback.state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = playback.state { return true }
        return false
    }

    private var canPlayPrevious: Bool { playback.currentChapterIndex > 0 }
    private var canPlayNext: Bool { playback.currentChapterIndex + 1 < playback.chapters.count }

    private var accessibilityText: String {
        guard let book = playback.currentBook else { return "暂无正在播放的书籍" }
        let chapter = playback.currentChapter?.title ?? ""
        let stateText = playback.state.isPlaying ? "正在播放" : (isBuffering ? "缓冲中" : "已暂停")
        return "\(stateText)：\(book.title) \(chapter)"
    }

    var body: some View {
        let accentColor = DSColors.accent(for: accentTheme)
        let isPlaying = playback.state.isPlaying
        let hasBook = playback.currentBook != nil

        HStack(spacing: 6) {
            Button {
                DSHaptics.selection()
                onOpenPlayer()
            } label: {
                MiniPlayerSleeveVinyl(
                    clock: playback.clock,
                    pipeline: container.coverPipeline,
                    coverURL: playback.currentBook?.coverURL ?? "",
                    bookTitle: playback.currentBook?.title ?? "有声书",
                    isPlaying: isPlaying,
                    isBuffering: isBuffering,
                    isFailed: isFailed,
                    hasActiveBook: hasBook,
                    isObscured: router.isPlayerPresented || banner.isSheetPresenting,
                    accentColor: accentColor
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)
            .accessibilityIdentifier("miniplayer.root")
            .accessibilityLabel(accessibilityText)

            Button {
                DSHaptics.lightImpact()
                if hasBook {
                    playback.togglePlayPause()
                } else {
                    onOpenPlayer()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(isPlaying ? accentColor.opacity(0.16) : DSColors.surfaceGrouped.opacity(0.85))
                    Circle()
                        .strokeBorder(
                            isPlaying ? accentColor.opacity(0.45) : DSColors.separator.opacity(0.32),
                            lineWidth: 0.8
                        )
                    if isBuffering {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accentColor)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(DSTypography.caption.weight(.bold))
                            .foregroundStyle(isPlaying ? accentColor : (hasBook ? DSColors.inkPrimary : DSColors.inkSecondary))
                            .offset(x: isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 34, height: 34)
                .frame(minWidth: 38, minHeight: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("miniplayer.togglePlay")
            .accessibilityLabel(isPlaying ? "暂停播放" : "继续播放")
        }
        .contextMenu {
            if hasBook {
                Button {
                    DSHaptics.lightImpact()
                    playback.togglePlayPause()
                } label: {
                    Label(isPlaying ? "暂停播放" : "继续播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                if canPlayPrevious {
                    Button {
                        DSHaptics.selection()
                        playback.previousChapter()
                    } label: {
                        Label("上一章", systemImage: "backward.end.fill")
                    }
                }
                if canPlayNext {
                    Button {
                        DSHaptics.selection()
                        playback.nextChapter()
                    } label: {
                        Label("下一章", systemImage: "forward.end.fill")
                    }
                }
                Button(action: onOpenPlayer) {
                    Label("展开播放器", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        .accessibilityAction(named: "播放或暂停") { playback.togglePlayPause() }
        .accessibilityAction(named: "上一章") { if canPlayPrevious { playback.previousChapter() } }
        .accessibilityAction(named: "下一章") { if canPlayNext { playback.nextChapter() } }
        .accessibilityAction(named: "展开播放器") { onOpenPlayer() }
    }
}
