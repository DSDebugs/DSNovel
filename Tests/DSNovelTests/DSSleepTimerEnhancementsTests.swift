import DSPlayback
import Foundation
import Testing

@Suite("DSSleepTimer 续时、按章延长与睡前偏好持久化测试")
struct DSSleepTimerEnhancementsTests {
    @Test("按章延长与倒计时续时不串模式且正确夹紧上限")
    @MainActor
    func extendChaptersAndMinutes() {
        let engine = SleepTimerEngine(tickIntervalNanoseconds: 60_000_000_000)
        engine.startAfterChapters(2)
        engine.extendChapters(by: 1)
        #expect(engine.mode == .afterChapters(remaining: 3))

        engine.extendChapters(by: 20)
        #expect(engine.mode == .afterChapters(remaining: 10))

        let now = Date()
        engine.startCountdown(minutes: 15, now: now, onFadeFactor: { _ in }, onFire: {})
        #expect(engine.estimatedEndDate != nil)
        let before = engine.remainingSeconds
        engine.extendMinutes(by: 5, now: now, onFadeFactor: { _ in }, onFire: {})
        #expect(engine.remainingSeconds >= before + 240)
        engine.cancel()
    }

    @Test("SleepTimerEngine 持久化恢复渐弱开关、自动回退秒数与上次自定义时长")
    @MainActor
    func sleepTimerPersistenceRoundTrip() {
        let suite = "dsnovel.test.sleeptimer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }

        let e1 = SleepTimerEngine()
        e1.bindPersistence(defaults)
        e1.fadeOutLastSeconds = 0
        e1.autoRewindOnSleepSeconds = 30
        e1.lastCustomMinutes = 40

        let e2 = SleepTimerEngine()
        e2.bindPersistence(defaults)
        #expect(e2.fadeOutLastSeconds == 0)
        #expect(e2.autoRewindOnSleepSeconds == 30)
        #expect(e2.lastCustomMinutes == 40)
    }
}
