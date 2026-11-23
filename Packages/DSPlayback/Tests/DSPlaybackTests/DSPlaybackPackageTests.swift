import AVFoundation
import DSPlayback
import Foundation
import XCTest

final class DSPlaybackPackageTests: XCTestCase {
    @MainActor
    func testPlaybackClockProgressClampingAndReset() {
        let clock = PlaybackClock()
        clock.update(current: 30, duration: 120)
        XCTAssertEqual(clock.progress, 0.25, accuracy: 0.001)

        clock.update(current: .nan, duration: .infinity, buffered: -10)
        XCTAssertEqual(clock.currentSeconds, 0)
        XCTAssertEqual(clock.progress, 0)

        clock.reset()
        XCTAssertEqual(clock.currentSeconds, 0)
        XCTAssertEqual(clock.durationSeconds, 0)
    }

    func testPlayerSpeedFormatterPrecisionAndClamping() {
        XCTAssertEqual(PlayerSpeedFormatter.format(0.1), "0.5x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.0), "1.0x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.25), "1.25x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.5), "1.5x")
        XCTAssertEqual(PlayerSpeedFormatter.format(4.0), "3.0x")
    }

    @MainActor
    func testAudioTapDSPFadeClampingAndFallbackWatchdog() async {
        let dsp = AudioTapDSP(watchdogTimeoutNanoseconds: 20_000_000)
        let player = AVPlayer()
        dsp.applyFadeVolume(to: player, factor: -1.0)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 0.0, accuracy: 0.001)
        dsp.applyFadeVolume(to: player, factor: 2.0)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 1.0, accuracy: 0.001)

        var fallbackCount = 0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            dsp.prepareForStream(
                isHLS: false,
                mimeType: nil,
                assetURL: URL(string: "https://cdn.example.com/audio")!,
                onFallback: {
                    fallbackCount += 1
                    cont.resume()
                }
            )
        }
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertTrue(dsp.isUsingNativeVolumeFallback)
    }

    @MainActor
    func testSleepTimerChapterCountdownAndFadeRestore() async {
        let engine = SleepTimerEngine(tickIntervalNanoseconds: 10_000_000)
        engine.startAfterChapters(2)
        XCTAssertEqual(engine.displayBadge, "播完2章")
        XCTAssertFalse(engine.consumeChapterFinished())
        XCTAssertEqual(engine.displayBadge, "播完1章")
        XCTAssertTrue(engine.consumeChapterFinished())
        XCTAssertFalse(engine.isActive)

        engine.fadeOutLastSeconds = 120
        var factors: [Float] = []
        engine.startCountdown(minutes: 1, onFadeFactor: { factors.append($0) }, onFire: {})
        let deadline = ContinuousClock.now + .seconds(2)
        while !factors.contains(where: { $0 < 1.0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(factors.contains(where: { $0 >= 0.05 && $0 < 1.0 }))
        engine.cancel()
        XCTAssertEqual(factors.last, 1.0)
    }
}
