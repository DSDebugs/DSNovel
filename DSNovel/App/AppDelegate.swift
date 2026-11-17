import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundDownloadSession.sessionIdentifier {
            Task { @MainActor in
                BackgroundDownloadSession.shared.systemCompletionHandler = completionHandler
            }
        } else {
            completionHandler()
        }
    }
}
