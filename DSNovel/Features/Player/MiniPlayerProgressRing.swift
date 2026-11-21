import SwiftUI

struct MiniPlayerProgressRing: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let clock: PlaybackClock
    let coverURL: String
    let bookTitle: String
    let isPlaying: Bool
    let isBuffering: Bool
    let isFailed: Bool
    let hasActiveBook: Bool
    let size: CGFloat
    let isObscured: Bool

    @State private var baseAngleDegrees: Double = 0
    @State private var spinStartDate: Date?
    @State private var frozenProgressFraction: Double = 0

    private var shouldLiveTrackClock: Bool {
        hasActiveBook && isPlaying && !isObscured && scenePhase == .active
    }

    private var shouldSpin: Bool {
        shouldLiveTrackClock && !reduceMotion
    }

    init(
        clock: PlaybackClock,
        coverURL: String,
        bookTitle: String,
        isPlaying: Bool,
        isBuffering: Bool,
        isFailed: Bool,
        hasActiveBook: Bool,
        size: CGFloat = 46,
        isObscured: Bool = false
    ) {
        self.clock = clock
        self.coverURL = coverURL
        self.bookTitle = bookTitle
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.isFailed = isFailed
        self.hasActiveBook = hasActiveBook
        self.size = size
        self.isObscured = isObscured
    }

    var body: some View {
        let coverSide = max(32, size - 6)
        let ringDiameter = max(36, size - 2.5)
        ZStack {
            if hasActiveBook {
                spinningCover(coverSide: coverSide)
                if isBuffering {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: coverSide, height: coverSide)
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else if isFailed {
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: coverSide, height: coverSide)
                    Image(systemName: "arrow.clockwise")
                        .font(DSTypography.caption)
                        .foregroundStyle(.white)
                } else if !isPlaying {
                    Circle()
                        .fill(Color.black.opacity(0.28))
                        .frame(width: coverSide, height: coverSide)
                    Image(systemName: "play.fill")
                        .font(DSTypography.caption)
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }

                if shouldLiveTrackClock {
                    MiniPlayerLiveProgressRing(clock: clock, ringDiameter: ringDiameter)
                } else {
                    DSProgress(
                        value: frozenProgressFraction,
                        style: .ring(size: ringDiameter, lineWidth: 2.5)
                    )
                }
            } else {
                Circle()
                    .fill(Color.dsSurfaceGrouped)
                    .frame(width: size - 4, height: size - 4)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.dsSeparator.opacity(0.35), lineWidth: 1)
                    )
                Image(systemName: "play.fill")
                    .font(DSTypography.caption)
                    .foregroundStyle(Color.dsAccent)
                    .offset(x: 1)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            frozenProgressFraction = clock.progressFraction
            syncSpinState()
        }
        .onChange(of: isPlaying) { _, _ in
            frozenProgressFraction = clock.progressFraction
            syncSpinState()
        }
        .onChange(of: isObscured) { _, _ in
            frozenProgressFraction = clock.progressFraction
            syncSpinState()
        }
        .onChange(of: scenePhase) { _, _ in
            frozenProgressFraction = clock.progressFraction
            syncSpinState()
        }
        .onChange(of: reduceMotion) { _, _ in
            syncSpinState()
        }
    }

    private func commitAccumulatedAngle(at now: Date = .now) {
        guard let start = spinStartDate else { return }
        let elapsed = max(0, now.timeIntervalSince(start))
        baseAngleDegrees = (baseAngleDegrees + elapsed * 30.0).truncatingRemainder(dividingBy: 360.0)
        spinStartDate = nil
    }

    private func syncSpinState() {
        if shouldSpin {
            if spinStartDate == nil {
                spinStartDate = .now
            }
        } else {
            commitAccumulatedAngle()
        }
    }

    @ViewBuilder
    private func spinningCover(coverSide: CGFloat) -> some View {
        if shouldSpin, let start = spinStartDate {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(start))
                let angle = baseAngleDegrees + elapsed * 30.0
                DSCover(
                    url: coverURL,
                    title: bookTitle,
                    side: coverSide
                )
                .clipShape(Circle())
                .rotationEffect(.degrees(angle))
            }
        } else {
            DSCover(
                url: coverURL,
                title: bookTitle,
                side: coverSide
            )
            .clipShape(Circle())
            .rotationEffect(.degrees(baseAngleDegrees))
        }
    }
}

/// 隔离 1Hz 播放时钟订阅：仅在可见且播放态挂载，遮挡或暂停时彻底卸载以停止 1Hz 重绘
private struct MiniPlayerLiveProgressRing: View {
    let clock: PlaybackClock
    let ringDiameter: CGFloat

    var body: some View {
        DSProgress(
            value: clock.progressFraction,
            style: .ring(size: ringDiameter, lineWidth: 2.5)
        )
    }
}
