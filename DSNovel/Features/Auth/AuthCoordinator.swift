import Foundation
import Observation

@MainActor
@Observable
final class AuthCoordinator {
    static let shared = AuthCoordinator()

    var activeAuthRequest: WebAuthSessionRequest?
    private(set) var lastCompletedSourceID: String?
    private(set) var completionCount: Int = 0
    private var subscribers: [UUID: (String) -> Void] = [:]

    init() {}

    @discardableResult
    func subscribe(_ handler: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    func presentLogin(forSourceID sourceID: String, isVerification: Bool = false) {
        let src = SourceStore.shared.source(for: sourceID)
        let name = src?.name ?? sourceID
        let rawURL = (src?.loginURL.isEmpty == false ? src?.loginURL : src?.siteURL) ?? "https://www.example.com"
        let sheetTitle = isVerification ? "安全验证 · \(name)" : "登录 · \(name)"
        activeAuthRequest = WebAuthSessionRequest(
            sourceID: sourceID,
            title: sheetTitle,
            initialURL: rawURL,
            expectedCookieName: nil,
            onCompleted: { [weak self] in
                Task { @MainActor in
                    self?.notifyLoginCompleted(sourceID: sourceID)
                }
            }
        )
    }

    func notifyLoginCompleted(sourceID: String) {
        SourceStore.shared.markLoggedIn(sourceID: sourceID)
        lastCompletedSourceID = sourceID
        completionCount &+= 1
        activeAuthRequest = nil
        DSHapticPolicy.fire(.success)
        BannerCenter.shared.show("已登录", kind: .success)

        for callback in subscribers.values {
            callback(sourceID)
        }
        if DiscoverStore.shared.currentSourceID == sourceID {
            Task { await DiscoverStore.shared.loadCategoryMenusAndFirstPage(forceReload: true) }
        }
    }

    func notifyLoginCancelledOrFailed(message: String? = nil) {
        activeAuthRequest = nil
        if let message, !message.isEmpty {
            BannerCenter.shared.show(message, kind: .warning)
        }
    }
}
