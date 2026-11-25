import AVFoundation
import DSCore
import Foundation

/// 播放进度持久化、观察者绑定与锁屏媒体信息同步扩展（SYS3-03：拆分自 PlaybackCoordinator 留足 400 行维护裕度）
extension PlaybackCoordinator {
    nonisolated private static func observeItemStatus(
        for item: AVPlayerItem,
        onChange: @escaping @Sendable (AVPlayerItem.Status, String, Double) -> Void
    ) -> NSKeyValueObservation {
        item.observe(\.status, options: [.initial, .new]) { observed, _ in
            let status = observed.status
            let errText = observed.error?.localizedDescription ?? "音频加载失败"
            let observedDur = observed.duration.seconds
            onChange(status, errText, observedDur)
        }
    }

    nonisolated static func performSeek(
        on player: AVPlayer,
        to time: CMTime,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            completion(finished)
        }
    }

    func effectiveIntroSeconds(forDuration validDur: Double) -> Double {
        let rawIntro = max(0, Double(bookSkipConfig.introSeconds))
        if validDur > 0 && rawIntro >= validDur - 2.0 {
            return 0
        }
        return rawIntro
    }

    func completeSeekPlaybackIfNeeded() {
        if case .buffering(let gen, _) = state,
           gen == generationCounter,
           activePlayerItem?.status == .readyToPlay {
            let nextState = state.applyingReadyToPlay(for: gen)
            applyStateFromObserver(nextState)
            if nextState.isPlaying {
                remoteController.configureAudioSession()
                player.playImmediately(atRate: Float(playbackRate))
                triggerWatchdogIfReady()
            }
        } else if state.isPlaying, player.timeControlStatus == .paused {
            remoteController.configureAudioSession()
            player.playImmediately(atRate: Float(playbackRate))
            triggerWatchdogIfReady()
        }
    }

    func persistCurrentProgress(isFinished: Bool, overrideFinished: Bool, force: Bool) {
        switch state {
        case .idle, .failed:
            return
        case .buffering where clock.durationSeconds <= 0:
            return
        default:
            break
        }
        guard let book = currentBook, let chapter = currentChapter else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastPersistedAt) < 4.0 { return }
        lastPersistedAt = now
        let posMs = Int(clock.currentSeconds * 1000)
        let durMs = Int(clock.durationSeconds * 1000)
        let store = progressStore
        Task {
            await store.saveProgress(
                book: book,
                chapter: chapter,
                positionMs: posMs,
                durationMs: durMs,
                isFinished: isFinished,
                overrideFinished: overrideFinished
            )
        }
    }

    func applyLivePlaybackRate(_ targetRate: Float) {
        let hasPlayableBuffer: Bool = {
            guard let item = player.currentItem else { return false }
            if let url = (item.asset as? AVURLAsset)?.url, url.isFileURL { return true }
            let now = CMTimeGetSeconds(player.currentTime())
            guard now.isFinite else { return false }
            for value in item.loadedTimeRanges {
                let range = value.timeRangeValue
                let start = CMTimeGetSeconds(range.start)
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                if now >= start - 0.5 && end > now + 0.5 { return true }
            }
            return false
        }()
        if hasPlayableBuffer {
            player.playImmediately(atRate: targetRate)
        } else {
            player.rate = targetRate
        }
    }

    func scheduleDebouncedNowPlayingSync() {
        nowPlayingSyncDebounceTask?.cancel()
        nowPlayingSyncDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.syncNowPlaying()
        }
    }

    func syncNowPlaying() {
        guard let book = currentBook, let chapter = currentChapter else { return }
        let syncArtwork = onLookupCachedArtwork?(book.coverURL)
        remoteController.updateNowPlaying(
            bookTitle: book.title,
            chapterTitle: chapter.title,
            narrator: book.narrator,
            coverURL: book.coverURL,
            artworkImage: syncArtwork,
            elapsed: clock.currentSeconds,
            duration: clock.durationSeconds,
            rate: playbackRate,
            isPlaying: state.isPlaying,
            canPrevious: currentChapterIndex > 0,
            canNext: currentChapterIndex + 1 < chapters.count,
            chapterNumber: currentChapterIndex + 1,
            chapterCount: chapters.count
        )
        remoteController.ensureArtworkLoaded(
            for: book.coverURL,
            syncLookup: onLookupCachedArtwork,
            asyncLoader: onLoadArtwork
        )
    }

    func triggerWatchdogIfReady() {
        guard hasAttachedAudioMix, state.isPlaying, player.timeControlStatus == .playing else { return }
        dsp.startWatchdogIfNeeded()
    }

    func bufferedDuration(for item: AVPlayerItem?) -> Double? {
        guard let ranges = item?.loadedTimeRanges, !ranges.isEmpty else { return nil }
        var maxEnd: Double = 0
        for value in ranges {
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(value.timeRangeValue))
            if end.isFinite && end > maxEnd {
                maxEnd = end
            }
        }
        return maxEnd > 0 ? maxEnd : nil
    }

    func attachItemObservers(item: AVPlayerItem, generation gen: UInt64, savedPositionMs: Int, savedFinished: Bool) {
        let statusObs = Self.observeItemStatus(for: item) { [weak self] status, errText, observedDur in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generationCounter else { return }
                switch status {
                case .readyToPlay:
                    guard case .buffering = self.state else { return }
                    let validDur = observedDur.isFinite && observedDur > 0 ? observedDur : self.clock.durationSeconds
                    let introSec = self.effectiveIntroSeconds(forDuration: validDur)
                    let rawSaved = savedFinished ? 0 : Double(savedPositionMs) / 1000.0
                    let nearEnd = validDur > 5 && (rawSaved >= validDur * 0.95 || (validDur - rawSaved) < 3.0)
                    let startAt = nearEnd ? introSec : max(introSec, rawSaved)
                    let completeReady: @MainActor @Sendable () -> Void = { [weak self] in
                        guard let self, gen == self.generationCounter else { return }
                        self.pendingResumePositionMs = nil
                        let nextState = self.state.applyingReadyToPlay(for: gen)
                        self.applyStateFromObserver(nextState)
                        self.clock.update(
                            current: startAt > 0.5 ? startAt : 0,
                            duration: validDur,
                            buffered: self.bufferedDuration(for: self.activePlayerItem)
                        )
                        if nextState.isPlaying {
                            self.remoteController.configureAudioSession()
                            self.player.playImmediately(atRate: Float(self.playbackRate))
                            self.triggerWatchdogIfReady()
                        }
                        self.syncNowPlaying()
                    }
                    if startAt > 0.5 {
                        self.seekGeneration &+= 1
                        let seekGen = self.seekGeneration
                        self.isSeeking = true
                        self.clock.update(
                            current: startAt,
                            duration: validDur,
                            buffered: self.bufferedDuration(for: self.activePlayerItem)
                        )
                        Self.performSeek(on: self.player, to: CMTime(seconds: startAt, preferredTimescale: 600)) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self, self.seekGeneration == seekGen else { return }
                                self.isSeeking = false
                                completeReady()
                            }
                        }
                    } else {
                        completeReady()
                    }
                case .failed:
                    self.applyStateFromObserver(.failed(generation: gen, message: errText))
                default:
                    break
                }
            }
        }

        let endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleChapterEnded(generation: gen) }
        }
        let stallObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generationCounter, self.state.isPlaying else { return }
                self.applyStateFromObserver(.buffering(generation: gen, shouldPlayWhenReady: true))
                self.syncNowPlaying()
            }
        }
        observerBag.replaceItemObservers(end: endObs, stall: stallObs, status: statusObs)
    }

    func handleChapterEnded(generation gen: UInt64) {
        guard gen == generationCounter else { return }
        persistCurrentProgress(isFinished: true, overrideFinished: true, force: true)
        if sleepTimer.consumeChapterFinished() {
            if currentChapterIndex + 1 < chapters.count {
                advanceChapterForSleepTimer()
            } else {
                setChapterEndedPause(generation: gen)
                syncNowPlaying()
            }
            return
        }
        if autoPlayNextChapter {
            nextChapter(autoPlay: true, persistCurrent: false)
        } else {
            setChapterEnded(generation: gen)
            syncNowPlaying()
        }
    }

    func attachPeriodicTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let current = time.seconds
            Task { @MainActor [weak self] in
                guard let self, self.activePlayerItem != nil, self.player.currentItem === self.activePlayerItem else { return }
                if case .buffering(let gen, true) = self.state, self.player.timeControlStatus == .playing {
                    self.applyStateFromObserver(.playing(generation: gen))
                    self.triggerWatchdogIfReady()
                    self.syncNowPlaying()
                } else if self.state.isPlaying, self.player.timeControlStatus == .playing, !self.dsp.isWatchdogPending {
                    self.triggerWatchdogIfReady()
                }
                guard !self.isSeeking else { return }
                let dur = self.player.currentItem?.duration.seconds ?? 0
                let validDur = dur.isFinite && dur > 0 ? dur : self.clock.durationSeconds
                self.clock.update(current: current, duration: validDur, buffered: self.bufferedDuration(for: self.player.currentItem))

                let outro = Double(self.bookSkipConfig.outroSeconds)
                if outro > 0, validDur > outro + 5, current >= (validDur - outro), self.state.isPlaying {
                    self.handleChapterEnded(generation: self.generationCounter)
                    return
                }
                if self.state.isPlaying && self.player.timeControlStatus == .playing, let book = self.currentBook {
                    let now = Date()
                    if let prev = self.lastListeningTickAt {
                        let dt = now.timeIntervalSince(prev)
                        if dt > 0.05 && dt <= 2.5 {
                            self.onRecordListeningDelta?(book, dt)
                        }
                    }
                    self.lastListeningTickAt = now
                } else {
                    self.lastListeningTickAt = nil
                }
                self.persistCurrentProgress(isFinished: false, overrideFinished: false, force: false)
            }
        }

    }

    func rebuildPlayerAfterMediaServicesReset() {
        wasPlayingBeforeInterruption = false
        let shouldResume = state.shouldPlayWhenReady
        let hadActiveChapter = (currentChapter != nil && (activePlayerItem != nil || loadTask != nil))
        let capturedPosMs = clock.durationSeconds > 0 ? Int(clock.currentSeconds * 1000) : pendingResumePositionMs
        loadTask?.cancel()
        loadTask = nil
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        observerBag.tearDownAll()
        player.pause()
        activePlayerItem = nil
        player = AVPlayer()
        attachPeriodicTimeObserver()
        dsp.syncFadeVolume(to: player)
        if hadActiveChapter {
            loadCurrentChapter(autoPlay: shouldResume, resumePositionOverrideMs: capturedPosMs)
        } else {
            state = state.applyingPauseOrInterrupt()
            syncNowPlaying()
        }
    }

    func setupObservers() {
        attachPeriodicTimeObserver()
        remoteController.installHandlers(
            onPlay: { [weak self] in self?.resume() },
            onPause: { [weak self] in self?.pause() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onNextChapter: { [weak self] in self?.nextChapter(autoPlay: true) },
            onPreviousChapter: { [weak self] in self?.previousChapter(autoPlay: true) },
            onSeek: { [weak self] sec in self?.seek(to: sec) },
            onInterruptBegan: { [weak self] in self?.handleAudioInterruptionBegan() },
            onInterruptEndedShouldResume: { [weak self] in self?.handleAudioInterruptionEndedShouldResume() },
            onInterruptEndedWithoutResume: { [weak self] in self?.handleAudioInterruptionEndedWithoutResume() },
            onRouteUnplugged: { [weak self] in self?.handleAudioRouteUnplugged() },
            onMediaServicesReset: { [weak self] in self?.handleMediaServicesWereReset() }
        )
    }

    /// 按音质档位配置前向缓冲时长（SYS4-04：提升弱网地铁听书流畅度）
    public static func forwardBufferDuration(for tier: AudioQualityTier, isOnWiFi: Bool = true) -> TimeInterval {
        switch tier {
        case .saver: return 15
        case .standard: return 30
        case .auto: return isOnWiFi ? 60 : 20
        case .high: return 60
        }
    }

    /// 睡眠定时到点触发：先暂停，若开启「暂停后自动回退」则将进度微调回退，次日续听不漏剧情
    public func handleSleepTimerFired() {
        let rewindSec = Double(sleepTimer.autoRewindOnSleepSeconds)
        let targetSec = max(0, clock.currentSeconds - rewindSec)
        pause()
        if rewindSec > 0 && clock.currentSeconds > 1 {
            seek(to: targetSec)
        }
    }

    /// 退后台时立即落盘当前播放位置，防止系统杀进程丢失最后进度
    public func flushProgressForBackground() {
        guard currentBook != nil, currentChapter != nil else { return }
        persistCurrentProgress(isFinished: false, overrideFinished: false, force: true)
    }

    public func flushProgressForBackgroundAsync() async {
        switch state {
        case .idle, .failed: return
        case .buffering where clock.durationSeconds <= 0: return
        default: break
        }
        guard let book = currentBook, let chapter = currentChapter else { return }
        lastPersistedAt = Date()
        await progressStore.saveProgress(
            book: book,
            chapter: chapter,
            positionMs: Int(clock.currentSeconds * 1000),
            durationMs: Int(clock.durationSeconds * 1000),
            isFinished: false,
            overrideFinished: false
        )
    }
}
