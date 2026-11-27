import CoreMedia
import Foundation

/// 锁屏 / 后台播放省电状态（非观测纯值类型，零 SwiftUI 刷新开销）
struct PlaybackPowerModeState {
    var isBackgroundPowerSaving: Bool = false
    var observerIntervalSeconds: Double = 0.5
}

extension PlaybackCoordinator {
    static let foregroundObserverInterval: Double = 0.5
    static let backgroundObserverInterval: Double = 2.0
    static let foregroundPersistInterval: TimeInterval = 4.0
    static let backgroundPersistInterval: TimeInterval = 20.0

    var progressPersistIntervalSeconds: TimeInterval {
        powerModeState.isBackgroundPowerSaving ? Self.backgroundPersistInterval : Self.foregroundPersistInterval
    }

    /// 前后台 / 锁屏切换省电模式：后台将主线程时间观察器降至 2s、进度落盘放宽至 20s；回前台瞬间恢复 0.5s 并立即同步时钟
    public func setBackgroundPowerSaving(_ enabled: Bool) {
        guard powerModeState.isBackgroundPowerSaving != enabled else { return }
        powerModeState.isBackgroundPowerSaving = enabled

        let current = player.currentTime().seconds
        let dur = player.currentItem?.duration.seconds ?? clock.durationSeconds
        let validCurrent = current.isFinite && current >= 0 ? current : clock.currentSeconds
        let validDuration = dur.isFinite && dur > 0 ? dur : clock.durationSeconds

        let targetInterval = preferredTimeObserverInterval(current: validCurrent, duration: validDuration)
        if abs(powerModeState.observerIntervalSeconds - targetInterval) > 0.05 {
            attachPeriodicTimeObserver(intervalSeconds: targetInterval)
        }

        if !enabled, activePlayerItem != nil, player.currentItem === activePlayerItem, !isSeeking {
            clock.update(
                current: validCurrent,
                duration: validDuration,
                buffered: bufferedDuration(for: player.currentItem)
            )
        }
    }

    func preferredTimeObserverInterval(current: Double? = nil, duration: Double? = nil) -> Double {
        guard powerModeState.isBackgroundPowerSaving else {
            return Self.foregroundObserverInterval
        }
        let outro = Double(bookSkipConfig.outroSeconds)
        if outro > 0 {
            let cur = current ?? clock.currentSeconds
            let dur = duration ?? clock.durationSeconds
            if dur > 0, (dur - cur) <= (outro + 15.0) {
                return Self.foregroundObserverInterval
            }
        }
        return Self.backgroundObserverInterval
    }

    func reconcileBackgroundObserverCadenceIfNeeded(current: Double, duration: Double) {
        guard powerModeState.isBackgroundPowerSaving else { return }
        let targetInterval = preferredTimeObserverInterval(current: current, duration: duration)
        if abs(powerModeState.observerIntervalSeconds - targetInterval) > 0.05 {
            attachPeriodicTimeObserver(intervalSeconds: targetInterval)
        }
    }
}
