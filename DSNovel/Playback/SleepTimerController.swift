import Foundation
import Observation

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
        case .chaptersRemaining(let c): return "\(c) 章后"
        }
    }
}

/// 睡眠定时控制器（NEW-08 拆分）：
/// - 管理定时模式（关闭 / 按分钟 / 本章结束 / N 章后）与剩余状态
/// - 提供按当前倍速动态折算剩余秒数与最后 30 秒线性音量渐弱因子计算
/// - 调度按分钟倒计时任务并在到期或章尾条件满足时通知 PlayerEngine
@MainActor
@Observable
final class SleepTimerController {
    var option: SleepTimerOption = .off
    private(set) var remainingSec: Int = 0
    private(set) var chaptersLeft: Int = 0
    @ObservationIgnored var fadeMultiplier: Float = 1.0
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    init() {}

    deinit {
        timerTask?.cancel()
    }

    func resetFadeMultiplier() {
        fadeMultiplier = 1.0
    }

    /// 动态预估睡眠定时剩余秒数（修复 ISS-12：在选择「本章结束」或「N 章后」时按当前倍速动态折算）
    nonisolated static func estimateSleepSeconds(
        option: SleepTimerOption,
        countdownSec: Int,
        currentTimeSec: Double,
        durationSec: Double,
        chapterQueue: [ChapterDTO] = [],
        currentChapterID: String? = nil,
        chaptersLeft: Int = 1,
        speed: Double
    ) -> Int {
        let safeSpeed = max(0.5, speed)
        switch option {
        case .off:
            return 0
        case .minutes(let mins):
            return countdownSec > 0 ? countdownSec : mins * 60
        case .endOfChapter:
            let effDur = durationSec > 0 ? durationSec : 600.0
            let remRaw = max(0.0, effDur - max(0.0, currentTimeSec))
            return Int((remRaw / safeSpeed).rounded())
        case .chaptersRemaining(let configuredCount):
            let effDur = durationSec > 0 ? durationSec : 600.0
            var totalRawSec = max(0.0, effDur - max(0.0, currentTimeSec))
            let extraChapters = max(0, (chaptersLeft > 0 ? chaptersLeft : configuredCount) - 1)
            if extraChapters > 0 {
                if let currentChapterID,
                   let curIdx = chapterQueue.firstIndex(where: { $0.id == currentChapterID }) {
                    let endIdx = min(chapterQueue.count, curIdx + 1 + extraChapters)
                    if curIdx + 1 < endIdx {
                        for i in (curIdx + 1)..<endIdx {
                            let hint = chapterQueue[i].hintDurationSec
                            totalRawSec += (hint > 0 ? hint : 600.0)
                        }
                    } else {
                        totalRawSec += Double(extraChapters) * (effDur > 0 ? effDur : 600.0)
                    }
                } else {
                    totalRawSec += Double(extraChapters) * (effDur > 0 ? effDur : 600.0)
                }
            }
            return Int((totalRawSec / safeSpeed).rounded())
        }
    }

    /// 计算最后 30 秒线性渐弱音量（供单元测试与定时器共用）
    nonisolated static func computeFadeVolume(
        baseVolume: Double,
        remainingSeconds: Int,
        fadeEnabled: Bool
    ) -> Float {
        guard fadeEnabled, remainingSeconds > 0, remainingSeconds <= 30 else {
            return Float(min(max(baseVolume, 0), 1.0))
        }
        let ratio = Double(remainingSeconds) / 30.0
        return Float(min(max(baseVolume * ratio, 0), 1.0))
    }

    func setOption(
        _ newOption: SleepTimerOption,
        isPlaying: @escaping @MainActor () -> Bool,
        onFadeUpdated: @escaping @MainActor () -> Void,
        onExpired: @escaping @MainActor () -> Void
    ) {
        timerTask?.cancel()
        option = newOption
        fadeMultiplier = 1.0
        onFadeUpdated()

        switch newOption {
        case .off:
            remainingSec = 0
            chaptersLeft = 0
        case .minutes(let mins):
            remainingSec = mins * 60
            startCountdownTask(isPlaying: isPlaying, onFadeUpdated: onFadeUpdated, onExpired: onExpired)
        case .endOfChapter:
            remainingSec = 0
            chaptersLeft = 1
        case .chaptersRemaining(let count):
            remainingSec = 0
            chaptersLeft = max(1, count)
        }
    }

    func extend(
        byMinutes extraMinutes: Int,
        estimatedRemainingSec: Int,
        isPlaying: @escaping @MainActor () -> Bool,
        onFadeUpdated: @escaping @MainActor () -> Void,
        onExpired: @escaping @MainActor () -> Void
    ) {
        let addSec = max(1, extraMinutes) * 60
        fadeMultiplier = 1.0
        onFadeUpdated()

        switch option {
        case .off:
            setOption(.minutes(extraMinutes), isPlaying: isPlaying, onFadeUpdated: onFadeUpdated, onExpired: onExpired)
        case .minutes:
            remainingSec += addSec
        case .endOfChapter, .chaptersRemaining:
            timerTask?.cancel()
            chaptersLeft = 0
            remainingSec = estimatedRemainingSec + addSec
            let totalMins = max(1, Int((Double(remainingSec) / 60.0).rounded()))
            option = .minutes(totalMins)
            startCountdownTask(isPlaying: isPlaying, onFadeUpdated: onFadeUpdated, onExpired: onExpired)
        }
    }

    /// 按章定时最后 30 秒线性音量渐弱（返回是否需要刷新音频管线）
    func updateChapterFadeIfNeeded(
        currentSec: Double,
        durationSec: Double,
        speed: Double,
        isPlaying: Bool,
        effectiveEndSec: Double,
        fadeEnabled: Bool
    ) -> Bool {
        let isLastSleepChapter: Bool = {
            switch option {
            case .endOfChapter:
                return true
            case .chaptersRemaining:
                return chaptersLeft <= 1
            default:
                return false
            }
        }()
        guard isLastSleepChapter, isPlaying else { return false }

        guard fadeEnabled, durationSec.isFinite, durationSec > 0 else {
            if abs(fadeMultiplier - 1.0) > 0.001 {
                fadeMultiplier = 1.0
                return true
            }
            return false
        }

        let remWallSec = max(0.0, (effectiveEndSec - currentSec) / max(0.5, speed))
        if remWallSec > 0 && remWallSec <= 30.0 {
            let newMultiplier = Float(min(max(remWallSec / 30.0, 0.0), 1.0))
            if abs(newMultiplier - fadeMultiplier) > 0.01 {
                fadeMultiplier = newMultiplier
                return true
            }
        } else if abs(fadeMultiplier - 1.0) > 0.001 {
            fadeMultiplier = 1.0
            return true
        }
        return false
    }

    /// 章节播完时消耗按章定时计数；若应立即暂停并结束定时则返回 true
    func consumeChapterFinished() -> Bool {
        fadeMultiplier = 1.0
        if option == .endOfChapter {
            option = .off
            return true
        }
        if case .chaptersRemaining = option {
            chaptersLeft -= 1
            if chaptersLeft <= 0 {
                option = .off
                return true
            }
        }
        return false
    }

    private func startCountdownTask(
        isPlaying: @escaping @MainActor () -> Bool,
        onFadeUpdated: @escaping @MainActor () -> Void,
        onExpired: @escaping @MainActor () -> Void
    ) {
        timerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled && self.remainingSec > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                if isPlaying() {
                    self.remainingSec -= 1
                    let fadeOn = AppSettingsStore.shared.sleepFadeOutEnabled
                    if fadeOn && self.remainingSec > 0 && self.remainingSec <= 30 {
                        self.fadeMultiplier = Float(Double(self.remainingSec) / 30.0)
                    } else {
                        self.fadeMultiplier = 1.0
                    }
                    onFadeUpdated()
                    if self.remainingSec <= 0 {
                        self.fadeMultiplier = 1.0
                        self.option = .off
                        onExpired()
                        break
                    }
                }
            }
        }
    }
}

// MARK: - PlayerEngine 睡眠定时兼容接口

extension PlayerEngine {
    var sleepOption: SleepTimerOption {
        get { sleepTimer.option }
        set { sleepTimer.option = newValue }
    }

    var sleepRemainingSec: Int {
        sleepTimer.remainingSec
    }

    /// 动态预估睡眠定时剩余秒数（修复 ISS-12：在选择「本章结束」或「N 章后」时按当前倍速动态折算）
    var estimatedSleepRemainingSec: Int {
        Self.estimateSleepSeconds(
            option: sleepTimer.option,
            countdownSec: sleepTimer.remainingSec,
            currentTimeSec: clock.currentTimeSec,
            durationSec: clock.durationSec,
            chapterQueue: chapterQueue,
            currentChapterID: currentChapter?.id,
            chaptersLeft: sleepTimer.chaptersLeft,
            speed: speed
        )
    }

    nonisolated static func estimateSleepSeconds(
        option: SleepTimerOption,
        countdownSec: Int,
        currentTimeSec: Double,
        durationSec: Double,
        chapterQueue: [ChapterDTO] = [],
        currentChapterID: String? = nil,
        chaptersLeft: Int = 1,
        speed: Double
    ) -> Int {
        SleepTimerController.estimateSleepSeconds(
            option: option,
            countdownSec: countdownSec,
            currentTimeSec: currentTimeSec,
            durationSec: durationSec,
            chapterQueue: chapterQueue,
            currentChapterID: currentChapterID,
            chaptersLeft: chaptersLeft,
            speed: speed
        )
    }

    /// 计算最后 30 秒线性渐弱音量（供单元测试与定时器共用）
    nonisolated static func computeFadeVolume(
        baseVolume: Double,
        remainingSeconds: Int,
        fadeEnabled: Bool
    ) -> Float {
        SleepTimerController.computeFadeVolume(
            baseVolume: baseVolume,
            remainingSeconds: remainingSeconds,
            fadeEnabled: fadeEnabled
        )
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimer.setOption(
            option,
            isPlaying: { [weak self] in self?.state == .playing },
            onFadeUpdated: { [weak self] in self?.applyEffectiveAudioSettings() },
            onExpired: { [weak self] in
                guard let self else { return }
                self.pause()
                self.applyEffectiveAudioSettings()
            }
        )
    }

    /// 快捷延长睡眠定时（修复 ISS-12：一键 +15 分钟续时）
    func extendSleepTimer(byMinutes extraMinutes: Int = 15) {
        let baseSec = estimatedSleepRemainingSec
        sleepTimer.extend(
            byMinutes: extraMinutes,
            estimatedRemainingSec: baseSec,
            isPlaying: { [weak self] in self?.state == .playing },
            onFadeUpdated: { [weak self] in self?.applyEffectiveAudioSettings() },
            onExpired: { [weak self] in
                guard let self else { return }
                self.pause()
                self.applyEffectiveAudioSettings()
            }
        )
    }

    func updateChapterSleepFadeIfNeeded(currentSec: Double, durationSec: Double) {
        let effectiveEnd = skipCoordinator.outroBoundarySec(durationSec: durationSec) ?? durationSec
        let changed = sleepTimer.updateChapterFadeIfNeeded(
            currentSec: currentSec,
            durationSec: durationSec,
            speed: speed,
            isPlaying: state == .playing,
            effectiveEndSec: effectiveEnd,
            fadeEnabled: AppSettingsStore.shared.sleepFadeOutEnabled
        )
        if changed {
            applyEffectiveAudioSettings()
        }
    }

    func handleSleepTimerChapterFinished() -> Bool {
        if sleepTimer.consumeChapterFinished() {
            pause()
            applyEffectiveAudioSettings()
            return true
        }
        return false
    }
}
