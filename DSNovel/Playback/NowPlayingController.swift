import Foundation
import MediaPlayer
import UIKit

/// 锁屏与控制中心元数据控制器（§4.2）：
/// 统一写入标题、书名、时长、实时进度、章节序号（MPMediaItemPropertyAlbumTrackNumber）与异步封面（MPMediaItemPropertyArtwork），
/// 并按封面 URL 缓存 MPMediaItemArtwork，避免周期刷新时重复请求或闪烁。
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    private var activeBookID: String?
    private var cachedCoverURL: String = ""
    private var cachedArtwork: MPMediaItemArtwork?
    private var loadingCoverURL: String = ""
    private var coverLoadTask: Task<Void, Never>?

    private static let artworkSidePt: CGFloat = 280
    private static let artworkMaxPixels: CGFloat = 600

    private static var artworkDisplayScale: CGFloat {
        let activeSceneScale = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .screen.scale
        let rawScale = activeSceneScale ?? UITraitCollection.current.displayScale
        let displayScale = rawScale > 0 ? rawScale : 2.0
        return min(displayScale, artworkMaxPixels / artworkSidePt)
    }

    init() {}

    func clear() {
        coverLoadTask?.cancel()
        coverLoadTask = nil
        activeBookID = nil
        cachedCoverURL = ""
        cachedArtwork = nil
        loadingCoverURL = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func update(
        book: BookRef?,
        chapter: ChapterDTO?,
        chapterIndexOneBased: Int,
        totalChapters: Int,
        elapsedSec: Double,
        durationSec: Double,
        isPlaying: Bool,
        speed: Double
    ) {
        guard let book, let chapter else {
            clear()
            return
        }

        activeBookID = book.id
        let targetBookID = book.id
        let coverURL = book.cover

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyArtist: book.author.isEmpty ? book.title : "\(book.title) · \(book.author)",
            MPMediaItemPropertyAlbumTitle: book.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedSec),
            MPMediaItemPropertyPlaybackDuration: max(0, durationSec),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if chapterIndexOneBased > 0 {
            info[MPMediaItemPropertyAlbumTrackNumber] = chapterIndexOneBased
        }
        if totalChapters > 0 {
            info[MPMediaItemPropertyAlbumTrackCount] = totalChapters
        }

        if coverURL.isEmpty {
            // 切换至无封面书籍时主动清理旧书封面缓存与进行中的拉取任务
            coverLoadTask?.cancel()
            coverLoadTask = nil
            cachedCoverURL = ""
            cachedArtwork = nil
            loadingCoverURL = ""
        } else if coverURL == cachedCoverURL, let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        } else if let memImg = CoverImagePipeline.shared.cachedInMemory(
            for: coverURL,
            side: Self.artworkSidePt,
            scale: Self.artworkDisplayScale
        ) {
            let art = MPMediaItemArtwork(boundsSize: memImg.size) { _ in memImg }
            cachedCoverURL = coverURL
            cachedArtwork = art
            loadingCoverURL = ""
            info[MPMediaItemPropertyArtwork] = art
        } else if loadingCoverURL != coverURL {
            // 切换到不同封面 URL 时清理旧封面避免串图
            if cachedCoverURL != coverURL {
                cachedCoverURL = ""
                cachedArtwork = nil
            }
            let artworkScale = Self.artworkDisplayScale
            loadingCoverURL = coverURL
            coverLoadTask?.cancel()
            coverLoadTask = Task { [weak self] in
                defer {
                    if let self, self.loadingCoverURL == coverURL {
                        self.loadingCoverURL = ""
                    }
                }
                let fetched = await CoverImagePipeline.shared.image(
                    for: coverURL,
                    targetSize: CGSize(width: Self.artworkSidePt, height: Self.artworkSidePt),
                    scale: artworkScale
                )
                guard !Task.isCancelled,
                      let self,
                      self.activeBookID == targetBookID,
                      let fetched else {
                    return
                }
                let art = MPMediaItemArtwork(boundsSize: fetched.size) { _ in fetched }
                self.cachedCoverURL = coverURL
                self.cachedArtwork = art
                var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                currentInfo[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
