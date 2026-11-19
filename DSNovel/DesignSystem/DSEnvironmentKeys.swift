import SwiftUI

/// SwiftUI 环境依赖注入键（NEW-09）：
/// 为 `AppSettingsStore`、`BannerCenter`、`AppRouter` 提供标准 `EnvironmentKey` 底座，
/// 未显式注入时自动回落至各自 `.shared` 单例，保持 100% 向后兼容。

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
        get { self[DSSettingsKey.self] ?? MainActor.assumeIsolated { AppSettingsStore.shared } }
        set { self[DSSettingsKey.self] = newValue }
    }

    var dsBannerCenter: BannerCenter {
        get { self[DSBannerCenterKey.self] ?? MainActor.assumeIsolated { BannerCenter.shared } }
        set { self[DSBannerCenterKey.self] = newValue }
    }

    var dsRouter: AppRouter {
        get { self[DSRouterKey.self] ?? MainActor.assumeIsolated { AppRouter.shared } }
        set { self[DSRouterKey.self] = newValue }
    }
}
