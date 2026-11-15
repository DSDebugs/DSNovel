import Foundation
import AVFoundation
import MediaPlayer
import SwiftData
import UIKit

/// 独立播放时钟 Observable（4.3 节）：仅进度条与时间文字订阅，避免整个播放页每秒重绘
@MainActor
@Observable
final class PlaybackClock {
    var currentTimeSec: Double = 0
    var durationSec: Double = 0

    var progressFraction: Double {
        guard durationSec > 0 else { return 0 }
        return min(max(currentTimeSec / durationSec, 0), 1)
    }

    var formattedCurrent: String {
        Self.formatSeconds(currentTimeSec)
    }

    var formattedRemaining: String {
        let rem = max(0, durationSec - currentTimeSec)
        return "-" + Self.formatSeconds(rem)
    }

    static func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

enum SleepTimerOption: Equatable {
    case off
    case minutes(Int)
    case endOfChapter
    case chaptersRemaining(Int)

    var label: String {
        switch self {
        case .off: return "定时关闭"
        case .minutes(let m): return "\(m) 分钟"
        case .endOfChapter: return "本章结束"
        case .chaptersRemaining(let c): return "\(c) 集后"
        }
    }
}

enum PlaybackState: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case failed(String)
}

/// 播放引擎（4.3 节）：管理 AVPlayer、片头片尾跳过、最后 30 秒线性渐弱睡眠定时、自定义请求头代理及锁屏控制中心
@MainActor
@Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    let clock = PlaybackClock()
    private(set) var state: PlaybackState = .idle
    private(set) var currentBook: BookRef?
    private(set) var currentChapter: ChapterDTO?
    private(set) var chapterQueue: [ChapterDTO] = []

    var speed: Double = 1.0 {
        didSet {
            if state == .playing {
                player.rate = Float(speed)
            }
        }
    }
    var bookVolume: Double = 1.0 {
        didSet {
            player.volume = Float(min(max(bookVolume, 0), 1.0))
        }
    }
    var skipIntroSec: Int = 0
    var skipOutroSec: Int = 0

    // 睡眠定时器状态
    var sleepOption: SleepTimerOption = .off
    private(set) var sleepRemainingSec: Int = 0
    private var sleepChaptersLeft: Int = 0
    private var sleepTimerTask: Task<Void, Never>?

    var isMiniPlayerVisible: Bool {
        currentBook != nil && currentChapter != nil
    }

    var currentBookID: String? {
        currentBook?.id
    }

    private let player = AVPlayer()
    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    private var resourceLoaderDelegate: CustomHeaderResourceLoader?
    private var lastPersistedTime: TimeInterval = 0
    private var hasRetriedCurrentChapter = false
    var modelContext: ModelContext?

    init() {
        configureRemoteCommands()
        observePeriodicTime()
        observeNotifications()
    }

    // MARK: - 播放入口与章节调度

    func startPlayback(
        book: BookRef,
        chapters: [ChapterDTO],
        startChapter: ChapterDTO,
        initialPositionMs: Int = 0
    ) {
        currentBook = book
        chapterQueue = chapters
        currentChapter = startChapter
        hasRetriedCurrentChapter = false

        loadBookPreferences(for: book.id)
        Task {
            await loadAndPlay(chapter: startChapter, initialPositionMs: initialPositionMs)
            await precacheUpcomingChapters()
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        case .paused, .idle:
            resume()
        case .failed:
            if let ch = currentChapter {
                Task { await loadAndPlay(chapter: ch, initialPositionMs: Int(clock.currentTimeSec * 1000)) }
            }
        case .buffering:
            pause()
        }
    }

    func pause() {
        player.pause()
        state = .paused
        persistProgressNow()
        updateNowPlayingInfo()
    }

    func resume() {
        configureAudioSession()
        // 恢复播放时回到该书记忆的音量（消除睡眠渐弱影响）
        player.volume = Float(bookVolume)
        player.playImmediately(atRate: Float(speed))
        state = .playing
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.clock.currentTimeSec = max(0, seconds)
                self?.persistProgressNow()
                self?.updateNowPlayingInfo()
            }
        }
    }

    func skipForward(_ deltaSec: Double = 30) {
        let next = min(clock.durationSec > 0 ? clock.durationSec : clock.currentTimeSec + deltaSec, clock.currentTimeSec + deltaSec)
        seek(to: next)
    }

    func skipBackward(_ deltaSec: Double = 15) {
        seek(to: max(0, clock.currentTimeSec - deltaSec))
    }

    func playNextChapter() {
        guard let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }),
              idx + 1 < chapterQueue.count else {
            pause()
            return
        }
        let nextCh = chapterQueue[idx + 1]
        currentChapter = nextCh
        hasRetriedCurrentChapter = false
        Task {
            await loadAndPlay(chapter: nextCh, initialPositionMs: 0)
            await precacheUpcomingChapters()
        }
    }

    func playPreviousChapter() {
        guard let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }),
              idx > 0 else {
            seek(to: 0)
            return
        }
        let prevCh = chapterQueue[idx - 1]
        currentChapter = prevCh
        hasRetriedCurrentChapter = false
        Task {
            await loadAndPlay(chapter: prevCh, initialPositionMs: 0)
        }
    }

    // MARK: - 睡眠定时器与最后 30 秒线性音量渐弱（4.3 节）

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimerTask?.cancel()
        sleepOption = option
        player.volume = Float(bookVolume)

        switch option {
        case .off:
            sleepRemainingSec = 0
            sleepChaptersLeft = 0
        case .minutes(let mins):
            sleepRemainingSec = mins * 60
            startCountdownTimer()
        case .endOfChapter:
            sleepRemainingSec = 0
            sleepChaptersLeft = 1
        case .chaptersRemaining(let count):
            sleepRemainingSec = 0
            sleepChaptersLeft = max(1, count)
        }
    }

    /// 计算最后 30 秒线性渐弱音量（供单元测试与定时器共用）
    nonisolated static func computeFadeVolume(baseVolume: Double, remainingSeconds: Int, fadeEnabled: Bool) -> Float {
        guard fadeEnabled, remainingSeconds > 0, remainingSeconds <= 30 else {
            return Float(min(max(baseVolume, 0), 1.0))
        }
        let ratio = Double(remainingSeconds) / 30.0
        return Float(min(max(baseVolume * ratio, 0), 1.0))
    }

    private func startCountdownTimer() {
        sleepTimerTask = Task {
            while !Task.isCancelled && sleepRemainingSec > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                if state == .playing {
                    sleepRemainingSec -= 1
                    let fadeOn = AppSettingsStore.shared.sleepFadeOutEnabled
                    player.volume = Self.computeFadeVolume(
                        baseVolume: bookVolume,
                        remainingSeconds: sleepRemainingSec,
                        fadeEnabled: fadeOn
                    )
                    if sleepRemainingSec <= 0 {
                        pause()
                        player.volume = Float(bookVolume)
                        sleepOption = .off
                        break
                    }
                }
            }
        }
    }

    // MARK: - 内部流加载与自定义请求头代理

    private func loadAndPlay(chapter: ChapterDTO, initialPositionMs: Int) async {
        guard let book = currentBook else { return }
        state = .buffering
        clock.currentTimeSec = 0
        clock.durationSec = Double(chapter.durationSec ?? 0)
        configureAudioSession()

        do {
            let playURL: URL
            var headers: [String: String] = [:]

            if let localURL = DownloadManager.shared.localFileURL(bookID: book.id, chapterID: chapter.id) {
                playURL = localURL
            } else {
                let stream = try await PluginRuntime.shared.resolvePlayURL(sourceID: book.sourceID, episodeURL: chapter.url)
                guard let remote = URL(string: stream.url) else {
                    throw PluginError.parseFailed("无效的音频 URL")
                }
                playURL = remote
                headers = stream.headers
            }

            let asset: AVURLAsset
            if !headers.isEmpty && !playURL.isFileURL {
                let delegate = CustomHeaderResourceLoader(headers: headers)
                self.resourceLoaderDelegate = delegate
                asset = delegate.makeAsset(for: playURL)
            } else {
                self.resourceLoaderDelegate = nil
                asset = AVURLAsset(url: playURL)
            }

            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain // 人声倍速更自然（4.3 节）
            player.replaceCurrentItem(with: item)

            let startSec = initialPositionMs > 0
                ? Double(initialPositionMs) / 1000.0
                : Double(max(0, skipIntroSec))

            if startSec > 0 {
                let target = CMTime(seconds: startSec, preferredTimescale: 600)
                await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            player.volume = Float(bookVolume)
            player.playImmediately(atRate: Float(speed))
            state = .playing
            persistProgressNow()
            updateNowPlayingInfo()
        } catch {
            if !hasRetriedCurrentChapter {
                hasRetriedCurrentChapter = true
                await loadAndPlay(chapter: chapter, initialPositionMs: initialPositionMs)
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func precacheUpcomingChapters() async {
        let count = AppSettingsStore.shared.precacheCount
        guard count > 0, let book = currentBook, let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }) else {
            return
        }
        let endIdx = min(chapterQueue.count, idx + 1 + count)
        guard idx + 1 < endIdx else { return }
        let upcoming = Array(chapterQueue[(idx + 1)..<endIdx])
        DownloadManager.shared.enqueueChapters(upcoming, for: book, kind: "precache")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = AppSettingsStore.shared.audioChannel == .spokenAudio ? .spokenAudio : .default
        try? session.setCategory(.playback, mode: mode, options: [])
        try? session.setActive(true)
    }

    private func observePeriodicTime() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let sec = time.seconds
                guard sec.isFinite && sec >= 0 else { return }
                self.clock.currentTimeSec = sec

                if let item = self.player.currentItem {
                    let dur = item.duration.seconds
                    if dur.isFinite && dur > 0 {
                        self.clock.durationSec = dur
                        // 片尾跳过检测
                        if self.skipOutroSec > 0 && sec >= max(1, dur - Double(self.skipOutroSec)) {
                            self.handleChapterFinished()
                            return
                        }
                    }
                }

                // 每 5 秒落库一次播放进度（4.1 节）
                if abs(sec - self.lastPersistedTime) >= 5.0 {
                    self.lastPersistedTime = sec
                    self.persistProgressNow()
                }
            }
        }
    }

    private func observeNotifications() {
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleChapterFinished()
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            Task { @MainActor in
                if type == .began {
                    self?.pause()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistProgressNow()
            }
        }
    }

    private func handleChapterFinished() {
        if let book = currentBook, let finished = currentChapter {
            DownloadManager.shared.cleanupPrecacheIfNeeded(bookID: book.id, chapterID: finished.id)
        }
        if sleepOption == .endOfChapter {
            pause()
            sleepOption = .off
            return
        }
        if case .chaptersRemaining = sleepOption {
            sleepChaptersLeft -= 1
            if sleepChaptersLeft <= 0 {
                pause()
                sleepOption = .off
                return
            }
        }
        playNextChapter()
    }

    // MARK: - SwiftData 进度与单书配置读写

    private func loadBookPreferences(for bookID: String) {
        let settings = AppSettingsStore.shared
        guard let ctx = modelContext else {
            speed = settings.defaultSpeed
            skipIntroSec = settings.defaultSkipIntroSec
            skipOutroSec = settings.defaultSkipOutroSec
            bookVolume = 1.0
            return
        }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            speed = saved.speed > 0 ? saved.speed : settings.defaultSpeed
            skipIntroSec = saved.skipIntroSec >= 0 ? saved.skipIntroSec : settings.defaultSkipIntroSec
            skipOutroSec = saved.skipOutroSec >= 0 ? saved.skipOutroSec : settings.defaultSkipOutroSec
            bookVolume = settings.rememberBookVolume ? saved.volume : 1.0
        } else {
            speed = settings.defaultSpeed
            skipIntroSec = settings.defaultSkipIntroSec
            skipOutroSec = settings.defaultSkipOutroSec
            bookVolume = 1.0
        }
    }

    func saveBookAudioSettings() {
        guard let ctx = modelContext, let bookID = currentBook?.id else { return }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            saved.speed = speed
            saved.volume = bookVolume
            saved.skipIntroSec = skipIntroSec
            saved.skipOutroSec = skipOutroSec
            try? ctx.save()
        }
    }

    func persistProgressNow() {
        guard let ctx = modelContext, let book = currentBook, let chapter = currentChapter else { return }
        let bookID = book.id
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            saved.lastChapterID = chapter.id
            saved.lastChapterTitle = chapter.title
            saved.lastPositionMs = Int(clock.currentTimeSec * 1000)
            saved.lastPlayedAt = .now
            try? ctx.save()
        }
    }

    // MARK: - 锁屏与控制中心（MPNowPlayingInfoCenter & MPRemoteCommandCenter）

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNextChapter()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPreviousChapter()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward(30)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward(15)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: posEvent.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let book = currentBook, let chapter = currentChapter else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyArtist: book.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.currentTimeSec,
            MPMediaItemPropertyPlaybackDuration: clock.durationSec,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? speed : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// 通过 AVAssetResourceLoaderDelegate 为需要自定义 Referer / User-Agent 的音频源注入请求头（4.3 节）
final class CustomHeaderResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let headers: [String: String]
    private var originalScheme: String = "https"

    init(headers: [String: String]) {
        self.headers = headers
        super.init()
    }

    func makeAsset(for url: URL) -> AVURLAsset {
        originalScheme = url.scheme ?? "https"
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "dsnovel-stream"
        let asset = AVURLAsset(url: comps?.url ?? url)
        asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "com.dsnovel.resourceloader"))
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let customURL = loadingRequest.request.url,
              var comps = URLComponents(url: customURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        comps.scheme = originalScheme
        guard let realURL = comps.url else { return false }

        var req = URLRequest(url: realURL)
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            let end = start + Int64(dataRequest.requestedLength) - 1
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            if let http = response as? HTTPURLResponse {
                loadingRequest.contentInformationRequest?.contentType = http.mimeType
                loadingRequest.contentInformationRequest?.contentLength = http.expectedContentLength
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
            }
            if let data {
                loadingRequest.dataRequest?.respond(with: data)
            }
            loadingRequest.finishLoading()
        }
        task.resume()
        return true
    }
}
