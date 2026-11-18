import SwiftUI
import UIKit

/// 播放器沉浸封面组件（§2.2 & §4.2）：
/// - 使用 GeometryReader 自适应计算 `min(w * 0.72, 280)` 适配小屏与大屏机型
/// - 支持播放/暂停弹性缩放、双击封面快速播放/暂停，以及切章时的「上一章 / 下一章」短暂浮层反馈
struct PlayerCoverSection: View {
    @Environment(\.dsReduceMotion) private var reduceMotion

    let coverURL: String
    let bookTitle: String
    let bookID: String?
    let playbackState: PlaybackState
    let chapterSwitchHint: String?
    private let onDoubleTapPlayPause: () -> Void
    private let onImageLoaded: (UIImage) -> Void

    init(
        coverURL: String,
        bookTitle: String,
        bookID: String?,
        playbackState: PlaybackState,
        chapterSwitchHint: String? = nil,
        onDoubleTapPlayPause: @escaping () -> Void,
        onImageLoaded: @escaping (UIImage) -> Void
    ) {
        self.coverURL = coverURL
        self.bookTitle = bookTitle
        self.bookID = bookID
        self.playbackState = playbackState
        self.chapterSwitchHint = chapterSwitchHint
        self.onDoubleTapPlayPause = onDoubleTapPlayPause
        self.onImageLoaded = onImageLoaded
    }

    var body: some View {
        let scale = PlayerAmbientFallbackPolicy.coverScale(
            for: playbackState,
            isPressed: false,
            reduceMotion: reduceMotion
        )
        GeometryReader { geo in
            let adaptiveSide = min(max(geo.size.width * 0.72, 180), 280)
            ZStack {
                DSCover(
                    url: coverURL,
                    title: bookTitle.isEmpty ? "有声书" : bookTitle,
                    side: adaptiveSide,
                    onImageLoaded: onImageLoaded
                )
                .shadow(color: Color.black.opacity(0.42), radius: 24, x: 0, y: 12)
                .scaleEffect(scale)
                .dsAnimation(Motion.smooth, value: scale)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onDoubleTapPlayPause()
                    }
                )
                .accessibilityLabel("专辑封面，双击播放或暂停")

                if let hint = chapterSwitchHint, !hint.isEmpty {
                    HStack(spacing: Spacing.s2) {
                        Image(systemName: hint.contains("上一章") ? "backward.end.fill" : "forward.end.fill")
                            .font(DSTypography.caption.weight(.bold))
                        Text(hint)
                            .font(DSTypography.cardTitle)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.s4)
                    .padding(.vertical, Spacing.s2)
                    .background(
                        Capsule().fill(Color.black.opacity(0.65))
                    )
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: 288)
    }
}
