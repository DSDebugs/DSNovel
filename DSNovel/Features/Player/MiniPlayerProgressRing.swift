import SwiftUI

struct MiniPlayerProgressRing: View {
    let clock: PlaybackClock
    let coverURL: String
    let bookTitle: String
    let size: CGFloat

    init(
        clock: PlaybackClock,
        coverURL: String,
        bookTitle: String,
        size: CGFloat
    ) {
        self.clock = clock
        self.coverURL = coverURL
        self.bookTitle = bookTitle
        self.size = size
    }

    var body: some View {
        ZStack {
            DSCover(
                url: coverURL,
                title: bookTitle,
                side: size - 6
            )
            .clipShape(Circle())

            DSProgress(
                value: clock.progressFraction,
                style: .ring(size: size, lineWidth: 2.5)
            )
        }
        .frame(width: size, height: size)
    }
}
