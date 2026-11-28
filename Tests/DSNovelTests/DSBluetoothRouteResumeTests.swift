import DSCore
import DSPlayback
import Foundation
import XCTest

private struct BluetoothResumeStubResolver: AudioResolving {
    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool
    ) async throws -> AudioStreamDTO {
        AudioStreamDTO(url: URL(string: "https://example.com/audio.m4a")!, qualityTier: preferredQuality, isHLS: false)
    }
}

private struct BluetoothResumeStubProgressStore: PlaybackProgressPersisting {
    func saveProgress(
        book: BookSummaryDTO,
        chapter: ChapterDTO,
        positionMs: Int,
        durationMs: Int,
        isFinished: Bool,
        overrideFinished: Bool
    ) async {}
    func loadChapterProgress(bookID: String, chapterID: String) async -> (positionMs: Int, durationMs: Int, isFinished: Bool)? { nil }
    func loadBookSkipConfig(bookID: String) async -> SkipConfigDTO { SkipConfigDTO() }
    func saveBookSkipConfig(bookID: String, config: SkipConfigDTO) async {}
}

final class DSBluetoothRouteResumeTests: XCTestCase {
    @MainActor
    private func makeCoordinator() -> PlaybackCoordinator {
        let coordinator = PlaybackCoordinator(
            audioResolver: BluetoothResumeStubResolver(),
            progressStore: BluetoothResumeStubProgressStore(),
            logger: DSDiagnosticLogStore()
        )
        let book = BookSummaryDTO(id: "b-bt", sourceID: "src", bookURL: "https://example.com/b", title: "测试有声书")
        let chapters = [ChapterDTO(id: "c1", index: 0, title: "第1章", url: "https://example.com/c1")]
        coordinator.play(book: book, chapters: chapters, startIndex: 0, autoPlay: true)
        return coordinator
    }

    @MainActor
    func testUnplugWhilePlayingAndReconnectResumesWithToggleDebounce() async {
        let coordinator = makeCoordinator()
        defer { coordinator.tearDown() }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.handleAudioRouteUnplugged(now: t0)
        XCTAssertFalse(coordinator.state.isPlaying)
        XCTAssertEqual(coordinator.pausedByRouteRemovalAt, t0)

        let t1 = t0.addingTimeInterval(12)
        coordinator.handleAudioRouteReconnected(
            isOtherAudioPlaying: false,
            routeHasPersonalAudio: true,
            debounceNanoseconds: 0,
            nowProvider: { t1 }
        )
        await coordinator.routeReconnectTask?.value

        XCTAssertTrue(coordinator.state.shouldPlayWhenReady)
        XCTAssertNil(coordinator.pausedByRouteRemovalAt)
        XCTAssertEqual(coordinator.lastAutoResumeFromRouteAt, t1)

        // 0.8s 内耳机补发 togglePlayPauseCommand 应防抖忽略，避免反手暂停
        coordinator.handleRemoteTogglePlayPause(now: t1.addingTimeInterval(0.8))
        XCTAssertTrue(coordinator.state.shouldPlayWhenReady)
    }

    @MainActor
    func testManualPausePreventsAutoResume() async {
        let coordinator = makeCoordinator()
        defer { coordinator.tearDown() }

        coordinator.pause()
        coordinator.handleAudioRouteUnplugged(now: Date())
        XCTAssertNil(coordinator.pausedByRouteRemovalAt)

        coordinator.handleAudioRouteReconnected(
            isOtherAudioPlaying: false,
            routeHasPersonalAudio: true,
            debounceNanoseconds: 0
        )
        await coordinator.routeReconnectTask?.value
        XCTAssertFalse(coordinator.state.shouldPlayWhenReady)
    }

    @MainActor
    func testExpiredWindowAndOtherAudioGuardPreventAutoResume() async {
        let coordinator = makeCoordinator()
        defer { coordinator.tearDown() }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.handleAudioRouteUnplugged(now: t0)

        // 其他 App 正在播音时跳过续播
        coordinator.handleAudioRouteReconnected(
            isOtherAudioPlaying: true,
            routeHasPersonalAudio: true,
            debounceNanoseconds: 0,
            nowProvider: { t0.addingTimeInterval(20) }
        )
        await coordinator.routeReconnectTask?.value
        XCTAssertFalse(coordinator.state.shouldPlayWhenReady)

        // 超过 10 分钟窗口后跳过续播
        coordinator.handleAudioRouteReconnected(
            isOtherAudioPlaying: false,
            routeHasPersonalAudio: true,
            debounceNanoseconds: 0,
            nowProvider: { t0.addingTimeInterval(601) }
        )
        await coordinator.routeReconnectTask?.value
        XCTAssertFalse(coordinator.state.shouldPlayWhenReady)
    }
}
