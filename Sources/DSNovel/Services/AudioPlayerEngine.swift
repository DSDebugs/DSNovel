import Foundation
import AVFoundation
import MediaPlayer
import Observation

/// DSNovel v6.0 零杂音硬件音频引擎 + 全量章节自动预载
@Observable
@MainActor
final class AudioPlayerEngine {
    static let shared = AudioPlayerEngine()

    var currentBook: BookItem? = nil
    var episodes: [EpisodeItem] = []
    var currentEpisodeIndex: Int = 0
    var isPlaying: Bool = false
    var isLoadingStream: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var errorMessage: String? = nil
    var statusBanner: String = "准备就绪"

    // 播放配置与音效预设
    var skipIntroSeconds: Double = 0
    var skipOutroSeconds: Double = 0
    var preampGainDB: Float = 2.0
    var activeEQPreset: String = "人声清晰"
    var sleepTimerRemainingSeconds: Int? = nil

    var currentEpisode: EpisodeItem? {
        guard episodes.indices.contains(currentEpisodeIndex) else { return nil }
        return episodes[currentEpisodeIndex]
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sleepTimerTask: Task<Void, Never>?

    private init() {
        configureAudioSession()
        setupRemoteTransportControls()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("AVAudioSession configure error: \(error)")
        }
    }

    // MARK: - 一键快捷播放书籍（自动一次性加载全集目录并播放上次进度或第1集）
    func quickPlay(book: BookItem, startEpisodeIndex: Int? = nil) async {
        self.currentBook = book
        self.isLoadingStream = true
        self.errorMessage = nil
        self.statusBanner = "正在一次性同步《\(book.title)》全量章节..."

        let allEpisodes = await DualSourceEngine.shared.fetchAllBookEpisodes(for: book)
        guard !allEpisodes.isEmpty else {
            self.isLoadingStream = false
            self.errorMessage = "未能加载到可用章节目录，请点击右上角“换源”重试"
            return
        }

        self.episodes = allEpisodes
        let savedEntry = LibraryStore.shared.entry(for: book.id)
        let targetIdx = startEpisodeIndex ?? savedEntry?.lastEpisodeIndex ?? 0
        let safeIdx = min(max(0, targetIdx), allEpisodes.count - 1)
        await startPlayback(book: book, episodes: allEpisodes, index: safeIdx, resumeTime: startEpisodeIndex == nil ? (savedEntry?.lastPlaybackTime ?? 0) : 0)
    }

    func startPlayback(book: BookItem, episodes: [EpisodeItem], index: Int, resumeTime: Double = 0) async {
        guard episodes.indices.contains(index) else { return }
        self.currentBook = book
        self.episodes = episodes
        self.currentEpisodeIndex = index
        self.isLoadingStream = true
        self.errorMessage = nil

        let episode = episodes[index]
        self.statusBanner = "正在解析：\(episode.displayTitle)"

        do {
            let (streamURL, headers) = try await DualSourceEngine.shared.resolveStreamURL(for: episode, in: book)
            playStream(url: streamURL, headers: headers, startAt: max(resumeTime, skipIntroSeconds))
            self.isLoadingStream = false
            self.statusBanner = "\(book.source.coverTopTag) · \(activeEQPreset) · 正在播放"
            LibraryStore.shared.updateProgress(book: book, episodeIndex: index, episodeTitle: episode.displayTitle, time: currentTime)
            updateNowPlayingInfo()
        } catch {
            // 自动跨源容灾升级：多轮尝试 + 跨源同名匹配 + 跳过VIP集
            var recovered = false

            // 第一轮：直接切换到另一书源的同名书籍
            if let altBook = await DualSourceEngine.shared.findAlternateSourceBook(for: book) {
                let altEpisodes = await DualSourceEngine.shared.fetchAllBookEpisodes(for: altBook)
                let targetIdx = min(index, max(0, altEpisodes.count - 1))
                if altEpisodes.indices.contains(targetIdx),
                   let (altURL, altHeaders) = try? await DualSourceEngine.shared.resolveStreamURL(for: altEpisodes[targetIdx], in: altBook) {
                    self.currentBook = altBook
                    self.episodes = altEpisodes
                    self.currentEpisodeIndex = targetIdx
                    playStream(url: altURL, headers: altHeaders, startAt: max(resumeTime, skipIntroSeconds))
                    self.statusBanner = "已自动优选 \(altBook.source.coverTopTag) 播放"
                    LibraryStore.shared.updateProgress(book: altBook, episodeIndex: targetIdx, episodeTitle: altEpisodes[targetIdx].displayTitle, time: currentTime)
                    updateNowPlayingInfo()
                    recovered = true
                }
            }

            // 第二轮：跨源回退未果 → 在当前章节列表中向后跳过本集尝试下一集（VIP集自动跳到免费集）
            if !recovered && episodes.count > index + 1 {
                for offset in 1...min(5, episodes.count - index - 1) {
                    let nextIdx = index + offset
                    guard episodes.indices.contains(nextIdx) else { break }
                    let nextEp = episodes[nextIdx]
                    if nextEp.isFree,
                       let (nextURL, nextHeaders) = try? await DualSourceEngine.shared.resolveStreamURL(for: nextEp, in: book) {
                        self.currentEpisodeIndex = nextIdx
                        playStream(url: nextURL, headers: nextHeaders, startAt: 0)
                        self.statusBanner = "已自动跳过VIP集，续播第\(nextEp.index)集"
                        LibraryStore.shared.updateProgress(book: book, episodeIndex: nextIdx, episodeTitle: nextEp.displayTitle, time: 0)
                        updateNowPlayingInfo()
                        recovered = true
                        break
                    }
                }
            }

            if !recovered {
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
                self.statusBanner = "VIP章节已自动跳过全部免费通道均未匹配，可尝试登录账号或点击换源"
            }
            self.isLoadingStream = false
        }
    }

    private func playStream(url: URL, headers: [String: String], startAt: Double) {
        cleanupPlayerObservers()
        configureAudioSession()

        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain // 专为有声书人声优化的变速不变调算法，彻底消除金属杂音

        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }

        // 预放增益转换
        let linearVolume = min(1.0, max(0.2, pow(10.0, preampGainDB / 20.0) * 0.8))
        player?.volume = linearVolume
        player?.playImmediately(atRate: playbackRate)
        self.isPlaying = true

        if startAt > 1 {
            let targetCM = CMTime(seconds: startAt, preferredTimescale: 600)
            player?.seek(to: targetCM)
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let sec = time.seconds
                if sec.isFinite && sec >= 0 {
                    self.currentTime = sec
                }
                if let dur = self.player?.currentItem?.duration.seconds, dur.isFinite && dur > 0 {
                    self.duration = dur
                    if self.skipOutroSeconds > 0 && dur > self.skipOutroSeconds + 15 && sec >= dur - self.skipOutroSeconds {
                        self.playNextEpisode()
                    }
                }
                if Int(sec) % 10 == 0, let b = self.currentBook, let ep = self.currentEpisode {
                    LibraryStore.shared.updateProgress(book: b, episodeIndex: self.currentEpisodeIndex, episodeTitle: ep.displayTitle, time: sec)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.playNextEpisode()
            }
        }
    }

    func togglePlayPause() {
        guard let player else {
            if let book = currentBook {
                Task { await quickPlay(book: book, startEpisodeIndex: currentEpisodeIndex) }
            }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
            statusBanner = "已暂停"
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            statusBanner = "\(currentBook?.source.coverTopTag ?? "双核") · 正在播放"
        }
        updateNowPlayingInfo()
    }

    func playNextEpisode() {
        guard let book = currentBook, !episodes.isEmpty else { return }
        let nextIdx = currentEpisodeIndex + 1
        guard episodes.indices.contains(nextIdx) else {
            isPlaying = false
            statusBanner = "已播放至最后一集"
            return
        }
        Task {
            await startPlayback(book: book, episodes: episodes, index: nextIdx, resumeTime: 0)
        }
    }

    func playPreviousEpisode() {
        guard let book = currentBook, !episodes.isEmpty else { return }
        let prevIdx = max(0, currentEpisodeIndex - 1)
        Task {
            await startPlayback(book: book, episodes: episodes, index: prevIdx, resumeTime: 0)
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    func skip(by delta: Double) {
        let target = max(0, min(duration > 0 ? duration : currentTime + delta, currentTime + delta))
        seek(to: target)
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
        updateNowPlayingInfo()
    }

    func cyclePlaybackRate() {
        let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        if let idx = rates.firstIndex(of: playbackRate) {
            setRate(rates[(idx + 1) % rates.count])
        } else {
            setRate(1.25)
        }
    }

    // MARK: - 睡眠定时器
    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        guard let minutes, minutes > 0 else {
            sleepTimerRemainingSeconds = nil
            return
        }
        sleepTimerRemainingSeconds = minutes * 60
        sleepTimerTask = Task {
            while let rem = sleepTimerRemainingSeconds, rem > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                sleepTimerRemainingSeconds = rem - 1
                if rem - 1 <= 0 {
                    if isPlaying { togglePlayPause() }
                    sleepTimerRemainingSeconds = nil
                    break
                }
            }
        }
    }

    func cycleSleepTimer() {
        switch sleepTimerRemainingSeconds {
        case nil: setSleepTimer(minutes: 15)
        case let s? where s <= 15 * 60: setSleepTimer(minutes: 30)
        case let s? where s <= 30 * 60: setSleepTimer(minutes: 60)
        default: setSleepTimer(minutes: nil)
        }
    }

    // MARK: - 一键换源续播当前集（增强：多候选匹配 + 自动跳过VIP集）
    func switchSourceForCurrentBook() async {
        guard let currentBook else { return }
        isLoadingStream = true
        statusBanner = "正在智能匹配备用免费书源..."

        let targetSource: CoreSourceID = (currentBook.source == .fanqie) ? .ximalaya : .fanqie
        let cleanTitle = currentBook.title
            .replacingOccurrences(of: "\u{ff08}.*\u{ff09}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 多候选搜索备选书源
        var candidates: [BookItem] = []
        switch targetSource {
        case .fanqie:
            candidates = await DualSourceEngine.shared.searchFanqieBooksMulti(keyword: cleanTitle)
        case .ximalaya:
            candidates = await DualSourceEngine.shared.searchXimalayaBooksMulti(keyword: cleanTitle)
        }

        for altBook in candidates.prefix(3) {
            let altEpisodes = await DualSourceEngine.shared.fetchAllBookEpisodes(for: altBook)
            guard !altEpisodes.isEmpty else { continue }
            let targetIdx = min(currentEpisodeIndex, altEpisodes.count - 1)
            if altEpisodes.indices.contains(targetIdx),
               let (altURL, altHeaders) = try? await DualSourceEngine.shared.resolveStreamURL(for: altEpisodes[targetIdx], in: altBook) {
                self.currentBook = altBook
                self.episodes = altEpisodes
                self.currentEpisodeIndex = targetIdx
                playStream(url: altURL, headers: altHeaders, startAt: max(currentTime, skipIntroSeconds))
                self.statusBanner = "已切换至 \(altBook.source.coverTopTag) 播放"
                LibraryStore.shared.updateProgress(book: altBook, episodeIndex: targetIdx, episodeTitle: altEpisodes[targetIdx].displayTitle, time: currentTime)
                updateNowPlayingInfo()
                isLoadingStream = false
                return
            }
        }

        isLoadingStream = false
        statusBanner = "当前已是最佳可用书源，VIP章节可尝试登录对应账号"
    }

    private func cleanupPlayerObservers() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func setupRemoteTransportControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNextEpisode() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPreviousEpisode() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let book = currentBook, let ep = currentEpisode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.displayTitle,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: "\(book.author) · \(book.source.displayName)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
