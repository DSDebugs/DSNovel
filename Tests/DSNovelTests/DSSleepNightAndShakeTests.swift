import DSPlayback
import Foundation
import XCTest

final class DSSleepNightAndShakeTests: XCTestCase {
    @MainActor
    func testNightWindowAcrossMidnightAndDismissGuard() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

        func makeDate(hour: Int, minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: hour, minute: minute))!
        }

        XCTAssertTrue(SleepTimerEngine.isWithinNightWindow(date: makeDate(hour: 23, minute: 30), startHour: 23, endHour: 5, calendar: cal))
        XCTAssertTrue(SleepTimerEngine.isWithinNightWindow(date: makeDate(hour: 2, minute: 0), startHour: 23, endHour: 5, calendar: cal))
        XCTAssertFalse(SleepTimerEngine.isWithinNightWindow(date: makeDate(hour: 14, minute: 0), startHour: 23, endHour: 5, calendar: cal))
        XCTAssertFalse(SleepTimerEngine.isWithinNightWindow(date: makeDate(hour: 5, minute: 0), startHour: 23, endHour: 5, calendar: cal))

        let engine = SleepTimerEngine()
        engine.nightAutoSleepEnabled = true
        let night = makeDate(hour: 23, minute: 15)
        XCTAssertTrue(engine.shouldArmNightAutoSleep(now: night, calendar: cal))

        // 用户手动关闭后 30 分钟内不再反复自启
        engine.markManuallyDismissed(now: night)
        XCTAssertFalse(engine.shouldArmNightAutoSleep(now: night.addingTimeInterval(600), calendar: cal))
        XCTAssertTrue(engine.shouldArmNightAutoSleep(now: night.addingTimeInterval(1900), calendar: cal))
    }

    func testShakeDetectorRequiresDualPeakAndRespectsCooldown() {
        var state = SleepShakeMonitor.DetectorState()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // 单次静止或轻微震动不触发
        XCTAssertFalse(SleepShakeMonitor.evaluateSample(x: 0.0, y: 0.0, z: 1.0, now: t0, state: &state))
        XCTAssertFalse(SleepShakeMonitor.evaluateSample(x: 2.9, y: 0.0, z: 0.0, now: t0.addingTimeInterval(0.1), state: &state))

        // 0.25s 后第二个 > 1.8G 峰值命中双峰触发
        XCTAssertTrue(SleepShakeMonitor.evaluateSample(x: -3.0, y: 0.0, z: 0.0, now: t0.addingTimeInterval(0.35), state: &state))

        // 4 秒冷却期内连续猛摇不重复触发
        XCTAssertFalse(SleepShakeMonitor.evaluateSample(x: 3.1, y: 0.0, z: 0.0, now: t0.addingTimeInterval(1.0), state: &state))
        XCTAssertFalse(SleepShakeMonitor.evaluateSample(x: -3.1, y: 0.0, z: 0.0, now: t0.addingTimeInterval(1.25), state: &state))

        // 冷却期结束后可再次触发
        XCTAssertFalse(SleepShakeMonitor.evaluateSample(x: 3.1, y: 0.0, z: 0.0, now: t0.addingTimeInterval(5.0), state: &state))
        XCTAssertTrue(SleepShakeMonitor.evaluateSample(x: -3.1, y: 0.0, z: 0.0, now: t0.addingTimeInterval(5.2), state: &state))
    }
}
