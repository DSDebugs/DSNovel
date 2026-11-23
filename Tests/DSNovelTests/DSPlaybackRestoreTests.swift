import DSCore
import DSPlayback
import DSStorage
import Foundation
import Testing

private actor StubRestoreAudioResolver: AudioResolving {
    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool
    ) async throws -> AudioStreamDTO {
        AudioStreamDTO(url: URL(fileURLWithPath: "/tmp/stub.m4a"), headers: [:], qualityTier: preferredQuality)
    }

    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool,
        bypassCache: Bool
    ) async throws -> AudioStreamDTO {
        AudioStreamDTO(url: URL(fileURLWithPath: "/tmp/stub.m4a"), headers: [:], qualityTier: preferredQuality)
    }
}

private actor StubRestoreProgressStore: PlaybackProgressPersisting {
    func saveProgress(
        book: BookSummaryDTO,
        chapter: ChapterDTO,
        positionMs: Int,
        durationMs: Int,
        isFinished: Bool,
        overrideFinished: Bool
    ) async {}

    func loadChapterProgress(bookID: String, chapterID: String) async -> (positionMs: Int, durationMs: Int, isFinished: Bool)? {
        nil
    }

    func loadBookSkipConfig(bookID: String) async -> SkipConfigDTO {
        SkipConfigDTO()
    }

    func saveBookSkipConfig(bookID: String, config: SkipConfigDTO) async {}
}

@Suite("DSPlayback 冷启动恢复最后播放书籍与章节测试")
struct DSPlaybackRestoreTests {
    @Test("PersistenceEngine.fetchLatestPlaybackSession 返回最近播放书籍与章节进度")
    func fetchLatestSessionFromPersistence() async throws {
        let storage = StorageContainerFactory.make(inMemoryOnly: true)
        let engine = PersistenceEngine.makeOffMain(modelContainer: storage.container)

        let book1 = BookSummaryDTO(id: "b1", sourceID: "s1", sourceName: "喜马拉雅", bookURL: "u1", title: "旧书")
        let book2 = BookSummaryDTO(id: "b2", sourceID: "s1", sourceName: "喜马拉雅", bookURL: "u2", title: "新书")
        let ch1 = ChapterDTO(id: "c1", index: 0, title: "第1章", url: "xm:1")
        let ch2 = ChapterDTO(id: "c5", index: 4, title: "第5章", url: "xm:5")

        await engine.saveProgress(book: book1, chapter: ch1, positionMs: 12_000, durationMs: 300_000, isFinished: false, overrideFinished: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        await engine.saveProgress(book: book2, chapter: ch2, positionMs: 45_000, durationMs: 600_000, isFinished: false, overrideFinished: false)

        let latest = await engine.fetchLatestPlaybackSession()
        #expect(latest?.book.id == "b2")
        #expect(latest?.chapterID == "c5")
        #expect(latest?.chapterIndex == 4)
        #expect(latest?.positionMs == 45_000)
        #expect(latest?.durationMs == 600_000)
    }

    @Test("PlaybackCoordinator.restoreSession 保持暂停态恢复并支持拖动与不覆盖已有播放")
    @MainActor
    func restoreSessionAndSeek() async {
        let resolver = StubRestoreAudioResolver()
        let store = StubRestoreProgressStore()
        let logger = DSDiagnosticLogStore()
        let coordinator = PlaybackCoordinator(audioResolver: resolver, progressStore: store, logger: logger)

        let book = BookSummaryDTO(id: "b2", sourceID: "s1", sourceName: "喜马拉雅", bookURL: "u2", title: "青山")
        let chapters = [
            ChapterDTO(id: "c0", index: 0, title: "第1章", url: "xm:10"),
            ChapterDTO(id: "c1", index: 1, title: "第2章", url: "xm:11")
        ]

        coordinator.restoreSession(book: book, chapters: chapters, chapterIndex: 1, positionMs: 90_000, durationMs: 480_000)
        #expect(coordinator.currentBook?.id == "b2")
        #expect(coordinator.chapters.count == 2)
        #expect(coordinator.currentChapterIndex == 1)
        #expect(coordinator.currentChapter?.id == "c1")
        #expect(!coordinator.state.isPlaying)
        #expect(coordinator.clock.currentSeconds == 90.0)
        #expect(coordinator.clock.durationSeconds == 480.0)

        let other = BookSummaryDTO(id: "b9", sourceID: "s1", sourceName: "喜马拉雅", bookURL: "u9", title: "其他书")
        coordinator.restoreSession(book: other, chapters: chapters, chapterIndex: 0, positionMs: 0, durationMs: 100_000)
        #expect(coordinator.currentBook?.id == "b2")

        coordinator.seek(to: 120.0)
        #expect(coordinator.clock.currentSeconds == 120.0)

        coordinator.tearDown()
    }
}
