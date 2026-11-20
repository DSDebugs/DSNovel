import Foundation
import Observation
import AVFoundation
import SwiftData

/// 按书跳过片头片尾协调器（NEW-08 拆分）：
/// - 管理单书跳过配置与当前章节片尾触发/抑制状态
/// - 提供新章起播位置计算、真实时长短章保护二次校验与 Seek 抑制/复位逻辑
/// - 计算片尾边界观察时间点与触发条件
@MainActor
@Observable
final class SkipIntroOutroCoordinator {
    var config: BookSkipConfig = .unset
    @ObservationIgnored var outroTriggeredForCurrentChapter: Bool = false
    @ObservationIgnored var outroSuppressedForCurrentChapter: Bool = false

    init() {}

    func resetChapterState() {
        outroTriggeredForCurrentChapter = false
        outroSuppressedForCurrentChapter = false
    }

    func resolveStartPosition(initialPositionMs: Int, hintDurationSec: Double) -> (startSec: Double, isIntroSkip: Bool) {
        let startSec = BookSkipConfig.startPositionSec(
            initialPositionMs: initialPositionMs,
            duration: hintDurationSec,
            config: config
        )
        let isIntroSkip = (initialPositionMs <= 0 && startSec > 0)
        return (startSec, isIntroSkip)
    }

    /// 二次短章校验：拿到真实时长后，若片头跳过超过 (duration - 5s) 则取消跳过从 0 起播
    func shouldCancelPendingIntroSkip(pendingIntroSeekSec: Double, actualDurationSec: Double) -> Bool {
        actualDurationSec.isFinite && actualDurationSec > 0 && pendingIntroSeekSec >= actualDurationSec - 5.0
    }

    /// 更新当前书跳过配置，并在当前位置已落入新设片尾区间时抑制自动跳过（B7④）
    func applyConfigUpdate(
        _ newConfig: BookSkipConfig,
        currentTimeSec: Double,
        durationSec: Double
    ) -> (previous: BookSkipConfig, normalized: BookSkipConfig) {
        let normalized = newConfig.normalized
        let previous = config
        config = normalized

        let outro = Double(normalized.effectiveOutroSec)
        if outro > 0, durationSec.isFinite, durationSec > 0, currentTimeSec >= durationSec - outro {
            outroSuppressedForCurrentChapter = true
        } else if BookSkipConfig.shouldResetOutroSuppression(seekSec: currentTimeSec, durationSec: durationSec, config: normalized) {
            outroSuppressedForCurrentChapter = false
        }
        return (previous, normalized)
    }

    func restoreConfig(_ previous: BookSkipConfig) {
        config = previous
    }

    /// 拖动进度条时同步片尾抑制/复位状态
    func handleSeek(to clampedSec: Double, durationSec: Double) {
        let outro = Double(config.effectiveOutroSec)
        guard outro > 0, durationSec.isFinite, durationSec > 0 else { return }
        if clampedSec >= durationSec - outro {
            outroSuppressedForCurrentChapter = true
        } else if BookSkipConfig.shouldResetOutroSuppression(seekSec: clampedSec, durationSec: durationSec, config: config) {
            outroSuppressedForCurrentChapter = false
            outroTriggeredForCurrentChapter = false
        }
    }

    func outroBoundarySec(durationSec: Double) -> Double? {
        BookSkipConfig.outroBoundarySec(durationSec: durationSec, config: config)
    }

    func shouldTriggerOutroSkip(positionSec: Double, durationSec: Double) -> Bool {
        BookSkipConfig.shouldTriggerOutroSkip(
            positionSec: positionSec,
            durationSec: durationSec,
            config: config,
            hasTriggered: outroTriggeredForCurrentChapter,
            isSuppressed: outroSuppressedForCurrentChapter
        )
    }

    func markOutroTriggered() {
        outroTriggeredForCurrentChapter = true
    }
}

// MARK: - PlayerEngine 按书跳过片头片尾兼容接口

extension PlayerEngine {
    var bookSkip: BookSkipConfig {
        skipCoordinator.config
    }

    var skipIntroSec: Int {
        skipCoordinator.config.effectiveIntroSec
    }

    var skipOutroSec: Int {
        skipCoordinator.config.effectiveOutroSec
    }

    func undoIntroSkipForCurrentChapter() {
        clearInlineFeedback()
        seek(to: 0)
    }

    @discardableResult
    func updateBookSkip(_ newConfig: BookSkipConfig) -> Bool {
        let dur = clock.durationSec
        let pos = clock.currentTimeSec
        let (previous, normalized) = skipCoordinator.applyConfigUpdate(
            newConfig,
            currentTimeSec: pos,
            durationSec: dur
        )

        if isCurrentItemReady && dur.isFinite && dur > 0 {
            configureOutroBoundaryObserver(durationSec: dur)
        }

        guard let ctx = modelContext, let book = currentBook else {
            return true
        }
        do {
            let saved = ensureBookRow(for: book, in: ctx)
            saved.skipEnabled = normalized.enabled
            saved.skipIntroSec = normalized.introSec
            saved.skipOutroSec = normalized.outroSec
            try ctx.save()
            return true
        } catch {
            skipCoordinator.restoreConfig(previous)
            showInlineToast("保存失败", durationSec: 3.0)
            return false
        }
    }

    func removeOutroBoundaryObserver() {
        if let token = outroBoundaryObserverToken {
            player.removeTimeObserver(token)
            outroBoundaryObserverToken = nil
        }
    }

    func configureOutroBoundaryObserver(durationSec: Double) {
        removeOutroBoundaryObserver()
        guard let boundarySec = skipCoordinator.outroBoundarySec(durationSec: durationSec) else {
            return
        }
        let gen = playbackGeneration
        let boundaryTime = CMTime(seconds: boundarySec, preferredTimescale: 600)
        outroBoundaryObserverToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundaryTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      gen == self.playbackGeneration,
                      self.isCurrentItemReady,
                      !self.isSeeking else { return }
                let dur = self.clock.durationSec
                let pos = max(self.clock.currentTimeSec, boundarySec)
                if self.skipCoordinator.shouldTriggerOutroSkip(positionSec: pos, durationSec: dur) {
                    self.triggerOutroSkip()
                }
            }
        }
    }

    func triggerOutroSkip() {
        skipCoordinator.markOutroTriggered()
        if nextChapterAvailability == .none {
            showInlineToast("已是最后一章", durationSec: 3.0)
        } else {
            showInlineToast("已跳过片尾，正在播放下一章", durationSec: 3.0)
        }
        handleChapterFinished()
    }
}
