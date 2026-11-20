import Foundation

struct AppLaunchConfig: Equatable, Sendable {
    let isUITestMode: Bool
    let simulateStoreFailure: Bool
    let forceReduceMotion: Bool
    let isEmptyLibraryAndSources: Bool
    let isNoSourceOnly: Bool

    static var current: AppLaunchConfig {
        #if DEBUG
        let args = Set(ProcessInfo.processInfo.arguments)
        return AppLaunchConfig(
            isUITestMode: args.contains("-DSNOVEL_UITEST"),
            simulateStoreFailure: args.contains("-DSNOVEL_SIMULATE_STORE_FAILURE"),
            forceReduceMotion: args.contains("-DSNOVEL_REDUCE_MOTION"),
            isEmptyLibraryAndSources: args.contains("-DSNOVEL_EMPTY"),
            isNoSourceOnly: args.contains("-DSNOVEL_NO_SOURCE")
        )
        #else
        return AppLaunchConfig(
            isUITestMode: false,
            simulateStoreFailure: false,
            forceReduceMotion: false,
            isEmptyLibraryAndSources: false,
            isNoSourceOnly: false
        )
        #endif
    }
}
