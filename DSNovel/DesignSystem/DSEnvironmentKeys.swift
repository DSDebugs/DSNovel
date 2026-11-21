import SwiftUI

/// SwiftUI 环境依赖注入键（NEW-09）：
/// 为 `AppSettingsStore`、`BannerCenter`、`AppRouter` 提供标准 `EnvironmentKey` 底座，
/// 未显式注入时在主线程自动回落至各自 `.shared` 单例并缓存线程安全引用，避免非主线程 `MainActor.assumeIsolated` 崩溃。

private final class DSEnvironmentFallbackBox<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Value?

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func store(_ value: Value) {
        lock.lock()
        cached = value
        lock.unlock()
    }

    func storeIfNil(_ value: Value) {
        lock.lock()
        if cached == nil {
            cached = value
        }
        lock.unlock()
    }
}

enum DSEnvironmentFallbackStore {
    static let settings = DSEnvironmentFallbackBox<AppSettingsStore>()
    static let bannerCenter = DSEnvironmentFallbackBox<BannerCenter>()
    static let router = DSEnvironmentFallbackBox<AppRouter>()

    static func prime(settings: AppSettingsStore, bannerCenter: BannerCenter, router: AppRouter) {
        self.settings.storeIfNil(settings)
        self.bannerCenter.storeIfNil(bannerCenter)
        self.router.storeIfNil(router)
    }
}

private struct DSSettingsKey: EnvironmentKey {
    static let defaultValue: AppSettingsStore? = nil
}

private struct DSBannerCenterKey: EnvironmentKey {
    static let defaultValue: BannerCenter? = nil
}

private struct DSRouterKey: EnvironmentKey {
    static let defaultValue: AppRouter? = nil
}

extension EnvironmentValues {
    var dsSettings: AppSettingsStore {
        get {
            if let existing = self[DSSettingsKey.self] {
                return existing
            }
            if Thread.isMainThread {
                let value = MainActor.assumeIsolated { AppSettingsStore.shared }
                DSEnvironmentFallbackStore.settings.storeIfNil(value)
                return value
            }
            if let cached = DSEnvironmentFallbackStore.settings.load() {
                return cached
            }
            let value: AppSettingsStore = DispatchQueue.main.sync {
                MainActor.assumeIsolated { AppSettingsStore.shared }
            }
            DSEnvironmentFallbackStore.settings.storeIfNil(value)
            return value
        }
        set {
            self[DSSettingsKey.self] = newValue
            DSEnvironmentFallbackStore.settings.store(newValue)
        }
    }

    var dsBannerCenter: BannerCenter {
        get {
            if let existing = self[DSBannerCenterKey.self] {
                return existing
            }
            if Thread.isMainThread {
                let value = MainActor.assumeIsolated { BannerCenter.shared }
                DSEnvironmentFallbackStore.bannerCenter.storeIfNil(value)
                return value
            }
            if let cached = DSEnvironmentFallbackStore.bannerCenter.load() {
                return cached
            }
            let value: BannerCenter = DispatchQueue.main.sync {
                MainActor.assumeIsolated { BannerCenter.shared }
            }
            DSEnvironmentFallbackStore.bannerCenter.storeIfNil(value)
            return value
        }
        set {
            self[DSBannerCenterKey.self] = newValue
            DSEnvironmentFallbackStore.bannerCenter.store(newValue)
        }
    }

    var dsRouter: AppRouter {
        get {
            if let existing = self[DSRouterKey.self] {
                return existing
            }
            if Thread.isMainThread {
                let value = MainActor.assumeIsolated { AppRouter.shared }
                DSEnvironmentFallbackStore.router.storeIfNil(value)
                return value
            }
            if let cached = DSEnvironmentFallbackStore.router.load() {
                return cached
            }
            let value: AppRouter = DispatchQueue.main.sync {
                MainActor.assumeIsolated { AppRouter.shared }
            }
            DSEnvironmentFallbackStore.router.storeIfNil(value)
            return value
        }
        set {
            self[DSRouterKey.self] = newValue
            DSEnvironmentFallbackStore.router.store(newValue)
        }
    }
}
