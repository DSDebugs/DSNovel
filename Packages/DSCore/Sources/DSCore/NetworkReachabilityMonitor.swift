import Foundation
import Network
import Observation

/// 线程安全单调序号生成器（避免主线程状态被旧路径回调乱序覆盖）
private final class PathSequenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            current &+= 1
            return current
        }
    }
}

/// Sendable 包装器用于跨线程比对当前激活的 NWPathMonitor 实例身份
private final class MonitorRef: @unchecked Sendable {
    let monitor: NWPathMonitor
    init(_ monitor: NWPathMonitor) {
        self.monitor = monitor
    }
}

/// 网络可达性与 Wi-Fi/蜂窝接口切换监听器（UI-02 / ARC-08：驱动 wifiOnlyDownload 与切换网络作废旧 resumeData）
@Observable
@MainActor
public final class NetworkReachabilityMonitor {
    public private(set) var isConnected: Bool = true
    public private(set) var isOnWiFi: Bool = true
    public private(set) var isExpensive: Bool = false
    public private(set) var hasReceivedInitialPath: Bool

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.dsnovel.app.network.monitor", qos: .utility)
    private let sequenceBox = PathSequenceBox()
    private var appliedSequence: UInt64 = 0
    private var onNetworkTypeChanged: (@MainActor (Bool) -> Void)?
    private var onInitialNetworkStateSynced: (@MainActor (Bool) -> Void)?
    private var hasTriggeredInitialSync: Bool = false
    private var initialPathWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(startImmediately: Bool = true) {
        self.hasReceivedInitialPath = !startImmediately
        if startImmediately {
            start()
        }
    }

    /// B14 / AUD-86：冷启动基于 ContinuousClock 与 CheckedContinuation 事件唤醒等待首个真实 NWPath 回调（保留超时兜底）
    public func waitForInitialPath(timeoutSeconds: TimeInterval = 0.5) async {
        guard !hasReceivedInitialPath else { return }
        let waiterID = UUID()
        let clampedTimeout = max(0.05, timeoutSeconds)
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(clampedTimeout), clock: ContinuousClock())
            self?.resumeInitialPathWaiter(id: waiterID)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if self.hasReceivedInitialPath || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.initialPathWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeInitialPathWaiter(id: waiterID)
            }
        }
        timeoutTask.cancel()
    }

    public func setOnNetworkTypeChanged(_ handler: @escaping @MainActor (Bool) -> Void) {
        self.onNetworkTypeChanged = handler
    }

    public func setOnInitialNetworkStateSynced(_ handler: @escaping @MainActor (Bool) -> Void) {
        self.onInitialNetworkStateSynced = handler
        if hasReceivedInitialPath && !hasTriggeredInitialSync {
            hasTriggeredInitialSync = true
            handler(isOnWiFi)
        }
    }

    public func start() {
        self.appliedSequence = sequenceBox.next()
        self.hasReceivedInitialPath = false
        self.hasTriggeredInitialSync = false
        monitor?.cancel()
        let newMonitor = NWPathMonitor()
        self.monitor = newMonitor
        let monitorRef = MonitorRef(newMonitor)
        let seqBox = self.sequenceBox
        newMonitor.pathUpdateHandler = { [weak self] path in
            let seq = seqBox.next()
            let connected = (path.status == .satisfied)
            let wifi = (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive && !path.isConstrained
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                guard let self, self.monitor === monitorRef.monitor && seq > self.appliedSequence else { return }
                self.appliedSequence = seq
                let hadInitial = self.hasReceivedInitialPath
                let wifiChanged = (self.isOnWiFi != wifi)
                self.hasReceivedInitialPath = true
                self.isConnected = connected
                self.isOnWiFi = wifi
                self.isExpensive = expensive
                self.resumeAllInitialPathWaiters()
                if hadInitial && wifiChanged {
                    self.onNetworkTypeChanged?(wifi)
                } else if !hadInitial && !self.hasTriggeredInitialSync {
                    if let handler = self.onInitialNetworkStateSynced {
                        self.hasTriggeredInitialSync = true
                        handler(wifi)
                    }
                }
            }
        }
        newMonitor.start(queue: queue)
    }

    public func stop() {
        self.appliedSequence = sequenceBox.next()
        monitor?.cancel()
        monitor = nil
        resumeAllInitialPathWaiters()
    }

    /// 供单元测试直接模拟网络环境切换
    public func simulateState(connected: Bool, onWiFi: Bool) {
        appliedSequence = sequenceBox.next()
        hasReceivedInitialPath = true
        let changed = (isOnWiFi != onWiFi)
        isConnected = connected
        isOnWiFi = onWiFi
        isExpensive = !onWiFi
        resumeAllInitialPathWaiters()
        if changed {
            onNetworkTypeChanged?(onWiFi)
        }
    }

    private func resumeInitialPathWaiter(id: UUID) {
        if let continuation = initialPathWaiters.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    private func resumeAllInitialPathWaiters() {
        guard !initialPathWaiters.isEmpty else { return }
        let waiters = Array(initialPathWaiters.values)
        initialPathWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }
}
