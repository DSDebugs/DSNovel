import DSCore
import Foundation
import XCTest

final class DSCoreMatrixTests: XCTestCase {

    func testAudioQualityTier_auto_DisplayAndBadge() {
        let t = AudioQualityTier.auto
        XCTAssertEqual(t.displayName, "自适应")
        XCTAssertFalse(t.badgeLabel.isEmpty)
        XCTAssertEqual(t.id, "auto")
    }

    func testAudioQualityTier_saver_DisplayAndBadge() {
        let t = AudioQualityTier.saver
        XCTAssertEqual(t.displayName, "标准")
        XCTAssertFalse(t.badgeLabel.isEmpty)
        XCTAssertEqual(t.id, "saver")
    }

    func testAudioQualityTier_standard_DisplayAndBadge() {
        let t = AudioQualityTier.standard
        XCTAssertEqual(t.displayName, "高清")
        XCTAssertFalse(t.badgeLabel.isEmpty)
        XCTAssertEqual(t.id, "standard")
    }

    func testAudioQualityTier_high_DisplayAndBadge() {
        let t = AudioQualityTier.high
        XCTAssertEqual(t.displayName, "超清")
        XCTAssertFalse(t.badgeLabel.isEmpty)
        XCTAssertEqual(t.id, "high")
    }

    func testSkipConfigClampingCase_0() {
        let cfg = SkipConfigDTO(introSeconds: 0, outroSeconds: 0)
        XCTAssertEqual(cfg.introSeconds, 0)
        XCTAssertEqual(cfg.outroSeconds, 0)
        XCTAssertEqual(cfg.isEnabled, false)
    }

    func testSkipConfigClampingCase_1() {
        let cfg = SkipConfigDTO(introSeconds: -10, outroSeconds: -5)
        XCTAssertEqual(cfg.introSeconds, 0)
        XCTAssertEqual(cfg.outroSeconds, 0)
        XCTAssertEqual(cfg.isEnabled, false)
    }

    func testSkipConfigClampingCase_2() {
        let cfg = SkipConfigDTO(introSeconds: 15, outroSeconds: 0)
        XCTAssertEqual(cfg.introSeconds, 15)
        XCTAssertEqual(cfg.outroSeconds, 0)
        XCTAssertEqual(cfg.isEnabled, true)
    }

    func testSkipConfigClampingCase_3() {
        let cfg = SkipConfigDTO(introSeconds: 0, outroSeconds: 20)
        XCTAssertEqual(cfg.introSeconds, 0)
        XCTAssertEqual(cfg.outroSeconds, 20)
        XCTAssertEqual(cfg.isEnabled, true)
    }

    func testSkipConfigClampingCase_4() {
        let cfg = SkipConfigDTO(introSeconds: 999, outroSeconds: 888)
        XCTAssertEqual(cfg.introSeconds, 600)
        XCTAssertEqual(cfg.outroSeconds, 600)
        XCTAssertEqual(cfg.isEnabled, true)
    }

    func testSkipConfigClampingCase_5() {
        let cfg = SkipConfigDTO(introSeconds: 600, outroSeconds: 600)
        XCTAssertEqual(cfg.introSeconds, 600)
        XCTAssertEqual(cfg.outroSeconds, 600)
        XCTAssertEqual(cfg.isEnabled, true)
    }

    func testPlaybackState_IdlePauseStaysIdle() {
        XCTAssertEqual(PlaybackState.idle.applyingPauseOrInterrupt(), .idle)
    }
    func testPlaybackState_PlayingPauseBecomesPaused() {
        XCTAssertEqual(PlaybackState.playing(generation: 3).applyingPauseOrInterrupt(), .paused(generation: 3))
    }
    func testPlaybackState_PausedResumeBecomesPlaying() {
        XCTAssertEqual(PlaybackState.paused(generation: 4).applyingResume(), .playing(generation: 4))
    }
    func testPlaybackState_EndedResumeBecomesPlaying() {
        XCTAssertEqual(PlaybackState.ended(generation: 5).applyingResume(), .playing(generation: 5))
    }
    func testPlaybackState_BufferingFalseResumeSetsTrue() {
        XCTAssertEqual(
            PlaybackState.buffering(generation: 6, shouldPlayWhenReady: false).applyingResume(),
            .buffering(generation: 6, shouldPlayWhenReady: true)
        )
    }
    func testPlaybackState_FailedPauseStaysFailed() {
        let s = PlaybackState.failed(generation: 8, message: "err")
        XCTAssertEqual(s.applyingPauseOrInterrupt(), s)
    }
    func testPlaybackState_GenerationAccessor() {
        XCTAssertEqual(PlaybackState.idle.generation, 0)
        XCTAssertEqual(PlaybackState.playing(generation: 42).generation, 42)
        XCTAssertEqual(PlaybackState.failed(generation: 99, message: "x").generation, 99)
    }
    func testPlaybackState_ShouldPlayWhenReadyFlags() {
        XCTAssertFalse(PlaybackState.idle.shouldPlayWhenReady)
        XCTAssertTrue(PlaybackState.playing(generation: 1).shouldPlayWhenReady)
        XCTAssertFalse(PlaybackState.paused(generation: 1).shouldPlayWhenReady)
        XCTAssertTrue(PlaybackState.buffering(generation: 1, shouldPlayWhenReady: true).shouldPlayWhenReady)
        XCTAssertFalse(PlaybackState.buffering(generation: 1, shouldPlayWhenReady: false).shouldPlayWhenReady)
    }

    func testDownloadStateTransition_queued_to_resolving() {
        XCTAssertTrue(DownloadState.queued.canTransition(to: .resolving))
    }

    func testDownloadStateTransition_queued_to_paused() {
        XCTAssertTrue(DownloadState.queued.canTransition(to: .paused))
    }

    func testDownloadStateTransition_queued_to_cancelled() {
        XCTAssertTrue(DownloadState.queued.canTransition(to: .cancelled))
    }

    func testDownloadStateTransition_queued_to_completed() {
        XCTAssertTrue(DownloadState.queued.canTransition(to: .completed))
    }

    func testDownloadStateTransition_resolving_to_downloading() {
        XCTAssertTrue(DownloadState.resolving.canTransition(to: .downloading))
    }

    func testDownloadStateTransition_resolving_to_failed() {
        XCTAssertTrue(DownloadState.resolving.canTransition(to: .failed))
    }

    func testDownloadStateTransition_resolving_to_completed() {
        XCTAssertFalse(DownloadState.resolving.canTransition(to: .completed))
    }

    func testDownloadStateTransition_downloading_to_completed() {
        XCTAssertTrue(DownloadState.downloading.canTransition(to: .completed))
    }

    func testDownloadStateTransition_downloading_to_paused() {
        XCTAssertTrue(DownloadState.downloading.canTransition(to: .paused))
    }

    func testDownloadStateTransition_downloading_to_failed() {
        XCTAssertTrue(DownloadState.downloading.canTransition(to: .failed))
    }

    func testDownloadStateTransition_paused_to_queued() {
        XCTAssertTrue(DownloadState.paused.canTransition(to: .queued))
    }

    func testDownloadStateTransition_paused_to_completed() {
        XCTAssertFalse(DownloadState.paused.canTransition(to: .completed))
    }

    func testDownloadStateTransition_completed_to_queued() {
        XCTAssertFalse(DownloadState.completed.canTransition(to: .queued))
    }

    func testDownloadStateTransition_cancelled_to_queued() {
        XCTAssertTrue(DownloadState.cancelled.canTransition(to: .queued))
    }

    func testResumeDataInvalidation_HTTP_200() {
        XCTAssertFalse(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 200))
    }

    func testResumeDataInvalidation_HTTP_401() {
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 401))
    }

    func testResumeDataInvalidation_HTTP_403() {
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 403))
    }

    func testResumeDataInvalidation_HTTP_404() {
        XCTAssertFalse(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 404))
    }

    func testResumeDataInvalidation_HTTP_410() {
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 410))
    }

    func testResumeDataInvalidation_HTTP_416() {
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 416))
    }

    func testResumeDataInvalidation_HTTP_429() {
        XCTAssertFalse(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 429))
    }

    func testResumeDataInvalidation_HTTP_500() {
        XCTAssertFalse(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 500))
    }

    func testResumeDataInvalidation_HTTP_503() {
        XCTAssertFalse(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 503))
    }

    func testCanonicalDownloadPathDeterministic() {
        let p1 = DownloadRecordSnapshot.canonicalRelativePath(bookID: "book/1", chapterID: "ch/2", ext: ".MP3!")
        let p2 = DownloadRecordSnapshot.canonicalRelativePath(bookID: "book/1", chapterID: "ch/2", ext: "mp3")
        XCTAssertEqual(p1, p2)
        XCTAssertTrue(p1.hasSuffix(".mp3"))
        XCTAssertFalse(p1.contains(".."))
    }
    func testURLSafeBase64WithoutPadding() {
        let encoded = DSCrypto.base64Encode("hello?world/test+123").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(DSCrypto.base64Decode(encoded), "hello?world/test+123")
    }
    func testAudioStreamBitrateBadgeFormatting() {
        let s1 = AudioStreamDTO(url: URL(string: "https://example.com/a.m4a")!, qualityTier: .high, bitrateKbps: 128)
        XCTAssertEqual(s1.displayBitrateBadge, "超清")
        let s2 = AudioStreamDTO(url: URL(string: "https://example.com/b.m4a")!, qualityTier: .saver, bitrateKbps: nil)
        XCTAssertEqual(s2.displayBitrateBadge, "标准")
    }
    func testDiagnosticRingBufferCapsEntries() async {
        let store = DSDiagnosticLogStore(maxEntries: 50)
        for i in 0..<80 {
            await store.record(category: .app, level: "INFO", message: "msg-\(i)")
        }
        let snap = await store.snapshot(limit: 100)
        XCTAssertEqual(snap.count, 50)
        XCTAssertEqual(snap.last?.message, "msg-79")
    }
    func testDiagnosticExportIncludesHeader() async {
        let store = DSDiagnosticLogStore()
        await store.record(category: .network, level: "WARN", message: "Cookie: sid=topsecret")
        let report = await store.exportSanitizedReport(appVersion: "3.0.0")
        XCTAssertTrue(report.contains("DSNovel v3"))
        XCTAssertFalse(report.contains("topsecret"))
    }
    func testZIPReaderRejectsOverflowEntryCount() {
        let reader = ZIPArchiveReader()
        let eocd = Data([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try reader.readAll(from: eocd))
    }
}
