import Foundation
import Observation

/// 独立高频播放时钟（L-IOS-6：与 PlaybackCoordinator 解耦，避免 1Hz 进度更新触发顶层整屏重绘）
@Observable
@MainActor
public final class PlaybackClock {
    public private(set) var currentSeconds: Double = 0
    public private(set) var durationSeconds: Double = 0
    public private(set) var bufferedSeconds: Double = 0

    public var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, currentSeconds / durationSeconds))
    }

    public init() {}

    public func update(current: Double, duration: Double, buffered: Double? = nil) {
        let safeCurrent = current.isFinite ? max(0, current) : 0
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        self.currentSeconds = safeCurrent
        if safeDuration > 0 {
            self.durationSeconds = safeDuration
        }
        if let buf = buffered, buf.isFinite {
            self.bufferedSeconds = max(0, buf)
        }
    }

    public func reset() {
        currentSeconds = 0
        durationSeconds = 0
        bufferedSeconds = 0
    }
}
