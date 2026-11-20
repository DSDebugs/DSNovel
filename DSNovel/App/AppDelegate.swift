import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundDownloadSession.sessionIdentifier {
            MainActor.assumeIsolated {
                // 同步保存系统回调并立即唤醒 DownloadManager 与非懒加载后台 URLSession，避免错过后台重连事件
                BackgroundDownloadSession.shared.systemCompletionHandler = completionHandler
                _ = DownloadManager.shared
                BackgroundDownloadSession.shared.ensureSessionInitialized()
            }
        } else {
            completionHandler()
        }
    }
}
