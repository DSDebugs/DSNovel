import XCTest
@testable import DSNovel

final class ChapterProgressStoreTests: XCTestCase {

    func testEvictsOldestEntriesAndKeepsLatest400() {
        let suiteName = "ChapterProgressTests_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bookID = "test_book_lru"
        for i in 1...600 {
            ChapterProgressStore.save(
                bookID: bookID,
                chapterID: "ep_\(i)",
                positionMs: i * 1000,
                now: TimeInterval(1_700_000_000 + i),
                defaults: defaults
            )
        }

        let loaded = ChapterProgressStore.loadAll(for: bookID, defaults: defaults)
        XCTAssertEqual(loaded.count, 400)
        XCTAssertNil(loaded["ep_1"])
        XCTAssertNil(loaded["ep_200"])
        XCTAssertEqual(loaded["ep_201"], 201_000)
        XCTAssertEqual(loaded["ep_600"], 600_000)
    }

    func testLegacyDictionaryCompatibilityAndDuplicateUpdate() {
        let suiteName = "ChapterProgressLegacy_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bookID = "legacy_book"
        ChapterProgressStore.save(bookID: bookID, chapterID: "ch_1", positionMs: 12_000, now: 100, defaults: defaults)
        ChapterProgressStore.save(bookID: bookID, chapterID: "ch_1", positionMs: 45_000, now: 200, defaults: defaults)

        let loaded = ChapterProgressStore.loadAll(for: bookID, defaults: defaults)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded["ch_1"], 45_000)
    }
}
