import Foundation

/// UI 测试启动参数隔离（规则 #12：DSNOVEL_UITEST 仅允许出现在此文件与 Tests/ 中）
enum AppLaunchConfig {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("DSNOVEL_UITEST")
            || ProcessInfo.processInfo.environment["DSNOVEL_UITEST"] == "1"
    }

    static var shouldResetState: Bool {
        ProcessInfo.processInfo.arguments.contains("DSNOVEL_UITEST_RESET")
    }

    static var shouldShowOnboardingInUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("DSNOVEL_UITEST_SHOW_ONBOARDING")
            || ProcessInfo.processInfo.environment["DSNOVEL_UITEST_SHOW_ONBOARDING"] == "1"
    }
}
