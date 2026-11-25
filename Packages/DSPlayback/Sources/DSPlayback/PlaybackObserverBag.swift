import Foundation

/// 线程安全观察者清理容器（SYS2-01：独立非 @MainActor 类，供 PlaybackCoordinator 安全托管观察者并在 deinit 释放，零 Swift 6 并发报错）
final class PlaybackObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    func replaceItemObservers(
        end: NSObjectProtocol?,
        stall: NSObjectProtocol?,
        status: NSKeyValueObservation?
    ) {
        let old = lock.withLock { () -> (NSObjectProtocol?, NSObjectProtocol?, NSKeyValueObservation?) in
            let prev = (endObserver, stallObserver, statusObservation)
            endObserver = end
            stallObserver = stall
            statusObservation = status
            return prev
        }
        if let e = old.0 { NotificationCenter.default.removeObserver(e) }
        if let s = old.1 { NotificationCenter.default.removeObserver(s) }
        old.2?.invalidate()
    }

    func tearDownAll() {
        replaceItemObservers(end: nil, stall: nil, status: nil)
    }

    deinit {
        tearDownAll()
    }
}
