import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundDownloadSession.sessionIdentifier {
            MainActor.assumeIsolated {
                // M-P0-2：后台冷启回调到达时先同步幂等绑定 ModelContainer，避免 DownloadManager 回调时 modelContext == nil 挂死丢文件
                BackgroundDownloadSession.shared.systemCompletionHandler = completionHandler
                _ = DownloadManager.shared
                if AppDependencies.live.downloadManager.modelContext == nil,
                   let container = DSNovelApp.ensureSharedModelContainerForBackground() {
                    AppDependencies.live.bindIfNeeded(modelContainer: container)
                }
                BackgroundDownloadSession.shared.ensureSessionInitialized()
            }
        } else {
            completionHandler()
        }
    }
}
