import AVFoundation
import DSCore
import DSPluginKit
import DSStorage
import Foundation
import Observation

/// 播放核心协调器（SYS2-01 Swift 6 安全释放 + SYS2-04 弱网卡顿与电话中断自动续播 + L-IOS-3 强类型状态机）
@Observable
@MainActor
public final class PlaybackCoordinator {
    public internal(set) var state: PlaybackState = .idle
    public internal(set) var currentBook: BookSummaryDTO?
    public internal(set) var chapters: [ChapterDTO] = []
    public internal(set) var currentChapterIndex: Int = 0
    public internal(set) var activeStream: AudioStreamDTO?
    public internal(set) var bookSkipConfig: SkipConfigDTO = SkipConfigDTO()
    public var playbackRate: Double = 1.0 {
        didSet {
            let clamped = playbackRate.isFinite ? min(3.0, max(0.5, playbackRate)) : 1.0
            if playbackRate != clamped {
                playbackRate = clamped
            }
            if state.isPlaying { player.rate = Float(playbackRate) }
            syncNowPlaying()
        }
    }
    public var preferredQuality: AudioQualityTier = .auto
    public var autoPlayNextChapter: Bool = true
    public var isOnWiFi: Bool = true
    public var allowUltraHighQuality: Bool = false
    public var onRequestPrecache: (@MainActor (BookSummaryDTO, [ChapterDTO]) -> Void)?
    public var onRecordListeningDelta: (@MainActor (BookSummaryDTO, Double) -> Void)?
    public var onResolveBookQuality: (@MainActor (BookSummaryDTO) -> AudioQualityTier)?

    public let clock = PlaybackClock()
    public let dsp = AudioTapDSP()
    public let sleepTimer = SleepTimerEngine()

    let player = AVPlayer()
    let audioResolver: any AudioResolving
    let offlineLocator: (any OfflineAudioLocating)?
    let progressStore: any PlaybackProgressPersisting
    let remoteController = RemoteCommandController()
    let logger: DSDiagnosticLogStore
    let observerBag = PlaybackObserverBag()

    var generationCounter: UInt64 = 0
    var loadTask: Task<Void, Never>?
    weak var activePlayerItem: AVPlayerItem?
    var timeObserverToken: Any?
    var lastPersistedAt: Date = .distantPast
    var wasPlayingBeforeInterruption: Bool = false
    var isSeeking: Bool = false
    var seekGeneration: UInt64 = 0
    var hasAttachedAudioMix: Bool = false
    var pendingResumePositionMs: Int?
    var lastListeningTickAt: Date?

    public var currentChapter: ChapterDTO? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    public init(
        audioResolver: any AudioResolving,
        offlineLocator: (any OfflineAudioLocating)? = nil,
        progressStore: any PlaybackProgressPersisting,
        logger: DSDiagnosticLogStore
    ) {
        self.audioResolver = audioResolver
        self.offlineLocator = offlineLocator
        self.progressStore = progressStore
        self.logger = logger
        setupObservers()
        dsp.onParametersUpdated = { [weak self] in
            self?.attachAudioMixIfNeededForActiveItem()
        }
    }

    public func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        dsp.resetWatchdog()
        sleepTimer.cancel()
        isSeeking = false
        seekGeneration &+= 1
        hasAttachedAudioMix = false
        pendingResumePositionMs = nil
        lastListeningTickAt = nil
        wasPlayingBeforeInterruption = false
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        observerBag.tearDownAll()
        remoteController.tearDown()
        player.pause()
        activePlayerItem = nil
        player.replaceCurrentItem(with: nil)
        state = .idle
    }

    public func play(book: BookSummaryDTO, chapters: [ChapterDTO], startIndex: Int, autoPlay: Bool = true) {
        guard chapters.indices.contains(startIndex) else { return }
        if let resolver = onResolveBookQuality {
            self.preferredQuality = resolver(book)
        }
        self.currentBook = book
        self.chapters = chapters
        self.currentChapterIndex = startIndex
        loadCurrentChapter(autoPlay: autoPlay)
    }

    /// 冷启动恢复上次播放的书籍、章节目录与进度（保持暂停态不自动外放，点播放时按需加载音频流）
    public func restoreSession(
        book: BookSummaryDTO,
        chapters: [ChapterDTO],
        chapterIndex: Int,
        positionMs: Int,
        durationMs: Int
    ) {
        guard currentBook == nil, state == .idle, !chapters.isEmpty else { return }
        let safeIndex = min(max(0, chapterIndex), chapters.count - 1)
        let safePosMs = max(0, positionMs)
        let safeDurMs = max(0, durationMs)
        if let resolver = onResolveBookQuality {
            self.preferredQuality = resolver(book)
        }
        self.currentBook = book
        self.chapters = chapters
        self.currentChapterIndex = safeIndex
        self.pendingResumePositionMs = safePosMs
        self.clock.update(current: Double(safePosMs) / 1000.0, duration: Double(safeDurMs) / 1000.0, buffered: 0)
        self.state = .paused(generation: generationCounter)
        self.syncNowPlaying()
    }

    public func retryCurrentChapter() {
        loadCurrentChapter(autoPlay: true)
    }

    public func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        case .buffering(_, let shouldPlay):
            if shouldPlay { pause() } else { resume() }
        case .paused, .ended:
            resume()
        case .failed:
            loadCurrentChapter(autoPlay: true)
        case .idle:
            break
        }
    }

    public func pause() {
        wasPlayingBeforeInterruption = false
        state = state.applyingPauseOrInterrupt()
        lastListeningTickAt = nil
        player.pause()
        persistCurrentProgress(isFinished: false, overrideFinished: false, force: true)
        syncNowPlaying()
    }

    public func resume() {
        if !sleepTimer.isActive && dsp.currentFadeGain < 1.0 {
            applySleepFade(factor: 1.0)
        }
        if activePlayerItem == nil, currentChapter != nil {
            loadCurrentChapter(autoPlay: true, resumePositionOverrideMs: pendingResumePositionMs)
            return
        }
        let wasEnded: Bool
        if case .ended = state {
            wasEnded = true
        } else {
            wasEnded = false
        }
        let next = state.applyingResume()
        state = next
        if wasEnded {
            let intro = effectiveIntroSeconds(forDuration: clock.durationSeconds)
            seekGeneration &+= 1
            let seekGen = seekGeneration
            isSeeking = true
            clock.update(current: intro, duration: clock.durationSeconds, buffered: bufferedDuration(for: player.currentItem))
            Self.performSeek(on: player, to: CMTime(seconds: intro, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.seekGeneration == seekGen else { return }
                    self.isSeeking = false
                    if self.state.isPlaying {
                        self.remoteController.configureAudioSession()
                        self.player.playImmediately(atRate: Float(self.playbackRate))
                        self.triggerWatchdogIfReady()
                    }
                    self.syncNowPlaying()
                }
            }
            syncNowPlaying()
            return
        }
        if case .buffering(let gen, true) = next,
           gen == generationCounter,
           activePlayerItem?.status == .readyToPlay,
           !isSeeking {
            let readyState = next.applyingReadyToPlay(for: gen)
            state = readyState
            if readyState.isPlaying {
                remoteController.configureAudioSession()
                player.playImmediately(atRate: Float(playbackRate))
                triggerWatchdogIfReady()
            }
        } else if next.isPlaying {
            remoteController.configureAudioSession()
            player.playImmediately(atRate: Float(playbackRate))
            triggerWatchdogIfReady()
        }
        syncNowPlaying()
    }

    /// 电话/系统中断开始：记录中断前是否处于播放意图，随后立刻清意图防缓冲态外放
    public func handleAudioInterruptionBegan() {
        wasPlayingBeforeInterruption = state.shouldPlayWhenReady
        state = state.applyingPauseOrInterrupt()
        player.pause()
        persistCurrentProgress(isFinished: false, overrideFinished: false, force: true)
        syncNowPlaying()
    }

    /// 系统中断结束且允许恢复（SYS2-04）
    public func handleAudioInterruptionEndedShouldResume() {
        guard wasPlayingBeforeInterruption else { return }
        wasPlayingBeforeInterruption = false
        resume()
    }

    /// 系统中断结束但未携带 .shouldResume：清零中断前播放标记，避免后续误恢复（AUD-51）
    public func handleAudioInterruptionEndedWithoutResume() {
        wasPlayingBeforeInterruption = false
    }

    /// 耳机拔出：永久暂停不自动恢复
    public func handleAudioRouteUnplugged() {
        wasPlayingBeforeInterruption = false
        state = state.applyingPauseOrInterrupt()
        player.pause()
        persistCurrentProgress(isFinished: false, overrideFinished: false, force: true)
        syncNowPlaying()
    }

    /// 系统媒体服务重置：重新同步音量与播放状态（AUD-51）
    public func handleMediaServicesWereReset() {
        wasPlayingBeforeInterruption = false
        let shouldResume = state.shouldPlayWhenReady
        dsp.syncFadeVolume(to: player)
        if currentChapter != nil, activePlayerItem != nil {
            let capturedPosMs = clock.durationSeconds > 0 ? Int(clock.currentSeconds * 1000) : pendingResumePositionMs
            loadCurrentChapter(autoPlay: shouldResume, resumePositionOverrideMs: capturedPosMs)
        } else {
            state = state.applyingPauseOrInterrupt()
            syncNowPlaying()
        }
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped: Double
        if clock.durationSeconds > 1 {
            clamped = min(max(0, clock.durationSeconds - 0.5), max(0, seconds))
        } else {
            clamped = max(0, seconds)
        }
        if activePlayerItem == nil {
            pendingResumePositionMs = Int(clamped * 1000)
            clock.update(current: clamped, duration: clock.durationSeconds, buffered: 0)
            persistCurrentProgress(isFinished: false, overrideFinished: true, force: true)
            syncNowPlaying()
            return
        }
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        seekGeneration &+= 1
        let seekGen = seekGeneration
        isSeeking = true
        clock.update(current: clamped, duration: clock.durationSeconds, buffered: bufferedDuration(for: player.currentItem))
        Self.performSeek(on: player, to: target) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == seekGen else { return }
                self.isSeeking = false
                self.completeSeekPlaybackIfNeeded()
                self.syncNowPlaying()
            }
        }
        persistCurrentProgress(isFinished: false, overrideFinished: true, force: true)
        syncNowPlaying()
    }

    public func skipBy(_ deltaSeconds: Double) {
        seek(to: clock.currentSeconds + deltaSeconds)
    }

    public func nextChapter(autoPlay: Bool = true, persistCurrent: Bool = true) {
        guard currentChapterIndex + 1 < chapters.count else {
            state = .ended(generation: generationCounter)
            player.pause()
            syncNowPlaying()
            return
        }
        if persistCurrent {
            persistCurrentProgress(isFinished: false, overrideFinished: false, force: true)
        }
        currentChapterIndex += 1
        loadCurrentChapter(autoPlay: autoPlay)
    }

    public func previousChapter(autoPlay: Bool = true) {
        guard currentChapterIndex > 0 else {
            seek(to: effectiveIntroSeconds(forDuration: clock.durationSeconds))
            return
        }
        persistCurrentProgress(isFinished: false, overrideFinished: false, force: true)
        currentChapterIndex -= 1
        loadCurrentChapter(autoPlay: autoPlay)
    }

    public func updateBookSkipConfig(_ config: SkipConfigDTO) {
        bookSkipConfig = config
        guard let bookID = currentBook?.id else { return }
        let store = progressStore
        Task { await store.saveBookSkipConfig(bookID: bookID, config: config) }
    }

    public func applySleepFade(factor: Float) {
        dsp.applyFadeVolume(to: player, factor: factor)
    }

    public func switchQuality(_ tier: AudioQualityTier) {
        preferredQuality = tier
        guard currentChapter != nil else { return }
        let resumeMs: Int?
        if state.isBuffering && clock.durationSeconds <= 0 {
            resumeMs = pendingResumePositionMs
        } else {
            let captured = Int(clock.currentSeconds * 1000)
            resumeMs = captured
            pendingResumePositionMs = captured
            persistCurrentProgress(isFinished: false, overrideFinished: false, force: true)
        }
        loadCurrentChapter(autoPlay: state.shouldPlayWhenReady, resumePositionOverrideMs: resumeMs)
    }

    func setChapterEndedPause(generation gen: UInt64) {
        state = .paused(generation: gen)
        player.pause()
    }

    func setChapterEnded(generation gen: UInt64) {
        state = .ended(generation: gen)
        player.pause()
    }

    func advanceChapterForSleepTimer() {
        currentChapterIndex += 1
        loadCurrentChapter(autoPlay: false)
    }

    func applyStateFromObserver(_ next: PlaybackState) {
        state = next
    }
}
