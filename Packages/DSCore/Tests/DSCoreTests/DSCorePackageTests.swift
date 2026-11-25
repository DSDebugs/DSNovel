import DSCore
import Foundation
import XCTest

final class DSCorePackageTests: XCTestCase {
    func testPlaybackStateLifecycleTransitions() {
        XCTAssertEqual(PlaybackState.idle.generation, 0)
        XCTAssertFalse(PlaybackState.idle.isPlaying)

        let buffering = PlaybackState.buffering(generation: 2, shouldPlayWhenReady: true)
        XCTAssertEqual(buffering.applyingReadyToPlay(for: 2), .playing(generation: 2))
        XCTAssertEqual(buffering.applyingReadyToPlay(for: 1), buffering)

        let interrupted = buffering.applyingPauseOrInterrupt()
        XCTAssertEqual(interrupted, .buffering(generation: 2, shouldPlayWhenReady: false))
        XCTAssertEqual(interrupted.applyingReadyToPlay(for: 2), .paused(generation: 2))
        XCTAssertEqual(PlaybackState.ended(generation: 2).applyingResume(), .playing(generation: 2))
    }

    func testDownloadStateTerminalAndTransitionMatrix() {
        XCTAssertTrue(DownloadState.completed.isTerminal)
        XCTAssertFalse(DownloadState.cancelled.isTerminal)
        XCTAssertTrue(DownloadState.queued.canTransition(to: .completed))
        XCTAssertFalse(DownloadState.completed.canTransition(to: .completed))
        XCTAssertFalse(DownloadState.completed.canTransition(to: .queued))
        XCTAssertTrue(DownloadState.cancelled.canTransition(to: .queued))
    }

    func testDownloadRetryPolicyBackoffAndResumeInvalidation() {
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 0, httpStatus: 500), 2.0)
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 1, httpStatus: 429), 12.0)
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 2, httpStatus: 503), 28.0)
        XCTAssertNil(DownloadRetryPolicy.delaySeconds(retryCount: 3, httpStatus: 500))
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 403))
        XCTAssertTrue(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 416))
        XCTAssertFalse(DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: 500))
    }

    func testDSCryptoDeterministicHashingAndBase64() {
        XCTAssertEqual(DSCrypto.md5Hex("dsnovel"), "bba61acffd158eb1a2771985139af09d")
        XCTAssertEqual(DSCrypto.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        let encoded = DSCrypto.base64Encode("有声书v3")
        XCTAssertEqual(DSCrypto.base64Decode(encoded), "有声书v3")
    }

    func testSkipConfigClampingBounds() {
        let clampedLow = SkipConfigDTO(introSeconds: -20, outroSeconds: -1)
        XCTAssertEqual(clampedLow.introSeconds, 0)
        XCTAssertEqual(clampedLow.outroSeconds, 0)
        XCTAssertFalse(clampedLow.isEnabled)

        let clampedHigh = SkipConfigDTO(introSeconds: 999, outroSeconds: 700)
        XCTAssertEqual(clampedHigh.introSeconds, 600)
        XCTAssertEqual(clampedHigh.outroSeconds, 600)
        XCTAssertTrue(clampedHigh.isEnabled)
    }
}
