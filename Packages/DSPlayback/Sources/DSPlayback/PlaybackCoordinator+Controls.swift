import AVFoundation
import DSCore
import Foundation

/// PlaybackCoordinator 章节切集、音质切换、睡眠定时与后台落盘控制（拆分保持单文件 ≤ 384 行）
extension PlaybackCoordinator {
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
