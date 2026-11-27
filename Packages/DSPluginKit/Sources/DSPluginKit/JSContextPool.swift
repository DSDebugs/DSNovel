import Foundation

/// 绑定单条固定串行 DispatchQueue 的 JS 执行租约（带代际号，隔离已退役死循环槽位的延迟归还）
public struct JSSlotLease: Sendable {
    public let index: Int
    public let queue: DispatchQueue
    internal let generation: UInt64

    internal init(index: Int, queue: DispatchQueue, generation: UInt64 = 0) {
        self.index = index
        self.queue = queue
        self.generation = generation
    }
}

/// 取消感知的 JSContext 有界串行队列池（支持排队超时与死循环卡死槽位的安全退役替补）
public actor JSContextPool {
    private let maxSlots: Int
    private let labelPrefix: String
    private let maxRetiredReplacements: Int
    private var serialQueues: [DispatchQueue]
    private var slotGenerations: [UInt64]
    private var availableIndices: [Int]
    private var checkedOutIndices: Set<Int> = []
    private var activeSlots: Int = 0
    private var retiredCount: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<JSSlotLease, Error>)] = []

    public init(
        maxSlots: Int = 4,
        labelPrefix: String = "com.dsnovel.app.js.slot",
        maxRetiredReplacements: Int = 8
    ) {
        let count = max(1, maxSlots)
        self.maxSlots = count
        self.labelPrefix = labelPrefix
        self.maxRetiredReplacements = max(0, maxRetiredReplacements)
        self.serialQueues = (0..<count).map { idx in
            DispatchQueue(label: "\(labelPrefix).\(idx)", qos: .userInitiated)
        }
        self.slotGenerations = Array(repeating: 0, count: count)
        self.availableIndices = Array(0..<count)
    }

    public var currentActiveSlots: Int { activeSlots }
    public var currentRetiredSlots: Int { retiredCount }

    public func withSlot<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let lease = try await acquireLease()
        defer { releaseLease(lease) }
        return try await work()
    }

    public func acquireLease(timeoutSeconds: TimeInterval? = nil) async throws -> JSSlotLease {
        try Task.checkCancellation()
        if !availableIndices.isEmpty {
            let idx = availableIndices.removeFirst()
            checkedOutIndices.insert(idx)
            activeSlots = checkedOutIndices.count
            return JSSlotLease(index: idx, queue: serialQueues[idx], generation: slotGenerations[idx])
        }
        let waiterID = UUID()
        let timeoutTask: Task<Void, Never>? = timeoutSeconds.map { seconds in
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .seconds(max(0.05, seconds)))
                guard !Task.isCancelled else { return }
                await self.cancelWaiter(id: waiterID)
            }
        }
        defer { timeoutTask?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSSlotLease, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append((id: waiterID, continuation: cont))
                }
            }
        } onCancel: {
            timeoutTask?.cancel()
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    public func releaseLease(_ lease: JSSlotLease) {
        guard lease.index >= 0, lease.index < slotGenerations.count,
              slotGenerations[lease.index] == lease.generation,
              checkedOutIndices.contains(lease.index) else {
            return
        }
        handOffOrReturnSlot(at: lease.index)
    }

    /// 死循环脚本超时后仍未退出时调用：隔离旧卡死队列并新建干净串行队列顶替该槽位（受 maxRetiredReplacements 上限保护）
    @discardableResult
    public func retireAndReplaceLease(_ lease: JSSlotLease) -> Bool {
        guard lease.index >= 0, lease.index < slotGenerations.count,
              slotGenerations[lease.index] == lease.generation,
              checkedOutIndices.contains(lease.index) else {
            return false
        }
        guard retiredCount < maxRetiredReplacements else {
            return false
        }
        retiredCount += 1
        let nextGen = slotGenerations[lease.index] &+ 1
        slotGenerations[lease.index] = nextGen
        serialQueues[lease.index] = DispatchQueue(
            label: "\(labelPrefix).\(lease.index).r\(nextGen)",
            qos: .userInitiated
        )
        handOffOrReturnSlot(at: lease.index)
        return true
    }

    private func handOffOrReturnSlot(at index: Int) {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            let freshLease = JSSlotLease(
                index: index,
                queue: serialQueues[index],
                generation: slotGenerations[index]
            )
            next.continuation.resume(returning: freshLease)
        } else {
            checkedOutIndices.remove(index)
            if !availableIndices.contains(index) {
                availableIndices.append(index)
            }
            activeSlots = checkedOutIndices.count
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: idx)
            removed.continuation.resume(throwing: CancellationError())
        }
    }
}
