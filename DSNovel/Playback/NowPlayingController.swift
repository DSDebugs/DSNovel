import Foundation
import MediaPlayer
import UIKit

/// 锁屏与控制中心元数据控制器（§4.2）：
/// 统一写入标题、书名、时长、实时进度、章节序号（MPMediaItemPropertyAlbumTrackNumber）与异步封面（MPMediaItemPropertyArtwork），
/// 并按封面 URL 缓存 MPMediaItemArtwork，避免每秒周期刷新时重复请求或闪烁。
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    private var cachedCoverURL: String = ""
    private var cachedArtwork: MPMediaItemArtwork?
    private var loadingCoverURL: String = ""
    private var coverLoadTask: Task<Void, Never>?

    init() {}

    func clear() {
        coverLoadTask?.cancel()
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

        let coverURL = book.cover
        if !coverURL.isEmpty, coverURL == cachedCoverURL, let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        } else if !coverURL.isEmpty,
                  let memImg = CoverImagePipeline.shared.cachedInMemory(for: coverURL, side: 280) {
            let art = MPMediaItemArtwork(boundsSize: memImg.size) { _ in memImg }
            cachedCoverURL = coverURL
            cachedArtwork = art
            info[MPMediaItemPropertyArtwork] = art
        } else if !coverURL.isEmpty, loadingCoverURL != coverURL {
            loadingCoverURL = coverURL
            coverLoadTask?.cancel()
            coverLoadTask = Task { [weak self] in
                let fetched = await CoverImagePipeline.shared.image(
                    for: coverURL,
                    targetSize: CGSize(width: 280, height: 280)
                )
                guard !Task.isCancelled, let self, let fetched else { return }
                let art = MPMediaItemArtwork(boundsSize: fetched.size) { _ in fetched }
                self.cachedCoverURL = coverURL
                self.cachedArtwork = art
                self.loadingCoverURL = ""
                var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                currentInfo[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
