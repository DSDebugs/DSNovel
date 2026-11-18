import SwiftUI

struct MiniPlayerProgressRing: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    let clock: PlaybackClock
    let coverURL: String
    let bookTitle: String
    let isPlaying: Bool
    let isBuffering: Bool
    let isFailed: Bool
    let hasActiveBook: Bool
    let size: CGFloat

    @State private var baseAngleDegrees: Double = 0
    @State private var spinStartDate: Date?

    init(
        clock: PlaybackClock,
        coverURL: String,
        bookTitle: String,
        isPlaying: Bool,
        isBuffering: Bool,
        isFailed: Bool,
        hasActiveBook: Bool,
        size: CGFloat = 46
    ) {
        self.clock = clock
        self.coverURL = coverURL
        self.bookTitle = bookTitle
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.isFailed = isFailed
        self.hasActiveBook = hasActiveBook
        self.size = size
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

                DSProgress(
                    value: clock.progressFraction,
                    style: .ring(size: ringDiameter, lineWidth: 2.5)
                )
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
            if isPlaying && !reduceMotion {
                spinStartDate = .now
            }
        }
        .onChange(of: isPlaying) { _, nowPlaying in
            if nowPlaying && !reduceMotion {
                spinStartDate = .now
            } else if let start = spinStartDate {
                let elapsed = Date().timeIntervalSince(start)
                baseAngleDegrees = (baseAngleDegrees + elapsed * 30.0).truncatingRemainder(dividingBy: 360.0)
                spinStartDate = nil
            }
        }
    }

    @ViewBuilder
    private func spinningCover(coverSide: CGFloat) -> some View {
        if isPlaying && !reduceMotion, let start = spinStartDate {
            TimelineView(.periodic(from: start, by: 1.0 / 30.0)) { context in
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
