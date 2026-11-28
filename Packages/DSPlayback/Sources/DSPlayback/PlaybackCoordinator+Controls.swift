import AVFoundation
import DSCore
import Foundation

/// PlaybackCoordinator 章节切集、音质切换、睡眠定时与后台落盘控制（拆分保持单文件 ≤ 384 行）
extension PlaybackCoordinator {
    public func skipBy(_ deltaSeconds: Double) {
        seek(to: clock.currentSeconds + deltaSeconds)
    }

    public func nextChapter(autoPlay: Bool = true, persistCurrent: Bool = true) {
        clearRouteAutoResumeState()
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
        clearRouteAutoResumeState()
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

    /// 实时复核当前播放章节的本地文件状态（防止播放中途删除已下载音频后状态陈旧拦住切音质）
    public func refreshActiveLocalSourceKind() async {
        guard let book = currentBook, let chapter = currentChapter else {
            activeLocalSourceKind = .online
            return
        }
        guard let asset = await offlineLocator?.localAudioAsset(bookID: book.id, chapterID: chapter.id) else {
            if activeLocalSourceKind != .online {
                activeLocalSourceKind = .online
            }
            return
        }
        activeLocalSourceKind = asset.isPrecache ? .precache : .downloaded
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
        if let bookID = currentBook?.id, let locator = offlineLocator {
            Task { await locator.invalidatePrecache(bookID: bookID, chapterID: nil) }
        }
        loadCurrentChapter(autoPlay: state.shouldPlayWhenReady, resumePositionOverrideMs: resumeMs, bypassPrecache: true)
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
        clearRouteAutoResumeState()
        if let book = currentBook, let chapter = currentChapter {
            onAutoBookmarkBeforeSleep?(book, chapter, Int(clock.currentSeconds * 1000))
        }
        let rewindSec = Double(sleepTimer.autoRewindOnSleepSeconds)
        let targetSec = max(0, clock.currentSeconds - rewindSec)
        pause()
        recordPauseForSmartRewind(reason: .sleepTimer)
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

    func clearRouteAutoResumeState() {
        routeReconnectTask?.cancel()
        routeReconnectTask = nil
        pausedByRouteRemovalAt = nil
    }

    /// 远程线控/耳机 AVRCP 切换：刚由蓝牙重连自动续播后的 1.5s 内忽略重复 toggle，防止反手按停
    public func handleRemoteTogglePlayPause(now: Date = Date()) {
        if state.shouldPlayWhenReady,
           let lastAuto = lastAutoResumeFromRouteAt,
           now.timeIntervalSince(lastAuto) < Self.routeAutoResumeToggleDebounceSeconds {
            return
        }
        togglePlayPause()
    }

    /// 蓝牙/有线耳机重新佩戴连回：250ms 稳定防抖 + 4 重防误触守卫后自动激活会话并续播
    public func handleAudioRouteReconnected(
        isOtherAudioPlaying: Bool? = nil,
        routeHasPersonalAudio: Bool? = nil,
        debounceNanoseconds: UInt64 = 250_000_000,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        guard pausedByRouteRemovalAt != nil else { return }
        routeReconnectTask?.cancel()
        routeReconnectTask = Task { @MainActor [weak self] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            guard let removedAt = self.pausedByRouteRemovalAt else { return }
            let now = nowProvider()
            guard now.timeIntervalSince(removedAt) <= Self.routeAutoResumeWindowSeconds else {
                self.pausedByRouteRemovalAt = nil
                return
            }
            guard !self.state.shouldPlayWhenReady, self.currentChapter != nil else {
                self.pausedByRouteRemovalAt = nil
                return
            }
            let otherAudio = isOtherAudioPlaying ?? AVAudioSession.sharedInstance().isOtherAudioPlaying
            guard !otherAudio else { return }
            let hasPersonalAudio = routeHasPersonalAudio ?? RemoteCommandController.currentRouteHasPersonalAudioOutput()
            guard hasPersonalAudio else { return }

            self.pausedByRouteRemovalAt = nil
            _ = await self.remoteController.ensureAudioSessionActiveWithRetry()
            guard !Task.isCancelled else { return }
            self.lastAutoResumeFromRouteAt = now
            self.resume()
        }
    }
}
