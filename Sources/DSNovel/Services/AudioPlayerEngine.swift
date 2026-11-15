import Foundation
import AVFoundation
import MediaPlayer
import Observation
import os

enum SleepTimerPreset: String, CaseIterable, Identifiable, Sendable {
    case off = "定时"
    case min15 = "15分"
    case min30 = "30分"
    case min60 = "60分"
    case endOfEpisode = "本集结束"

    var id: String { rawValue }
}

/// DSNovel v12.0 音频播放引擎（含代次令牌、系统事件监听、节流存盘与状态机）
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
    var errorMessage: String? = nil
    var statusBanner: String = "准备就绪"

    var playbackRate: Float = 1.0 {
        didSet { UserDefaults.standard.set(playbackRate, forKey: "dsnovel_rate_v12") }
    }
    var skipIntroSeconds: Double = 0 {
        didSet { UserDefaults.standard.set(skipIntroSeconds, forKey: "dsnovel_skip_intro_v12") }
    }
    var skipOutroSeconds: Double = 0 {
        didSet { UserDefaults.standard.set(skipOutroSeconds, forKey: "dsnovel_skip_outro_v12") }
    }

    var sleepTimerPreset: SleepTimerPreset = .off
    var sleepTimerRemainingSeconds: Int? = nil

    var currentEpisode: EpisodeItem? {
        guard episodes.indices.contains(currentEpisodeIndex) else { return nil }
        return episodes[currentEpisodeIndex]
    }

    private let logger = Logger(subsystem: "com.dsnovel.app", category: "AudioPlayerEngine")
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var sleepTimerTask: Task<Void, Never>?

    private var playbackGeneration: Int = 0
    private var playbackTask: Task<Void, Never>?
    private var isAdvancing: Bool = false
    private var lastPersistedAt: Date = .distantPast

    private init() {
        let savedRate = UserDefaults.standard.float(forKey: "dsnovel_rate_v12")
        if savedRate > 0 { self.playbackRate = savedRate }
        self.skipIntroSeconds = UserDefaults.standard.double(forKey: "dsnovel_skip_intro_v12")
        self.skipOutroSeconds = UserDefaults.standard.double(forKey: "dsnovel_skip_outro_v12")

        configureAudioSession()
        setupRemoteTransportControls()
        setupSystemAudioNotifications()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        } catch {
            logger.error("AVAudioSession setCategory failed: \(error.localizedDescription)")
        }
        do {
            try session.setActive(true)
        } catch {
            logger.error("AVAudioSession setActive failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 一键播放（先保留上下文再并发加载，保留书架秒级续播进度，H-02/H-03）
    func quickPlay(book: BookItem, startEpisodeIndex: Int? = nil, resumeTime: Double? = nil) {
        playbackTask?.cancel()
        playbackGeneration += 1
        let gen = playbackGeneration

        self.isLoadingStream = true
        self.errorMessage = nil
        self.statusBanner = "正在加载《\(book.title)》目录..."

        playbackTask = Task { [weak self] in
            guard let self else { return }
            let result = await DualSourceEngine.shared.fetchAllBookEpisodes(for: book)
            guard gen == self.playbackGeneration, !Task.isCancelled else { return }

            guard !result.episodes.isEmpty else {
                self.isLoadingStream = false
                self.errorMessage = "未能加载到可用章节目录，请检查网络后重试"
                return
            }

            let savedEntry = LibraryStore.shared.entry(for: book.id)
            let targetIdx = startEpisodeIndex ?? savedEntry?.lastEpisodeIndex ?? 0
            let safeIdx = min(max(0, targetIdx), result.episodes.count - 1)
            let targetResume: Double
            if let explicit = resumeTime {
                targetResume = explicit
            } else if let savedEntry, savedEntry.lastEpisodeIndex == safeIdx {
                targetResume = savedEntry.lastPlaybackTime
            } else {
                targetResume = 0
            }

            await self.executePlayback(
                book: book,
                episodes: result.episodes,
                index: safeIdx,
                resumeTime: targetResume,
                generation: gen
            )
        }
    }

    func startPlayback(book: BookItem, episodes: [EpisodeItem], index: Int, resumeTime: Double = 0) {
        playbackTask?.cancel()
        playbackGeneration += 1
        let gen = playbackGeneration
        playbackTask = Task { [weak self] in
            await self?.executePlayback(
                book: book,
                episodes: episodes,
                index: index,
                resumeTime: resumeTime,
                generation: gen
            )
        }
    }

    private func executePlayback(
        book: BookItem,
        episodes: [EpisodeItem],
        index: Int,
        resumeTime: Double,
        generation: Int
    ) async {
        guard episodes.indices.contains(index) else { return }

        self.currentBook = book
        self.episodes = episodes
        self.currentEpisodeIndex = index
        self.currentTime = 0
        self.duration = 0
        self.isAdvancing = false
        self.isLoadingStream = true
        self.errorMessage = nil

        let episode = episodes[index]
        self.statusBanner = "正在缓冲：\(episode.displayTitle)"

        do {
            let streamURL = try await DualSourceEngine.shared.resolveStreamURL(for: episode, in: book)
            guard generation == self.playbackGeneration, !Task.isCancelled else { return }

            let startSec = max(resumeTime, skipIntroSeconds)
            playStream(url: streamURL, startAt: startSec)
            self.isLoadingStream = false
            self.statusBanner = "\(book.source.coverTopTag) · 正在播放"
            LibraryStore.shared.updateProgress(
                book: book,
                episodeIndex: index,
                episodeTitle: episode.displayTitle,
                time: startSec
            )
            updateNowPlayingInfo()
        } catch {
            guard generation == self.playbackGeneration, !Task.isCancelled else { return }
            self.isLoadingStream = false
            self.isPlaying = false
            self.errorMessage = error.localizedDescription
            self.statusBanner = "播放受阻"
        }
    }

    private func playStream(url: URL, startAt: Double) {
        cleanupPlayerObservers()
        configureAudioSession()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain

        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }

        // KVO 监听真实播放状态（H-09）
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            Task { @MainActor in
                guard let self else { return }
                switch avPlayer.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.isLoadingStream = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isLoadingStream = true
                case .paused:
                    self.isPlaying = false
                    self.isLoadingStream = false
                @unknown default:
                    break
                }
                self.updateNowPlayingInfo()
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] avItem, _ in
            Task { @MainActor in
                guard let self else { return }
                if avItem.status == .failed {
                    self.isPlaying = false
                    self.isLoadingStream = false
                    self.errorMessage = avItem.error?.localizedDescription ?? "音频加载失败"
                    self.statusBanner = "音频加载失败"
                }
            }
        }

        player?.playImmediately(atRate: playbackRate)

        if startAt > 1 {
            player?.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
            self.currentTime = startAt
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
                    // H-01: 使用 isAdvancing 防止异步取流期间连续跳过多集
                    if self.skipOutroSeconds > 0,
                       dur > self.skipOutroSeconds + 15,
                       sec >= dur - self.skipOutroSeconds,
                       !self.isAdvancing {
                        self.isAdvancing = true
                        self.playNextEpisode()
                        return
                    }
                }
                // H-03: 仅在 sec > 1 且距离上次存盘 >= 10 秒时持久化
                if sec > 1,
                   Date().timeIntervalSince(self.lastPersistedAt) >= 10,
                   let b = self.currentBook,
                   let ep = self.currentEpisode {
                    self.lastPersistedAt = Date()
                    LibraryStore.shared.updateProgress(
                        book: b,
                        episodeIndex: self.currentEpisodeIndex,
                        episodeTitle: ep.displayTitle,
                        time: sec
                    )
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.sleepTimerPreset == .endOfEpisode {
                    self.sleepTimerPreset = .off
                    self.sleepTimerRemainingSeconds = nil
                    self.pause()
                    self.statusBanner = "本集已播完并定时停止"
                    return
                }
                if !self.isAdvancing {
                    self.isAdvancing = true
                    self.playNextEpisode()
                }
            }
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断"
                self.errorMessage = err
                self.statusBanner = "播放出错"
                self.isPlaying = false
            }
        }
    }

    func play() {
        guard let player else {
            if let book = currentBook {
                quickPlay(book: book, startEpisodeIndex: currentEpisodeIndex)
            }
            return
        }
        configureAudioSession()
        player.playImmediately(atRate: playbackRate)
        statusBanner = "\(currentBook?.source.coverTopTag ?? "喜马拉雅") · 正在播放"
        updateNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        statusBanner = "已暂停"
        if let b = currentBook, let ep = currentEpisode, currentTime > 1 {
            LibraryStore.shared.updateProgress(book: b, episodeIndex: currentEpisodeIndex, episodeTitle: ep.displayTitle, time: currentTime)
        }
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func playNextEpisode() {
        guard let book = currentBook, !episodes.isEmpty else { return }
        let nextIdx = currentEpisodeIndex + 1
        guard episodes.indices.contains(nextIdx) else {
            pause()
            statusBanner = "已播放至最后一集"
            return
        }
        startPlayback(book: book, episodes: episodes, index: nextIdx, resumeTime: 0)
    }

    func playPreviousEpisode() {
        guard let book = currentBook, !episodes.isEmpty else { return }
        let prevIdx = max(0, currentEpisodeIndex - 1)
        startPlayback(book: book, episodes: episodes, index: prevIdx, resumeTime: 0)
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

    // MARK: - 独立睡眠定时档位 (M-13)
    func cycleSleepTimer() {
        let all = SleepTimerPreset.allCases
        let currentIdx = all.firstIndex(of: sleepTimerPreset) ?? 0
        let next = all[(currentIdx + 1) % all.count]
        applySleepTimer(next)
    }

    func applySleepTimer(_ preset: SleepTimerPreset) {
        sleepTimerTask?.cancel()
        sleepTimerPreset = preset
        switch preset {
        case .off, .endOfEpisode:
            sleepTimerRemainingSeconds = nil
        case .min15:
            startCountdown(minutes: 15)
        case .min30:
            startCountdown(minutes: 30)
        case .min60:
            startCountdown(minutes: 60)
        }
    }

    private func startCountdown(minutes: Int) {
        sleepTimerRemainingSeconds = minutes * 60
        sleepTimerTask = Task {
            while let rem = sleepTimerRemainingSeconds, rem > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                sleepTimerRemainingSeconds = rem - 1
                if rem - 1 <= 0 {
                    pause()
                    sleepTimerPreset = .off
                    sleepTimerRemainingSeconds = nil
                    break
                }
            }
        }
    }

    private func cleanupPlayerObservers() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failedObserver {
            NotificationCenter.default.removeObserver(failedObserver)
            self.failedObserver = nil
        }
    }

    private func setupSystemAudioNotifications() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    self.pause()
                } else if type == .ended,
                          let optVal = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                          AVAudioSession.InterruptionOptions(rawValue: optVal).contains(.shouldResume) {
                    self.play()
                }
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
            if reason == .oldDeviceUnavailable {
                Task { @MainActor in
                    self?.pause()
                }
            }
        }
    }

    private func setupRemoteTransportControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
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
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: posEvent.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let book = currentBook, let ep = currentEpisode else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.displayTitle,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author.isEmpty ? book.source.displayName : book.author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
