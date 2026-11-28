import DSCore
import Foundation
import UIKit

/// 暂停来源（用于智能暂停回退互斥，防止与睡眠定时回退叠加）
public enum PlaybackPauseReason: String, Sendable, Equatable {
    case manual
    case routeRemoval
    case interruption
    case sleepTimer
}

/// 智能暂停回退（Smart Rewind）、夜间自动定时与锁屏摇一摇延时扩展（拆分自 PlaybackCoordinator 保持 ≤ 384 行）
extension PlaybackCoordinator {
    /// 纯函数计算本次恢复播放应回退的目标秒数（nil 表示无需回退）
    public nonisolated static func computeSmartRewindTarget(
        enabled: Bool,
        pausedAt: Date?,
        pauseReason: PlaybackPauseReason,
        sleepAutoRewindSeconds: Int,
        thresholdMinutes: Int,
        rewindSeconds: Int,
        currentSeconds: Double,
        introFloorSeconds: Double,
        now: Date = Date()
    ) -> Double? {
        guard enabled, let pausedAt else { return nil }
        if pauseReason == .sleepTimer && sleepAutoRewindSeconds > 0 {
            return nil
        }
        let elapsed = now.timeIntervalSince(pausedAt)
        guard elapsed >= TimeInterval(max(1, thresholdMinutes) * 60) else { return nil }
        let floorSec = max(0, introFloorSeconds)
        guard currentSeconds > floorSec + 3.0 else { return nil }
        let target = max(floorSec, currentSeconds - Double(max(1, rewindSeconds)))
        guard currentSeconds - target >= 1.0 else { return nil }
        return target
    }

    func recordPauseForSmartRewind(reason: PlaybackPauseReason, now: Date = Date()) {
        lastPausedAt = now
        lastPauseReason = reason
    }

    func clearSmartRewindMarker() {
        lastPausedAt = nil
    }

    /// 恢复播放前尝试执行智能暂停回退；返回实际回退秒数（0 表示未触发）
    @discardableResult
    func applySmartRewindIfNeeded(now: Date = Date()) -> Int {
        let introFloor = effectiveIntroSeconds(forDuration: clock.durationSeconds)
        guard let target = Self.computeSmartRewindTarget(
            enabled: smartRewindEnabled,
            pausedAt: lastPausedAt,
            pauseReason: lastPauseReason,
            sleepAutoRewindSeconds: sleepTimer.autoRewindOnSleepSeconds,
            thresholdMinutes: smartRewindThresholdMinutes,
            rewindSeconds: smartRewindSeconds,
            currentSeconds: clock.currentSeconds,
            introFloorSeconds: introFloor,
            now: now
        ) else {
            lastPausedAt = nil
            return 0
        }
        let delta = max(1, Int((clock.currentSeconds - target).rounded()))
        lastPausedAt = nil
        seek(to: target)
        onSmartRewindApplied?(delta)
        return delta
    }

    /// 深夜时段起播时自动开启睡眠定时（仅当定时关闭且本轮未被手动关闭）
    @discardableResult
    public func armNightAutoSleepIfNeeded(now: Date = Date()) -> Bool {
        guard sleepTimer.shouldArmNightAutoSleep(now: now) else { return false }
        let mins = sleepTimer.nightAutoDurationMinutes
        sleepTimer.startCountdown(
            minutes: mins,
            now: now,
            onFadeFactor: { [weak self] factor in self?.applySleepFade(factor: factor) },
            onFire: { [weak self] in self?.handleSleepTimerFired() }
        )
        onNightAutoSleepArmed?(mins)
        return true
    }

    /// 同步锁屏摇一摇监测窗口（仅在最后 120 秒激活，其余时段零传感零耗电）
    func syncSleepShakeMonitoring(isInWindow: Bool) {
        if isInWindow && sleepTimer.shakeToExtendEnabled {
            sleepShakeMonitor.start { [weak self] in
                self?.handleSleepShakeExtend()
            }
        } else {
            sleepShakeMonitor.stop()
        }
    }

    public func handleSleepShakeExtend() {
        guard sleepTimer.shakeToExtendEnabled else { return }
        guard case .countdown = sleepTimer.mode else { return }
        sleepTimer.extendMinutes(
            by: 15,
            onFadeFactor: { [weak self] factor in self?.applySleepFade(factor: factor) },
            onFire: { [weak self] in self?.handleSleepTimerFired() }
        )
        applySleepFade(factor: 1.0)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            let second = UIImpactFeedbackGenerator(style: .medium)
            second.impactOccurred()
        }
        onSleepShakeExtended?(15)
    }
}
