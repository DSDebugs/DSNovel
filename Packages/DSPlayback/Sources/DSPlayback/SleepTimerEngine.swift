import Foundation
import Observation

/// 睡眠定时模式（L-IOS-3：按墙钟 deadline: Date 计算，零后台漂移；支持按章播完暂停并预定位下章片头）
public enum SleepTimerMode: Sendable, Equatable {
    case off
    case countdown(deadline: Date)
    case afterChapters(remaining: Int)
}

@Observable
@MainActor
public final class SleepTimerEngine {
    public private(set) var mode: SleepTimerMode = .off
    public private(set) var remainingSeconds: Int = 0
    public var fadeOutLastSeconds: Int = 15
    public var tickIntervalNanoseconds: UInt64
    public var postFireFadeRestoreDelayNanoseconds: UInt64 = 150_000_000

    private var tickTask: Task<Void, Never>?
    private var postFireRestoreTask: Task<Void, Never>?
    private var activeFadeHandler: (@MainActor (Float) -> Void)?
    private var pendingRestoreFadeHandler: (@MainActor (Float) -> Void)?

    public init(tickIntervalNanoseconds: UInt64 = 1_000_000_000) {
        self.tickIntervalNanoseconds = tickIntervalNanoseconds
    }

    public var isActive: Bool { mode != .off }

    public var displayBadge: String? {
        switch mode {
        case .off:
            return nil
        case .countdown:
            let m = remainingSeconds / 60
            let s = remainingSeconds % 60
            return String(format: "%02d:%02d", m, s)
        case .afterChapters(let count):
            return "播完\(count)章"
        }
    }

    /// 启动墙钟倒计时（基于绝对 deadline: Date，即使锁屏挂起后唤醒也零漂移）
    public func startCountdown(
        minutes: Int,
        now: Date = Date(),
        onFadeFactor: @escaping @MainActor (Float) -> Void,
        onFire: @escaping @MainActor () -> Void
    ) {
        cancel()
        let seconds = max(60, minutes * 60)
        let deadline = now.addingTimeInterval(TimeInterval(seconds))
        mode = .countdown(deadline: deadline)
        remainingSeconds = seconds
        activeFadeHandler = onFadeFactor

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = Int(ceil(deadline.timeIntervalSinceNow))
                if left <= 0 {
                    self.remainingSeconds = 0
                    self.mode = .off
                    self.activeFadeHandler = nil
                    self.pendingRestoreFadeHandler = onFadeFactor
                    onFire()
                    let restoreDelay = self.postFireFadeRestoreDelayNanoseconds
                    self.postFireRestoreTask?.cancel()
                    self.postFireRestoreTask = Task { @MainActor [weak self] in
                        if restoreDelay > 0 {
                            try? await Task.sleep(nanoseconds: restoreDelay)
                        }
                        guard !Task.isCancelled else { return }
                        onFadeFactor(1.0)
                        self?.pendingRestoreFadeHandler = nil
                        self?.postFireRestoreTask = nil
                    }
                    return
                }
                self.remainingSeconds = left
                if left <= self.fadeOutLastSeconds, self.fadeOutLastSeconds > 0 {
                    let factor = Float(left) / Float(self.fadeOutLastSeconds)
                    onFadeFactor(max(0.05, factor))
                }
                let intervalNs = self.tickIntervalNanoseconds
                if intervalNs > 0 {
                    try? await Task.sleep(nanoseconds: intervalNs)
                } else {
                    await Task.yield()
                }
            }
        }
    }

    /// 启动按章定时（单位严格使用「章」，符合规则 #10）
    public func startAfterChapters(_ count: Int) {
        cancel()
        let clamped = max(1, min(10, count))
        mode = .afterChapters(remaining: clamped)
        remainingSeconds = 0
    }

    /// 章节自然播完时扣减计数；返回 true 表示定时触发（调用方应暂停并预定位至下一章片头）
    public func consumeChapterFinished() -> Bool {
        guard case .afterChapters(let left) = mode else { return false }
        let next = left - 1
        if next <= 0 {
            mode = .off
            return true
        }
        mode = .afterChapters(remaining: next)
        return false
    }

    public func cancel() {
        tickTask?.cancel()
        tickTask = nil
        postFireRestoreTask?.cancel()
        postFireRestoreTask = nil
        let resetFade = activeFadeHandler ?? pendingRestoreFadeHandler
        activeFadeHandler = nil
        pendingRestoreFadeHandler = nil
        mode = .off
        remainingSeconds = 0
        resetFade?(1.0)
    }

    /// 供单元测试直接校验墙钟剩余秒数
    public static func computeRemainingSeconds(deadline: Date, now: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
}
