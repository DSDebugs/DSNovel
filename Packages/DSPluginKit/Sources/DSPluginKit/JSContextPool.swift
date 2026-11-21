import Foundation

/// 绑定单条固定串行 DispatchQueue 的 JS 执行租约（超时不提前释放，直至执行块真正退出）
public struct JSSlotLease: Sendable {
    public let index: Int
    public let queue: DispatchQueue

    internal init(index: Int, queue: DispatchQueue) {
        self.index = index
        self.queue = queue
    }
}

/// 取消感知的 JSContext 有界串行队列池（AUD-13：固定数量串行队列，超时不提前释放被阻塞槽位）
public actor JSContextPool {
    private let maxSlots: Int
    private let serialQueues: [DispatchQueue]
    private var availableIndices: [Int]
    private var activeSlots: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<JSSlotLease, Error>)] = []

    public init(maxSlots: Int = 4, labelPrefix: String = "com.dsnovel.v3.js.slot") {
        let count = max(1, maxSlots)
        self.maxSlots = count
        self.serialQueues = (0..<count).map { idx in
            DispatchQueue(label: "\(labelPrefix).\(idx)", qos: .userInitiated)
        }
        self.availableIndices = Array(0..<count)
    }

    public var currentActiveSlots: Int { activeSlots }

    public func withSlot<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let lease = try await acquireLease()
        defer { releaseLease(lease) }
        return try await work()
    }

    public func acquireLease() async throws -> JSSlotLease {
        try Task.checkCancellation()
        if !availableIndices.isEmpty {
            let idx = availableIndices.removeFirst()
            activeSlots += 1
            return JSSlotLease(index: idx, queue: serialQueues[idx])
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSSlotLease, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append((id: waiterID, continuation: cont))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    public func releaseLease(_ lease: JSSlotLease) {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: lease)
        } else {
            if !availableIndices.contains(lease.index) {
                availableIndices.append(lease.index)
            }
            activeSlots = max(0, maxSlots - availableIndices.count)
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: idx)
            removed.continuation.resume(throwing: CancellationError())
        }
    }
}
