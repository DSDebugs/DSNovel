import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import Foundation
import XCTest

final class DSPlaybackAndDSDownloadsMatrixTests: XCTestCase {

    func testSpeedFormatter_0_5() {
        XCTAssertEqual(PlayerSpeedFormatter.format(0.5), "0.5x")
    }

    func testSpeedFormatter_0_75() {
        XCTAssertEqual(PlayerSpeedFormatter.format(0.75), "0.75x")
    }

    func testSpeedFormatter_1_0() {
        XCTAssertEqual(PlayerSpeedFormatter.format(1.0), "1.0x")
    }

    func testSpeedFormatter_1_25() {
        XCTAssertEqual(PlayerSpeedFormatter.format(1.25), "1.25x")
    }

    func testSpeedFormatter_1_5() {
        XCTAssertEqual(PlayerSpeedFormatter.format(1.5), "1.5x")
    }

    func testSpeedFormatter_1_75() {
        XCTAssertEqual(PlayerSpeedFormatter.format(1.75), "1.75x")
    }

    func testSpeedFormatter_2_0() {
        XCTAssertEqual(PlayerSpeedFormatter.format(2.0), "2.0x")
    }

    func testSpeedFormatter_2_5() {
        XCTAssertEqual(PlayerSpeedFormatter.format(2.5), "2.5x")
    }

    func testSpeedFormatter_3_0() {
        XCTAssertEqual(PlayerSpeedFormatter.format(3.0), "3.0x")
    }

    func testSpeedFormatter_clampLow() {
        XCTAssertEqual(PlayerSpeedFormatter.format(0.1), "0.5x")
    }

    func testSpeedFormatter_clampHigh() {
        XCTAssertEqual(PlayerSpeedFormatter.format(5.0), "3.0x")
    }

    func testEQPreset_flat_HasFiveBands() {
        let p = AudioEQPreset.flat
        XCTAssertEqual(p.bandGainsDB.count, 5)
        XCTAssertFalse(p.title.isEmpty)
    }

    func testEQPreset_voiceBoost_HasFiveBands() {
        let p = AudioEQPreset.voiceBoost
        XCTAssertEqual(p.bandGainsDB.count, 5)
        XCTAssertFalse(p.title.isEmpty)
    }

    func testEQPreset_warm_HasFiveBands() {
        let p = AudioEQPreset.warm
        XCTAssertEqual(p.bandGainsDB.count, 5)
        XCTAssertFalse(p.title.isEmpty)
    }

    func testEQPreset_night_HasFiveBands() {
        let p = AudioEQPreset.night
        XCTAssertEqual(p.bandGainsDB.count, 5)
        XCTAssertFalse(p.title.isEmpty)
    }

    func testEQPreset_bright_HasFiveBands() {
        let p = AudioEQPreset.bright
        XCTAssertEqual(p.bandGainsDB.count, 5)
        XCTAssertFalse(p.title.isEmpty)
    }

    func testScrubberFormatTime_zero() {
        XCTAssertEqual(DSScrubber.formatTime(0), "00:00")
    }

    func testScrubberFormatTime_fiveSec() {
        XCTAssertEqual(DSScrubber.formatTime(5), "00:05")
    }

    func testScrubberFormatTime_oneMin() {
        XCTAssertEqual(DSScrubber.formatTime(60), "01:00")
    }

    func testScrubberFormatTime_oneHour() {
        XCTAssertEqual(DSScrubber.formatTime(3600), "1:00:00")
    }

    func testScrubberFormatTime_hourMinSec() {
        XCTAssertEqual(DSScrubber.formatTime(3665), "1:01:05")
    }

    func testScrubberFormatTime_negative() {
        XCTAssertEqual(DSScrubber.formatTime(-10), "00:00")
    }

    func testScrubberFormatTime_nan() {
        XCTAssertEqual(DSScrubber.formatTime(Double.nan), "00:00")
    }

    func testScrubberFormatTime_infinity() {
        XCTAssertEqual(DSScrubber.formatTime(Double.infinity), "00:00")
    }

    func testAudioDSPParametersClamping() {
        let p = AudioDSPParameters(bandGainsDB: [1, 2], stereoBalance: 5.0, volumeBoostEnabled: true, fadeGain: -2.0)
        XCTAssertEqual(p.bandGainsDB, [0, 0, 0, 0, 0])
        XCTAssertEqual(p.stereoBalance, 1.0)
        XCTAssertEqual(p.fadeGain, 0.0)
    }

    @MainActor
    func testAudioTapDSPMarkReceiptCancelsFallback() {
        let dsp = AudioTapDSP(watchdogTimeoutNanoseconds: 25_000_000)
        var fallback = false
        dsp.prepareForStream(
            isHLS: false,
            mimeType: "audio/mp4",
            assetURL: URL(string: "https://cdn.example.com/a.m4a")!,
            onFallback: { fallback = true }
        )
        XCTAssertTrue(dsp.isWatchdogPending, "非 HLS 音频流挂载后应同步启动看门狗任务")
        dsp.markTapReceiptReceived()
        XCTAssertFalse(dsp.isWatchdogPending, "收到 Tap 回执后应立即取消看门狗任务")
        XCTAssertFalse(dsp.isUsingNativeVolumeFallback)
        XCTAssertFalse(fallback)
    }

    @MainActor
    func testAudioTapDSPM3U8SuffixImmediateFallback() {
        let dsp = AudioTapDSP()
        var fallback = false
        dsp.prepareForStream(
            isHLS: false,
            mimeType: nil,
            assetURL: URL(string: "https://cdn.example.com/playlist.m3u8")!,
            onFallback: { fallback = true }
        )
        XCTAssertTrue(dsp.isUsingNativeVolumeFallback)
        XCTAssertTrue(fallback)
    }

    @MainActor
    func testPlaybackClockHandlesNaNAndZeroDuration() {
        let clock = PlaybackClock()
        clock.update(current: .nan, duration: .infinity, buffered: -5)
        XCTAssertEqual(clock.currentSeconds, 0)
        XCTAssertEqual(clock.durationSeconds, 0)
        XCTAssertEqual(clock.progress, 0)
        clock.update(current: 60, duration: 100)
        clock.update(current: 70, duration: 0)
        XCTAssertEqual(clock.durationSeconds, 100)
        XCTAssertEqual(clock.progress, 0.7, accuracy: 0.001)
        clock.reset()
        XCTAssertEqual(clock.currentSeconds, 0)
    }

    @MainActor
    func testSleepTimerChapterClampingAndCancel() {
        let engine = SleepTimerEngine()
        engine.startAfterChapters(0)
        XCTAssertEqual(engine.displayBadge, "播完1章")
        engine.startAfterChapters(99)
        XCTAssertEqual(engine.displayBadge, "播完10章")
        engine.cancel()
        XCTAssertNil(engine.displayBadge)
        XCTAssertFalse(engine.isActive)
    }

    func testDownloadSchedulerRespectsBackoffWindow() {
        let scheduler = DownloadScheduler(maxManualConcurrent: 2, maxPrecacheConcurrent: 1)
        let now = Date()
        let delayed = DownloadRecordSnapshot(
            id: "d1", bookID: "b", bookTitle: "B", sourceID: "s",
            chapterID: "c1", chapterIndex: 0, chapterTitle: "C1", chapterURL: "https://example.com/1",
            kind: .manual, state: .queued, retryCount: 1, retryNotBefore: now.addingTimeInterval(30)
        )
        let ready = DownloadRecordSnapshot(
            id: "d2", bookID: "b", bookTitle: "B", sourceID: "s",
            chapterID: "c2", chapterIndex: 1, chapterTitle: "C2", chapterURL: "https://example.com/2",
            kind: .manual, state: .queued, retryCount: 0, retryNotBefore: nil
        )
        let picked = scheduler.pickNextBatch(manualCandidates: [delayed, ready], precacheCandidates: [], now: now)
        XCTAssertEqual(picked.map(\.id), ["d2"])
    }

    func testDownloadSchedulerActiveSlotTracking() {
        var scheduler = DownloadScheduler(maxManualConcurrent: 2, maxPrecacheConcurrent: 1)
        scheduler.markStarted(id: "m1", kind: .manual)
        scheduler.markStarted(id: "p1", kind: .precache)
        XCTAssertEqual(scheduler.totalActiveCount, 2)
        scheduler.markFinished(id: "m1")
        XCTAssertEqual(scheduler.totalActiveCount, 1)
    }

    func testDownloadProgressFeedUpdatesAndRemoval() async {
        await MainActor.run {
            let feed = DownloadProgressFeed()
            feed.update(id: "t1", downloaded: 50, total: 200, speed: 1024)
            XCTAssertEqual(feed.progress(for: "t1"), 0.25, accuracy: 0.001)
            feed.remove(id: "t1")
            XCTAssertEqual(feed.progress(for: "t1"), 0)
        }
    }

    func testCoverPipelineRejectsInvalidContentTypes() {
        for ct in ["text/html", "application/json", "text/plain"] {
            XCTAssertNil(CoverImagePipeline.validateAndDecodeImage(data: Data("abc".utf8), contentType: ct))
        }
        XCTAssertNil(CoverImagePipeline.validateAndDecodeImage(data: Data(), contentType: "image/png"))
    }
}
