import DSCore
import DSPlayback
import Foundation
import Testing

private struct BluetoothResumeStubResolver: AudioResolving {
    func resolveAudio(book: BookSummaryDTO, chapter: ChapterDTO, preferredQuality: AudioQualityTier) async throws -> ResolvedAudioDTO {
        ResolvedAudioDTO(url: "https://example.com/audio.m4a", headers: [:], quality: .high)
    }
}

private actor BluetoothResumeStubProgressStore: PlaybackProgressPersisting {
    func saveProgress(book: BookSummaryDTO, chapter: ChapterDTO, positionMs: Int, durationMs: Int, isFinished: Bool, overrideFinished: Bool) async {}
    func fetchProgress(bookID: String, chapterID: String) async -> ChapterProgressDTO? { nil }
    func fetchBookSkipConfig(bookID: String) async -> SkipConfigDTO? { nil }
    func saveBookSkipConfig(bookID: String, config: SkipConfigDTO) async {}
}

@Suite("蓝牙耳机摘下暂停与戴回自动续播闭环测试")
struct DSBluetoothRouteResumeTests {
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

    @Test("播放中摘下耳机自动暂停并记录标记，窗口内戴回自动续播且 1.5s 内防抖重复 toggle")
    @MainActor
    func unplugWhilePlayingAndReconnectResumesWithToggleDebounce() async {
        let coordinator = makeCoordinator()
        defer { coordinator.tearDown() }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.handleAudioRouteUnplugged(now: t0)
        #expect(!coordinator.state.isPlaying)
        #expect(coordinator.pausedByRouteRemovalAt == t0)

        let t1 = t0.addingTimeInterval(12)
        coordinator.handleAudioRouteReconnected(
            isOtherAudioPlaying: false,
            routeHasPersonalAudio: true,
            debounceNanoseconds: 0,
            nowProvider: { t1 }
        )
        await coordinator.routeReconnectTask?.value

        #expect(coordinator.state.shouldPlayWhenReady)
        #expect(coordinator.pausedByRouteRemovalAt == nil)
        #expect(coordinator.lastAutoResumeFromRouteAt == t1)

        // 0.8s 内耳机补发 togglePlayPauseCommand 应防抖忽略，避免反手暂停
        coordinator.handleRemoteTogglePlayPause(now: t1.addingTimeInterval(0.8))
        #expect(coordinator.state.shouldPlayWhenReady)
    }

    @Test("原本手动暂停时摘下再戴回，或摘下后手动操作，绝不误自动开播")
    @MainActor
    func manualPausePreventsAutoResume() async {
        let coordinator = makeCoordinator()
        defer { coordinator.tearDown() }

        coordinator.pause()
        coordinator.handleAudioRouteUnplugged(now: Date())
        #expect(coordinator.pausedByRouteRemovalAt == nil)

        coordinator.handleAudioRouteReconnected(
            isOtherAudioPlaying: false,
            routeHasPersonalAudio: true,
            debounceNanoseconds: 0
        )
        await coordinator.routeReconnectTask?.value
        #expect(!coordinator.state.shouldPlayWhenReady)
    }

    @Test("超过 10 分钟窗口或其他 App 正在播放时不自动抢声")
    @MainActor
    func expiredWindowAndOtherAudioGuardPreventAutoResume() async {
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
        #expect(!coordinator.state.shouldPlayWhenReady)

        // 超过 10 分钟窗口后跳过续播
        coordinator.handleAudioRouteReconnected(
            isOtherAudioPlaying: false,
            routeHasPersonalAudio: true,
            debounceNanoseconds: 0,
            nowProvider: { t0.addingTimeInterval(601) }
        )
        await coordinator.routeReconnectTask?.value
        #expect(!coordinator.state.shouldPlayWhenReady)
    }
}
