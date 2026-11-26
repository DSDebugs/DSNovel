import DSDesignSystem
import DSStorage
import SwiftData
import SwiftUI
import UIKit

/// 应用主入口（L-IOS-2：同步幂等初始化容器；SYS2-02：全仓零 ! 强制解包安全降级）
@main
struct DSNovelV3App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let isHostedUnitTest: Bool
    private let container: AppContainer?

    init() {
        let hostedUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !AppLaunchConfig.isUITesting
        self.isHostedUnitTest = hostedUnitTest
        self.container = hostedUnitTest ? nil : AppContainer.bootstrapIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            if isHostedUnitTest {
                Color.clear
            } else if let container {
                Group {
                    if container.storageResult.isDegradedInMemory {
                        DataRepairView()
                    } else if !container.settings.onboardingCompleted
                        && (!AppLaunchConfig.isUITesting || AppLaunchConfig.shouldShowOnboardingInUITest) {
                        OnboardingView()
                    } else {
                        AppShell()
                    }
                }
                .environment(container)
                .environment(container.settings)
                .environment(container.router)
                .environment(container.playback)
                .environment(container.playback.clock)
                .environment(container.downloads)
                .environment(container.downloads.progressFeed)
                .environment(container.banner)
                .modelContainer(container.modelContainer)
                .preferredColorScheme(resolvedColorScheme(for: container.settings.themeMode))
                .tint(DSColors.accent(for: container.settings.accentTheme))
                .environment(\.dsAccentTheme, container.settings.accentTheme)
                .task {
                    await container.startAsyncServicesIfNeeded()
                }
            } else {
                DSStateView(
                    icon: "externaldrive.badge.exclamationmark",
                    title: "本地存储初始化失败",
                    message: "请释放部分设备存储空间后重新启动 DSNovel。"
                )
            }
        }
    }

    private func resolvedColorScheme(for mode: AppThemeMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
