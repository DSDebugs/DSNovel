import Foundation
import AVFoundation
import MediaPlayer
import UIKit

// MARK: - 锁屏、控制中心与系统音频通知协调（NEW-08 拆分）

extension PlayerEngine {
    func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumeOrReloadCurrentChapter() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
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
        // 禁用快进/快退 15s/30s 命令，确保灵动岛、锁屏界面与控制中心优先展示「上一章 / 下一章」切换按钮
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let targetTime = posEvent.positionTime
            Task { @MainActor in self?.seek(to: targetTime) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let targetRate = Double(rateEvent.playbackRate)
            Task { @MainActor in self?.setSpeed(targetRate, persist: true) }
            return .success
        }
    }

    func updateRemoteCommandStates() {
        let center = MPRemoteCommandCenter.shared()
        center.previousTrackCommand.isEnabled = canPlayPreviousChapter
        center.nextTrackCommand.isEnabled = (nextChapterAvailability != .none)
    }

    func updateNowPlayingInfo() {
        NowPlayingController.shared.update(
            book: currentBook,
            chapter: currentChapter,
            chapterIndexOneBased: currentChapterOneBasedIndex,
            totalChapters: chapterQueue.count,
            elapsedSec: clock.currentTimeSec,
            durationSec: clock.durationSec,
            isPlaying: state == .playing,
            speed: speed
        )
    }

    /// 音频会话中断处理（S3 加固）：
    /// - `.began` 同时兼容 `.playing` 与 `.buffering`；
    /// - `.ended` 始终复位 `wasPlayingBeforeInterruption`，避免标志残留，并通过 `resumeOrReloadCurrentChapter()` 恢复播放。
    func handleAudioInterruption(
        type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions
    ) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = (state == .playing || state == .buffering || shouldPlayWhenReady)
            shouldPlayWhenReady = false
            pause()
        case .ended:
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            if shouldResume {
                resumeOrReloadCurrentChapter()
            }
        @unknown default:
            break
        }
    }

    func observeNotifications() {
        let endToken = NotificationCenter.default.addObserver(
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
        notificationTokens.append(endToken)

        let failedEndToken = NotificationCenter.default.addObserver(
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
                await self.handleItemFailedToPlayToEnd(errorMessage: err)
            }
        }
        notificationTokens.append(failedEndToken)

        // S3：监听 AVPlayerItemPlaybackStalled，触发 14s 缓冲卡死 Watchdog
        let stalledToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let stalledID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            Task { @MainActor [weak self] in
                guard let self,
                      let currentItem = self.player.currentItem,
                      stalledID == ObjectIdentifier(currentItem) else { return }
                self.handlePlaybackStalled()
            }
        }
        notificationTokens.append(stalledToken)

        // S3：处理音频中断开始与结束（支持 .playing/.buffering 中断与结束后复位标志 + 续播/重载）
        let interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            let optionsVal = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsVal)
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(type: type, options: options)
            }
        }
        notificationTokens.append(interruptionToken)

        // 修复 ISS-10：监听耳机/蓝牙外设断开（oldDeviceUnavailable），自动暂停并落盘进度防止外放惊扰
        let routeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
                  reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .playing || self.state == .buffering || self.shouldPlayWhenReady else { return }
                self.shouldPlayWhenReady = false
                self.pause()
            }
        }
        notificationTokens.append(routeToken)

        // 监听系统媒体服务重置，自动重建会话并恢复音画管线
        let mediaResetToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesWereReset()
            }
        }
        notificationTokens.append(mediaResetToken)

        let bgToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistProgressNow()
            }
        }
        notificationTokens.append(bgToken)
    }
}
