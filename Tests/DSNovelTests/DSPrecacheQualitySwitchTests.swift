import DSCore
import DSPlayback
import Foundation
import XCTest

private final class QualitySwitchStubResolver: AudioResolving, @unchecked Sendable {
    private let lock = NSLock()
    var resolvedQualities: [AudioQualityTier] = []
    var shouldFail = false

    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool
    ) async throws -> AudioStreamDTO {
        let fail = lock.withLock { () -> Bool in
            resolvedQualities.append(preferredQuality)
            return shouldFail
        }
        if fail {
            throw NSError(domain: "DSPrecacheQualitySwitchTests", code: -1009, userInfo: [NSLocalizedDescriptionKey: "离线模拟"])
        }
        return AudioStreamDTO(
            url: URL(string: "https://example.com/\(chapter.id)_\(preferredQuality.rawValue).m4a")!,
            qualityTier: preferredQuality,
            isHLS: false
        )
    }
}

private actor QualitySwitchStubLocator: OfflineAudioLocating {
    private var assets: [String: LocalAudioAsset] = [:]
    private(set) var invalidatedBooks: [(bookID: String, chapterID: String?)] = []

    func setAsset(_ asset: LocalAudioAsset, bookID: String, chapterID: String) {
        assets["\(bookID)_\(chapterID)"] = asset
    }

    func localAudioURL(bookID: String, chapterID: String) async -> URL? {
        assets["\(bookID)_\(chapterID)"]?.url
    }

    func isDownloaded(bookID: String, chapterID: String) async -> Bool {
        assets["\(bookID)_\(chapterID)"] != nil
    }

    func localAudioAsset(bookID: String, chapterID: String) async -> LocalAudioAsset? {
        assets["\(bookID)_\(chapterID)"]
    }

    func invalidatePrecache(bookID: String, chapterID: String?) async {
        invalidatedBooks.append((bookID, chapterID))
        for (key, asset) in assets where asset.isPrecache {
            if let chapterID {
                if key == "\(bookID)_\(chapterID)" { assets.removeValue(forKey: key) }
            } else if key.hasPrefix("\(bookID)_") {
                assets.removeValue(forKey: key)
            }
        }
    }
}

private struct QualitySwitchStubProgress: PlaybackProgressPersisting {
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

final class DSPrecacheQualitySwitchTests: XCTestCase {
    @MainActor
    func testPrecacheSwitchesQualityImmediatelyAndInvalidatesBookPrecache() async {
        let resolver = QualitySwitchStubResolver()
        let locator = QualitySwitchStubLocator()
        let book = BookSummaryDTO(id: "b-pq", sourceID: "src", bookURL: "https://example.com/b", title: "缓存音质测试")
        let chapter = ChapterDTO(id: "c-12", index: 11, title: "第12章", url: "https://example.com/c12")
        let cacheURL = URL(fileURLWithPath: "/tmp/precache_c12.m4a")
        await locator.setAsset(LocalAudioAsset(url: cacheURL, isPrecache: true, qualityTier: .standard), bookID: book.id, chapterID: chapter.id)

        let coordinator = PlaybackCoordinator(
            audioResolver: resolver,
            offlineLocator: locator,
            progressStore: QualitySwitchStubProgress(),
            logger: DSDiagnosticLogStore()
        )
        defer { coordinator.tearDown() }
        coordinator.allowUltraHighQuality = true
        coordinator.preferredQuality = .standard
        coordinator.play(book: book, chapters: [chapter], startIndex: 0, autoPlay: false)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coordinator.activeLocalSourceKind, .precache)
        XCTAssertFalse(coordinator.isPlayingDownloadedOfflineAudio)

        coordinator.switchQuality(.high)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(coordinator.activeLocalSourceKind, .online)
        XCTAssertEqual(coordinator.activeStream?.qualityTier, .high)
        let remaining = await locator.localAudioAsset(bookID: book.id, chapterID: chapter.id)
        XCTAssertNil(remaining)
    }

    @MainActor
    func testManualDownloadedAudioStaysDownloadedAndUntouched() async {
        let resolver = QualitySwitchStubResolver()
        let locator = QualitySwitchStubLocator()
        let book = BookSummaryDTO(id: "b-dl", sourceID: "src", bookURL: "https://example.com/b2", title: "下载音质测试")
        let chapter = ChapterDTO(id: "c-1", index: 0, title: "第1章", url: "https://example.com/c1")
        let dlURL = URL(fileURLWithPath: "/tmp/manual_c1.m4a")
        await locator.setAsset(LocalAudioAsset(url: dlURL, isPrecache: false, qualityTier: .standard), bookID: book.id, chapterID: chapter.id)

        let coordinator = PlaybackCoordinator(
            audioResolver: resolver,
            offlineLocator: locator,
            progressStore: QualitySwitchStubProgress(),
            logger: DSDiagnosticLogStore()
        )
        defer { coordinator.tearDown() }
        coordinator.preferredQuality = .high
        coordinator.play(book: book, chapters: [chapter], startIndex: 0, autoPlay: false)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coordinator.activeLocalSourceKind, .downloaded)
        XCTAssertTrue(coordinator.isPlayingDownloadedOfflineAudio)
        XCTAssertEqual(coordinator.activeStream?.url, dlURL)
        XCTAssertTrue(resolver.resolvedQualities.isEmpty)
    }
}
