import Foundation

/// P0-3：先到先得的一次性超时竞态封装（不依赖 withThrowingTaskGroup 等待阻塞 JSContext，超时即刻返回）
// SAFETY: 内部一次性结果提交由 NSLock/OSAllocatedUnfairLock 严格互斥。
public final class OneShotTimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    public init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    public func resume(returning value: T) {
        let cont = lock.withLock { () -> CheckedContinuation<T, Error>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(returning: value)
    }

    public func resume(throwing error: Error) {
        let cont = lock.withLock { () -> CheckedContinuation<T, Error>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(throwing: error)
    }
}

/// P1-19：线程安全共享取消令牌（用于取消/超时后立即唤醒并中止 HostHandleJS 同步阻塞操作）
// SAFETY: 取消状态标志与回调列表由内部锁互斥保护。
public final class SandboxCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [(id: UUID, fn: @Sendable () -> Void)] = []

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        let toRun: [@Sendable () -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            let list = handlers.map(\.fn)
            handlers.removeAll()
            return list
        }
        for fn in toRun { fn() }
    }

    @discardableResult
    public func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            handlers.append((id: id, fn: handler))
            return false
        }
        if alreadyCancelled {
            handler()
        }
        return id
    }

    public func removeCancelHandler(_ id: UUID) {
        lock.withLock {
            handlers.removeAll { $0.id == id }
        }
    }
}
