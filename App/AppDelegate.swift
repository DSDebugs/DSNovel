import AVFoundation
import DSDownloads
import Foundation
import UIKit

/// 主线程隔离的后台 URLSession 回调协调器（ARC-08/AUD-92：零 nonisolated(unsafe)，统一单一 handler 分发）
@MainActor
final class BackgroundSessionCoordinator {
    static let shared = BackgroundSessionCoordinator()
    private var handler: ((@escaping @Sendable () -> Void) -> Void)?

    func registerHandler(_ handler: @escaping (@escaping @Sendable () -> Void) -> Void) {
        self.handler = handler
    }

    func dispatchBackgroundCompletion(_ completion: @escaping @Sendable () -> Void) {
        if handler == nil {
            _ = AppContainer.bootstrapIfNeeded()
        }
        if let handler {
            handler(completion)
        } else {
            completion()
        }
    }
}

/// 主线程一次性安全包装箱（P1-14：严格保证系统 completionHandler 仅回调一次）
private final class MainActorCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var closure: (() -> Void)?
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    func invokeOnMain() {
        let cb = lock.withLock { () -> (() -> Void)? in
            let current = closure
            closure = nil
            return current
        }
        guard let cb else { return }
        DispatchQueue.main.async { cb() }
    }
}

/// 应用委托：同步直连后台 URLSession 唤醒与纯竖屏方向锁定
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundTransferTransport.sessionIdentifier else {
            completionHandler()
            return
        }
        let box = MainActorCompletionBox(completionHandler)
        let sendableCompletion: @Sendable () -> Void = { box.invokeOnMain() }
        MainActor.assumeIsolated {
            BackgroundSessionCoordinator.shared.dispatchBackgroundCompletion(sendableCompletion)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated {
            AppContainer.existingInstance?.playback.tearDown()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
