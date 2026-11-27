import DSCore
import DSDesignSystem
import DSStorage
import Foundation
import Testing
@testable import DSNovel

@Suite("内置主题配色与启动默认页回归测试", .serialized)
struct DSAccentThemeAndLaunchTabTests {
    @Test("内置 6 款主题配色完整且包含网易红，全局色彩令牌同步更新")
    func builtinAccentThemesAndPaletteSync() {
        #expect(DSAccentTheme.allCases.count == 6)
        #expect(DSAccentTheme.allCases.contains(.neteaseRed))
        #expect(DSAccentTheme.neteaseRed.title == "网易红")

        let original = DSColors.currentAccentTheme
        defer { DSColors.setAccentTheme(original) }

        for theme in DSAccentTheme.allCases {
            DSColors.setAccentTheme(theme)
            #expect(DSColors.currentAccentTheme == theme)
            _ = DSColors.accent(for: theme)
            _ = DSColors.accentSwatch(for: theme)
            _ = DSColors.resolvedAccent(nightDim: true)
        }
    }

    @Test("AppSettingsStore 持久化主题色与启动默认页，AppRouter 按配置初始化")
    @MainActor
    func settingsPersistenceAndRouterInitialization() throws {
        let suiteName = "ds_theme_launch_test_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsStore(defaults: defaults)
        #expect(store.accentTheme == .terracotta)
        #expect(store.defaultLaunchTab == .library)

        store.accentTheme = .neteaseRed
        store.defaultLaunchTab = .discover

        let reloaded = AppSettingsStore(defaults: defaults)
        #expect(reloaded.accentTheme == .neteaseRed)
        #expect(reloaded.defaultLaunchTab == .discover)

        let defaultRouter = AppRouter()
        #expect(defaultRouter.selectedTab == .library)

        let discoverRouter = AppRouter(initialTab: reloaded.defaultLaunchTab == .discover ? .discover : .library)
        #expect(discoverRouter.selectedTab == .discover)
    }
}
