import CoreMotion
import Foundation

/// 睡眠定时最后 2 分钟锁屏摇一摇延时传感器（按需 20Hz 启停，免 NSMotionUsageDescription 弹窗）
// SAFETY: 摇动检测状态机与 CMMotionManager 仅在单串行 OperationQueue / MainActor 边界内访问，触发回调经 MainActor 派发。
public final class SleepShakeMonitor: @unchecked Sendable {
    public struct DetectorState: Sendable {
        public var lastPeakAt: Date?
        public var lastTriggeredAt: Date?

        public init(lastPeakAt: Date? = nil, lastTriggeredAt: Date? = nil) {
            self.lastPeakAt = lastPeakAt
            self.lastTriggeredAt = lastTriggeredAt
        }
    }

    public static let defaultPeakThresholdG: Double = 1.8
    public static let defaultDualPeakWindowSeconds: TimeInterval = 0.65
    public static let defaultCooldownSeconds: TimeInterval = 4.0

    private let lock = NSLock()
    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dsnovel.sleep.shake"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    private var state = DetectorState()
    private var isMonitoring = false
    private var onShakeHandler: (@MainActor () -> Void)?

    public init() {}

    public var isRunning: Bool {
        lock.withLock { isMonitoring }
    }

    public func start(onShake: @escaping @MainActor () -> Void) {
        let shouldStart: Bool = lock.withLock {
            onShakeHandler = onShake
            guard !isMonitoring else { return false }
            isMonitoring = true
            state.lastPeakAt = nil
            return true
        }
        guard shouldStart, motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 1.0 / 20.0
        motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let accel = data?.acceleration else { return }
            let now = Date()
            let triggeredHandler: (@MainActor () -> Void)? = self.lock.withLock {
                guard self.isMonitoring else { return nil }
                let didTrigger = Self.evaluateSample(
                    x: accel.x,
                    y: accel.y,
                    z: accel.z,
                    now: now,
                    state: &self.state
                )
                return didTrigger ? self.onShakeHandler : nil
            }
            if let handler = triggeredHandler {
                Task { @MainActor in
                    handler()
                }
            }
        }
    }

    public func stop() {
        let shouldStop: Bool = lock.withLock {
            onShakeHandler = nil
            state.lastPeakAt = nil
            guard isMonitoring else { return false }
            isMonitoring = false
            return true
        }
        if shouldStop {
            motionManager.stopAccelerometerUpdates()
        }
    }

    /// 纯静态双峰摇动检测器（扣除 1G 重力后检测 > 1.8G 且 0.65s 内命中 2 次峰值，触发后 4s 防连触冷却）
    public static func evaluateSample(
        x: Double,
        y: Double,
        z: Double,
        now: Date,
        state: inout DetectorState,
        peakThresholdG: Double = defaultPeakThresholdG,
        dualPeakWindowSeconds: TimeInterval = defaultDualPeakWindowSeconds,
        cooldownSeconds: TimeInterval = defaultCooldownSeconds
    ) -> Bool {
        if let lastTrig = state.lastTriggeredAt, now.timeIntervalSince(lastTrig) < cooldownSeconds {
            return false
        }
        let magnitude = sqrt(x * x + y * y + z * z)
        let dynamicG = abs(magnitude - 1.0)
        guard dynamicG >= peakThresholdG else { return false }

        if let prev = state.lastPeakAt {
            let dt = now.timeIntervalSince(prev)
            if dt >= 0.08 && dt <= dualPeakWindowSeconds {
                state.lastPeakAt = nil
                state.lastTriggeredAt = now
                return true
            }
        }
        state.lastPeakAt = now
        return false
    }
}
