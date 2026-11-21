import SwiftUI
import UIKit

/// 播放器沉浸封面组件：
/// - 播放态：封面立体浮起（1.0x）+ 背部双层声波光环呼吸扩散；
/// - 暂停/遮挡/退后台：封面柔和内收且声波 TimelineView 自动休眠；
/// - 宽高双约束防溢出：可用高度 < 100 时隐藏外层声波光环并裁剪背光边界。
struct PlayerCoverSection: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let coverURL: String
    let bookTitle: String
    let bookID: String?
    let ambientColor: Color
    let playbackState: PlaybackState
    let isObscured: Bool
    private let onDoubleTapPlayPause: () -> Void
    private let onImageLoaded: (UIImage) -> Void

    init(
        coverURL: String,
        bookTitle: String,
        bookID: String?,
        ambientColor: Color = .dsAccent,
        playbackState: PlaybackState,
        isObscured: Bool = false,
        onDoubleTapPlayPause: @escaping () -> Void,
        onImageLoaded: @escaping (UIImage) -> Void
    ) {
        self.coverURL = coverURL
        self.bookTitle = bookTitle
        self.bookID = bookID
        self.ambientColor = ambientColor
        self.playbackState = playbackState
        self.isObscured = isObscured
        self.onDoubleTapPlayPause = onDoubleTapPlayPause
        self.onImageLoaded = onImageLoaded
    }

    private var isPlaying: Bool {
        playbackState == .playing
    }

    var body: some View {
        let scale = PlayerAmbientFallbackPolicy.coverScale(
            for: playbackState,
            isPressed: false,
            reduceMotion: reduceMotion
        )
        let isTimelinePaused = !isPlaying || isObscured || scenePhase != .active
        GeometryReader { geo in
            let maxByHeight = max(88, geo.size.height - 24)
            let adaptiveSide = max(0, min(geo.size.width * 0.68, maxByHeight, 264))
            let cornerRadius = Radius.cover(forSide: adaptiveSide)
            let isUltraCompactHeight = geo.size.height < 100

            ZStack {
                // 1. 封面背部柔和氛围背光（播放时饱满发散，暂停时收敛；超低高度收敛半径防溢出）
                if !isUltraCompactHeight {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.dsAccent.opacity(isPlaying ? 0.46 : 0.10),
                                    ambientColor.opacity(isPlaying ? 0.58 : 0.14),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 12,
                                endRadius: adaptiveSide * 0.72
                            )
                        )
                        .frame(width: adaptiveSide * 1.32, height: adaptiveSide * 1.32)
                        .scaleEffect(isPlaying ? 1.06 : 0.78)
                        .blur(radius: isPlaying ? 18 : 10)
                        .dsAnimation(Motion.smooth, value: isPlaying)
                }

                // 2. 播放态声波律动外环（可用高度 < 100 时隐藏避免溢出）
                if !reduceMotion && !isUltraCompactHeight {
                    TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: isTimelinePaused)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let wave1 = isPlaying ? (1.0 + 0.045 * sin(t * 2.4)) : 0.86
                        let wave2 = isPlaying ? (1.05 + 0.055 * cos(t * 1.8)) : 0.86
                        ZStack {
                            RoundedRectangle(cornerRadius: cornerRadius + 6, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.dsAccent.opacity(isPlaying ? 0.55 : 0.0),
                                            Color.white.opacity(isPlaying ? 0.22 : 0.0),
                                            Color.dsAccent.opacity(isPlaying ? 0.40 : 0.0)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.4
                                )
                                .frame(width: adaptiveSide + 12, height: adaptiveSide + 12)
                                .scaleEffect(wave1)

                            RoundedRectangle(cornerRadius: cornerRadius + 14, style: .continuous)
                                .strokeBorder(
                                    Color.white.opacity(isPlaying ? 0.14 : 0.0),
                                    lineWidth: 1.0
                                )
                                .frame(width: adaptiveSide + 28, height: adaptiveSide + 28)
                                .scaleEffect(wave2)
                        }
                    }
                }

                // 3. 专辑封面主体（纯净无任何浮层提示；裁切仅限定在封面图本身，避免硬切外围光晕与声波环）
                DSCover(
                    url: coverURL,
                    title: bookTitle.isEmpty ? "有声书" : bookTitle,
                    side: adaptiveSide,
                    onImageLoaded: onImageLoaded
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isPlaying ? Color.white.opacity(0.28) : Color.white.opacity(0.12),
                            lineWidth: isPlaying ? 1.0 : 0.5
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(isPlaying ? 0.0 : 0.26))
                )
                .shadow(
                    color: isPlaying ? Color.black.opacity(0.52) : Color.black.opacity(0.30),
                    radius: isUltraCompactHeight ? 8 : (isPlaying ? 26 : 14),
                    x: 0,
                    y: isUltraCompactHeight ? 4 : (isPlaying ? 14 : 6)
                )
                .scaleEffect(scale)
                .rotation3DEffect(
                    .degrees(isPlaying || reduceMotion ? 0 : -4),
                    axis: (x: 1, y: 0, z: 0)
                )
                .dsAnimation(Motion.bouncy, value: scale)
                .dsAnimation(Motion.smooth, value: isPlaying)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onDoubleTapPlayPause()
                    }
                )
                .accessibilityLabel("专辑封面，双击播放或暂停")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: 272)
    }
}
