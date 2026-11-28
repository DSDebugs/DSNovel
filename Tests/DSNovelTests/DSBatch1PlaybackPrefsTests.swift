import DSCore
import DSPlayback
import DSStorage
import Foundation
import XCTest

final class DSBatch1PlaybackPrefsTests: XCTestCase {
    @MainActor
    func testPerBookPlaybackRateOverridesGlobalAndClearsBackToGlobal() {
        let suiteName = "DSBatch1PlaybackPrefsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.playbackRate = 1.25

        XCTAssertEqual(settings.resolvedPlaybackRate(forBookID: "book-a"), 1.25, accuracy: 0.001)
        XCTAssertFalse(settings.hasBookPlaybackRate(forBookID: "book-a"))

        settings.setBookPlaybackRate(1.75, forBookID: "book-a")
        XCTAssertTrue(settings.hasBookPlaybackRate(forBookID: "book-a"))
        XCTAssertEqual(settings.resolvedPlaybackRate(forBookID: "book-a"), 1.75, accuracy: 0.001)
        XCTAssertEqual(settings.resolvedPlaybackRate(forBookID: "book-b"), 1.25, accuracy: 0.001)

        // 清除单书覆盖后自动回退全局倍速
        settings.setBookPlaybackRate(nil, forBookID: "book-a")
        XCTAssertFalse(settings.hasBookPlaybackRate(forBookID: "book-a"))
        XCTAssertEqual(settings.resolvedPlaybackRate(forBookID: "book-a"), 1.25, accuracy: 0.001)
    }

    func testSmartRewindThresholdsMutualExclusionAndIntroClamp() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // 未超过暂停阈值时不回退
        let tooShort = PlaybackCoordinator.computeSmartRewindTarget(
            enabled: true,
            pausedAt: t0,
            pauseReason: .manual,
            sleepAutoRewindSeconds: 30,
            thresholdMinutes: 10,
            rewindSeconds: 10,
            currentSeconds: 120,
            introFloorSeconds: 15,
            now: t0.addingTimeInterval(599)
        )
        XCTAssertNil(tooShort)

        // 超过阈值正常回退 10 秒
        let normal = PlaybackCoordinator.computeSmartRewindTarget(
            enabled: true,
            pausedAt: t0,
            pauseReason: .manual,
            sleepAutoRewindSeconds: 30,
            thresholdMinutes: 10,
            rewindSeconds: 10,
            currentSeconds: 120,
            introFloorSeconds: 15,
            now: t0.addingTimeInterval(605)
        )
        XCTAssertEqual(normal ?? -1, 110, accuracy: 0.01)

        // 睡眠定时暂停且已开启睡眠回退时，互斥跳过避免双重回退
        let sleepMutex = PlaybackCoordinator.computeSmartRewindTarget(
            enabled: true,
            pausedAt: t0,
            pauseReason: .sleepTimer,
            sleepAutoRewindSeconds: 30,
            thresholdMinutes: 10,
            rewindSeconds: 10,
            currentSeconds: 120,
            introFloorSeconds: 15,
            now: t0.addingTimeInterval(3600)
        )
        XCTAssertNil(sleepMutex)

        // 不回退进跳过片头区间
        let clampedIntro = PlaybackCoordinator.computeSmartRewindTarget(
            enabled: true,
            pausedAt: t0,
            pauseReason: .manual,
            sleepAutoRewindSeconds: 0,
            thresholdMinutes: 5,
            rewindSeconds: 15,
            currentSeconds: 22,
            introFloorSeconds: 15,
            now: t0.addingTimeInterval(600)
        )
        XCTAssertEqual(clampedIntro ?? -1, 15, accuracy: 0.01)
    }
}
