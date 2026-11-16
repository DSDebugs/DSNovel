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

/// 播放引擎（对齐 ssts Player.resolveAsset & Player.loadAndPlay）：
/// 使用 AVURLAssetHTTPHeaderFieldsKey 原生注入自定义 Referer/UA/Cookie、支持 HLS (.m3u8) 与流式 MP3/M4A 播放、
/// KVO 监听 AVPlayerItem.status == .readyToPlay 后精准跳转进度，并自动同步「最近播放」与「书架」最后播放章节及时间。
@MainActor
@Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    let clock = PlaybackClock()
    private(set) var state: PlaybackState = .idle
    private(set) var currentBook: BookRef?
    private(set) var currentChapter: ChapterDTO?
    private(set) var chapterQueue: [ChapterDTO] = []
    /// 最近一次插件解析错误（若为 .needLogin 或 .needVerify，支持在播放页/详情页一键打开网页登录）
    private(set) var lastPluginError: PluginError?

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
    private var failedEndObserverToken: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0
    private var pendingSeekSec: Double?
    private var lastPersistedTime: TimeInterval = 0
    private var hasRetriedCurrentChapter = false
    /// 当前 AVPlayerItem 是否已 readyToPlay 且属于「当前章节」。
    /// 未就绪前（解析播放地址、缓冲中）绝不允许周期观察者用播放器上一条音频的时间/时长污染进度时钟与数据库。
    private var isCurrentItemReady = false
    /// 当前章节对应的 AVPlayerItem，用于周期观察者校验时间来源
    private var loadedItem: AVPlayerItem?
    /// 章节列表缓存签名：同一本书、同一份章节队列只落盘一次，避免每次保存进度都重新编码+压缩整本章节目录
    private var savedQueueSignature: String?
    private var precacheTask: Task<Void, Never>?
    /// 当前章节正在播放本地文件但文件损坏时，强制改走在线流
    private var bypassLocalChapterID: String?
    private var isPlayingLocalFile = false
    /// 当前章节地址是否由「内置解析」给出（用于直链过期后的强制重解析）
    private var builtinParserResolved = false
    var modelContext: ModelContext?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
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
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration

        currentBook = book
        chapterQueue = chapters
        currentChapter = startChapter
        lastPluginError = nil
        hasRetriedCurrentChapter = false

        loadBookPreferences(for: book.id)
        let startSec = initialPositionMs > 0
            ? Double(initialPositionMs) / 1000.0
            : Double(max(0, skipIntroSec))
        // 先摘掉上一条音频：否则解析新章节播放地址期间，周期观察者会把「上一章/上一本书」的时间写进新章节
        detachCurrentItem(startSec: startSec)
        clock.currentTimeSec = startSec
        clock.durationSec = startChapter.hintDurationSec
        // 立即记录到「最近播放」（及已加入书架书籍的最后播放章节与时间）
        persistProgressNow(positionMsOverride: Int(startSec * 1000))

        loadTask = Task {
            await loadAndPlay(chapter: startChapter, initialPositionMs: initialPositionMs, generation: gen)
        }
    }

    /// 摘除当前播放项并重置所有与「旧音频」相关的状态
    private func detachCurrentItem(startSec: Double) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedItem = nil
        isCurrentItemReady = false
        isPlayingLocalFile = false
        pendingSeekSec = startSec > 0.5 ? startSec : nil
        lastPersistedTime = startSec
        state = .buffering
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        case .paused, .idle:
            if player.currentItem?.status == .readyToPlay {
                resume()
            } else if let ch = currentChapter {
                retryCurrentChapter()
            } else {
                resume()
            }
        case .failed:
            retryCurrentChapter()
        case .buffering:
            pause()
        }
    }

    func retryCurrentChapter() {
        guard let ch = currentChapter else { return }
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration
        hasRetriedCurrentChapter = false
        lastPluginError = nil
        let resumeMs = Int(clock.currentTimeSec * 1000)
        detachCurrentItem(startSec: Double(resumeMs) / 1000.0)
        loadTask = Task {
            await loadAndPlay(chapter: ch, initialPositionMs: resumeMs, generation: gen)
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
        let clamped = max(0, seconds)
        clock.currentTimeSec = clamped
        guard isCurrentItemReady, let item = player.currentItem, item.status == .readyToPlay else {
            pendingSeekSec = clamped
            persistProgressNow(positionMsOverride: Int(clamped * 1000))
            return
        }
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clock.currentTimeSec = clamped
                self.persistProgressNow(positionMsOverride: Int(clamped * 1000))
                self.updateNowPlayingInfo()
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
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration
        currentChapter = nextCh
        lastPluginError = nil
        hasRetriedCurrentChapter = false
        let startSec = Double(max(0, skipIntroSec))
        detachCurrentItem(startSec: startSec)
        clock.currentTimeSec = startSec
        clock.durationSec = nextCh.hintDurationSec
        persistProgressNow(positionMsOverride: max(0, skipIntroSec * 1000))

        loadTask = Task {
            await loadAndPlay(chapter: nextCh, initialPositionMs: 0, generation: gen)
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
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration
        currentChapter = prevCh
        lastPluginError = nil
        hasRetriedCurrentChapter = false
        let startSec = Double(max(0, skipIntroSec))
        detachCurrentItem(startSec: startSec)
        clock.currentTimeSec = startSec
        clock.durationSec = prevCh.hintDurationSec
        persistProgressNow(positionMsOverride: max(0, skipIntroSec * 1000))

        loadTask = Task {
            await loadAndPlay(chapter: prevCh, initialPositionMs: 0, generation: gen)
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

    // MARK: - 内部流加载与原生 AVURLAsset 请求头构建（100% 对齐 ssts Player.resolveAsset）

    nonisolated static func makeStreamAsset(url playURL: URL, headers rawHeaders: [String: String], kind: StreamKind) -> AVURLAsset {
        if playURL.isFileURL {
            return AVURLAsset(url: playURL)
        }
        var wireHeaders = rawHeaders
        var mediaTypeHint: String?
        for key in Array(wireHeaders.keys) where key.lowercased() == "x-media-type" {
            mediaTypeHint = wireHeaders.removeValue(forKey: key)?.lowercased()
        }
        if !wireHeaders.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            wireHeaders["User-Agent"] = JsHostBridge.mobileUA
        }
        if !wireHeaders.keys.contains(where: { $0.lowercased() == "cookie" }) {
            let cookieStr = CookieSync.cookieHeader(for: playURL)
            if !cookieStr.isEmpty {
                wireHeaders["Cookie"] = cookieStr
            }
        }

        var options: [String: Any] = [:]
        if !wireHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = wireHeaders
        }

        let ext = playURL.pathExtension.lowercased()
        let absLower = playURL.absoluteString.lowercased()
        if kind == .hls || mediaTypeHint == "hls" || ext == "m3u8" || absLower.contains(".m3u8") {
            options["AVURLAssetOutOfBandMIMETypeKey"] = "application/x-mpegURL"
        } else if ext == "m4a" || ext == "mp4" {
            options["AVURLAssetOutOfBandMIMETypeKey"] = "audio/mp4"
        }
        return AVURLAsset(url: playURL, options: options)
    }

    private func loadAndPlay(chapter: ChapterDTO, initialPositionMs: Int, generation: UInt64) async {
        guard let book = currentBook, generation == playbackGeneration else { return }
        let startSec = initialPositionMs > 0
            ? Double(initialPositionMs) / 1000.0
            : Double(max(0, skipIntroSec))
        // 重试路径同样需要先摘除旧播放项、重置「就绪」标记与待跳转位置
        detachCurrentItem(startSec: startSec)

        state = .buffering
        lastPluginError = nil
        clock.currentTimeSec = startSec
        clock.durationSec = chapter.hintDurationSec
        configureAudioSession()

        do {
            let playURL: URL
            var headers: [String: String] = [:]
            var streamKind: StreamKind = .onDemand

            var usingLocal = false
            if bypassLocalChapterID != chapter.id,
               let localURL = DownloadManager.shared.localFileURL(bookID: book.id, chapterID: chapter.id) {
                playURL = localURL
                usingLocal = true
            } else {
                // 统一解析入口：官方书源接口优先，VIP/受限章节自动回退到「内置解析」
                let stream = try await PluginRuntime.shared.resolvePlayStream(sourceID: book.sourceID, episodeURL: chapter.url)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                guard let remote = JsHostBridge.makeRequestURL(from: stream.url, relativeTo: chapter.url) else {
                    throw PluginError.parseFailed("无效的音频 URL")
                }
                playURL = remote
                headers = stream.headers
                streamKind = stream.kind
                builtinParserResolved = stream.resolvedBy == BuiltinParserRuntime.resolverTag
            }

            guard !Task.isCancelled, generation == playbackGeneration else { return }

            let asset = Self.makeStreamAsset(url: playURL, headers: headers, kind: streamKind)
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain // 人声倍速更自然（4.3 节）
            item.preferredForwardBufferDuration = 15

            loadedItem = item
            isPlayingLocalFile = usingLocal
            observePlayerItem(item, chapter: chapter, initialPositionMs: initialPositionMs, generation: generation)
            player.replaceCurrentItem(with: item)
            player.volume = Float(bookVolume)

            if pendingSeekSec == nil {
                player.playImmediately(atRate: Float(speed))
            }
            persistProgressNow(positionMsOverride: Int(startSec * 1000))
            updateNowPlayingInfo()
        } catch let pErr as PluginError {
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            lastPluginError = pErr
            if !hasRetriedCurrentChapter, case .network = pErr {
                hasRetriedCurrentChapter = true
                await loadAndPlay(chapter: chapter, initialPositionMs: initialPositionMs, generation: generation)
            } else {
                state = .failed(pErr.localizedDescription)
            }
        } catch {
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            if !hasRetriedCurrentChapter {
                hasRetriedCurrentChapter = true
                await loadAndPlay(chapter: chapter, initialPositionMs: initialPositionMs, generation: generation)
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func observePlayerItem(
        _ item: AVPlayerItem,
        chapter: ChapterDTO,
        initialPositionMs: Int,
        generation: UInt64
    ) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let itemStatus = observedItem.status
            let itemID = ObjectIdentifier(observedItem)
            let itemDurationSec = observedItem.duration.seconds
            let itemErrorDesc = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                // 仅处理「当前章节」的播放项，过期项的状态回调一律丢弃
                guard let self, generation == self.playbackGeneration,
                      let loaded = self.loadedItem, ObjectIdentifier(loaded) == itemID else { return }
                switch itemStatus {
                case .readyToPlay:
                    guard !self.isCurrentItemReady else { return }
                    self.isCurrentItemReady = true
                    if itemDurationSec.isFinite && itemDurationSec > 0 {
                        self.clock.durationSec = itemDurationSec
                    }
                    self.schedulePrecache(generation: generation)
                    if let seekSec = self.pendingSeekSec, seekSec > 0 {
                        // 保持 pendingSeekSec 直到 seek 完成：期间周期观察者不得改写进度时钟
                        self.clock.currentTimeSec = seekSec
                        let target = CMTime(seconds: seekSec, preferredTimescale: 600)
                        self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self, generation == self.playbackGeneration else { return }
                                self.pendingSeekSec = nil
                                self.lastPersistedTime = seekSec
                                self.configureAudioSession()
                                self.player.volume = Float(self.bookVolume)
                                self.player.playImmediately(atRate: Float(self.speed))
                                self.state = .playing
                                self.persistProgressNow(positionMsOverride: Int(seekSec * 1000))
                                self.updateNowPlayingInfo()
                            }
                        }
                    } else {
                        self.pendingSeekSec = nil
                        self.configureAudioSession()
                        self.player.volume = Float(self.bookVolume)
                        self.player.playImmediately(atRate: Float(self.speed))
                        self.state = .playing
                        self.persistProgressNow()
                        self.updateNowPlayingInfo()
                    }
                case .failed:
                    let errMsg = itemErrorDesc ?? "音频流加载失败"
                    if self.isPlayingLocalFile, let book = self.currentBook {
                        // 本地（预缓存/下载）文件损坏：删除记录并改走在线流，不消耗重试次数
                        DownloadManager.shared.invalidateLocalFile(bookID: book.id, chapterID: chapter.id)
                        self.bypassLocalChapterID = chapter.id
                        await self.loadAndPlay(
                            chapter: chapter,
                            initialPositionMs: Int(self.clock.currentTimeSec * 1000),
                            generation: generation
                        )
                    } else if !self.hasRetriedCurrentChapter {
                        self.hasRetriedCurrentChapter = true
                        // 内置解析给出的直链可能已过期：重试前先作废缓存，强制重新解析
                        if self.builtinParserResolved {
                            await BuiltinParserRuntime.shared.invalidateCache(parserID: nil, episodeURL: chapter.url)
                        }
                        await self.loadAndPlay(
                            chapter: chapter,
                            initialPositionMs: initialPositionMs,
                            generation: generation
                        )
                    } else {
                        self.state = .failed(errMsg)
                    }
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            let tcStatus = avPlayer.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackGeneration else { return }
                switch tcStatus {
                case .playing:
                    self.state = .playing
                    self.updateNowPlayingInfo()
                case .waitingToPlayAtSpecifiedRate:
                    if case .playing = self.state {
                        self.state = .buffering
                    }
                case .paused:
                    if case .playing = self.state {
                        self.state = .paused
                        self.updateNowPlayingInfo()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    /// 预缓存必须让位于「当前章节起播」：等当前章节稳定播放 8 秒后才开始，且切章即取消。
    /// 原实现在点击章节的同一时刻就解析后续章节地址并整文件下载，抢占带宽、JS 上下文与 WebView 嗅探通道（全局串行），
    /// 这正是「选章加载非常缓慢、一直在缓存」的主因之一。
    private func schedulePrecache(generation: UInt64) {
        precacheTask?.cancel()
        guard AppSettingsStore.shared.precacheCount > 0 else { return }
        precacheTask = Task { [weak self] in
            var waited = 0
            while waited < 120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, generation == self.playbackGeneration else { return }
                if self.state == .playing, self.isCurrentItemReady, self.clock.currentTimeSec >= 8 { break }
                waited += 1
            }
            guard let self, !Task.isCancelled, generation == self.playbackGeneration, waited < 120 else { return }
            await self.precacheUpcomingChapters()
        }
    }

    private func precacheUpcomingChapters() async {
        let count = AppSettingsStore.shared.precacheCount
        guard count > 0, let book = currentBook, let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }) else {
            return
        }
        DownloadManager.shared.dropQueuedPrecache()
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
                // 只接受「当前章节、已就绪」播放项的时间：切章/解析地址/待跳转期间，播放器仍可能回报上一条音频的时间，
                // 此前正是它把旧时间写进新章节的时钟与 lastPositionMs，造成新书首次选章时进度时间混乱。
                guard self.isCurrentItemReady, self.pendingSeekSec == nil,
                      let item = self.player.currentItem, item === self.loadedItem else { return }
                let sec = time.seconds
                guard sec.isFinite && sec >= 0 else { return }
                self.clock.currentTimeSec = sec

                let dur = item.duration.seconds
                if dur.isFinite && dur > 0 {
                    self.clock.durationSec = dur
                    // 片尾跳过检测（章节比跳过时长还短时不触发）
                    if self.skipOutroSec > 0,
                       dur > Double(self.skipOutroSec) + 1,
                       sec >= dur - Double(self.skipOutroSec) {
                        self.handleChapterFinished()
                        return
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
        ) { [weak self] note in
            let finishedID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            Task { @MainActor [weak self] in
                guard let self,
                      let currentItem = self.player.currentItem,
                      finishedID == ObjectIdentifier(currentItem) else { return }
                self.handleChapterFinished()
            }
        }

        failedEndObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let failedID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断"
            Task { @MainActor [weak self] in
                guard let self,
                      let currentItem = self.player.currentItem,
                      failedID == ObjectIdentifier(currentItem) else { return }
                self.state = .failed(err)
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

    // MARK: - SwiftData 进度与单书配置读写（「书架」与「最近播放」统一记录进度、严格分离归属）

    private func loadBookPreferences(for bookID: String) {
        let settings = AppSettingsStore.shared
        guard let ctx = modelContext else {
            speed = settings.defaultSpeed
            skipIntroSec = settings.defaultSkipIntroSec
            skipOutroSec = settings.defaultSkipOutroSec
            bookVolume = 1.0
            return
        }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
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
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            saved.speed = speed
            saved.volume = bookVolume
            saved.skipIntroSec = skipIntroSec
            saved.skipOutroSec = skipOutroSec
            try? ctx.save()
        }
    }

    /// 持久化当前播放进度：
    /// - 若书籍已在数据库（无论是在书架 `inShelf == true` 还是仅在最近播放 `inShelf == false`），更新其最后播放章节、进度毫秒数与最后播放时间；
    /// - 若书籍尚未在数据库，创建一条 `inShelf = false` 的记录，使其仅出现在「最近播放」而不会自动污染「书架」。
    func persistProgressNow(positionMsOverride: Int? = nil) {
        guard let ctx = modelContext, let book = currentBook, let chapter = currentChapter else { return }
        let bookID = book.id
        let posMs = positionMsOverride ?? max(0, Int(clock.currentTimeSec * 1000))
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            saved.lastChapterID = chapter.id
            saved.lastChapterTitle = chapter.title
            saved.lastPositionMs = posMs
            saved.lastPlayedAt = .now
            if !book.cover.isEmpty && saved.cover.isEmpty {
                saved.cover = book.cover
            }
            if !book.author.isEmpty && saved.author.isEmpty {
                saved.author = book.author
            }
            try? ctx.save()
        } else {
            let historyBook = Book(
                id: book.id,
                sourceID: book.sourceID,
                bookURL: book.bookURL,
                title: book.title,
                author: book.author,
                cover: book.cover,
                intro: book.intro,
                inShelf: false,
                addedAt: .now,
                lastChapterID: chapter.id,
                lastChapterTitle: chapter.title,
                lastPositionMs: posMs,
                lastPlayedAt: .now,
                volume: bookVolume,
                skipIntroSec: skipIntroSec,
                skipOutroSec: skipOutroSec,
                speed: speed
            )
            ctx.insert(historyBook)
            try? ctx.save()
        }
        saveChapterQueueIfNeeded(for: book.id)
    }

    /// 章节目录缓存：同一本书同一份队列只编码+压缩一次，并放到后台线程。
    /// 原实现每次保存进度（每 5 秒、每次 seek/暂停/切章）都在主线程重新序列化整本章节目录，章节越多越卡。
    private func saveChapterQueueIfNeeded(for bookID: String) {
        guard !chapterQueue.isEmpty else { return }
        let signature = "\(bookID)#\(chapterQueue.count)#\(chapterQueue.first?.id ?? "")#\(chapterQueue.last?.id ?? "")"
        guard signature != savedQueueSignature else { return }
        savedQueueSignature = signature
        let queue = chapterQueue
        Task.detached(priority: .utility) {
            ChapterCacheStore.saveChapters(queue, for: bookID)
        }
    }

    // MARK: - 锁屏与控制中心（MPNowPlayingInfoCenter & MPRemoteCommandCenter）

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNextChapter() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPreviousChapter() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward(30) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward(15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let targetTime = posEvent.positionTime
            Task { @MainActor in self?.seek(to: targetTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let book = currentBook, let chapter = currentChapter else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyArtist: book.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.currentTimeSec,
            MPMediaItemPropertyPlaybackDuration: clock.durationSec,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? speed : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
