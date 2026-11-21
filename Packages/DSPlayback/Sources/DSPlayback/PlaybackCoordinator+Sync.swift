import AVFoundation
import DSCore
import Foundation

/// 播放进度持久化、观察者绑定与锁屏媒体信息同步扩展（SYS3-03：拆分自 PlaybackCoordinator 留足 400 行维护裕度）
extension PlaybackCoordinator {
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

    func syncNowPlaying() {
        guard let book = currentBook, let chapter = currentChapter else { return }
        remoteController.updateNowPlaying(
            bookTitle: book.title,
            chapterTitle: chapter.title,
            narrator: book.narrator,
            elapsed: clock.currentSeconds,
            duration: clock.durationSeconds,
            rate: playbackRate,
            isPlaying: state.isPlaying
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
        let statusObs = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let errText = observed.error?.localizedDescription ?? "音频加载失败"
            let observedDur = observed.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, gen == self.generationCounter else { return }
                switch status {
                case .readyToPlay:
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
                        self.player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
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

    func setupObservers() {
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
                self.persistCurrentProgress(isFinished: false, overrideFinished: false, force: false)
            }
        }

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
}
