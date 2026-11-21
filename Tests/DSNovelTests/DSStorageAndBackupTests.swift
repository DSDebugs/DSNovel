import DSCore
import DSStorage
import Foundation
import XCTest

final class DSStorageAndBackupTests: XCTestCase {
    func testShelfAndHistoryIsolationAndDurationGuard() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        let book = BookSummaryDTO(id: "src::b1", sourceID: "src", bookURL: "https://example.com/b1", title: "测试有声书")
        let ch = ChapterDTO(id: "c1", index: 0, title: "第一章", url: "https://example.com/c1")

        try await engine.upsertBook(book, addToShelf: true)
        await engine.saveProgress(book: book, chapter: ch, positionMs: 15_000, durationMs: 120_000, isFinished: false, overrideFinished: false)

        // durationMs == 0 绝不覆盖已有正总时长
        await engine.saveProgress(book: book, chapter: ch, positionMs: 25_000, durationMs: 0, isFinished: false, overrideFinished: false)
        let prog = await engine.loadChapterProgress(bookID: book.id, chapterID: ch.id)
        XCTAssertEqual(prog?.positionMs, 25_000)
        XCTAssertEqual(prog?.durationMs, 120_000)

        // 移出书架不影响收听历史
        try await engine.setInShelf(bookID: book.id, inShelf: false)
        let shelf = try await engine.fetchShelfBooks()
        let history = try await engine.fetchHistoryBooks()
        XCTAssertTrue(shelf.isEmpty)
        XCTAssertEqual(history.count, 1)
    }

    func testSourceUpsertPreservesUserConfig() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        let v1 = SourceMetaDTO(id: "s1", name: "测试源", version: "1.0", isEnabled: false, isPinned: true, groupName: "我的精选")
        try await engine.upsertSource(meta: v1, scriptBody: "var a=1;", isBundled: false)

        let v2 = SourceMetaDTO(id: "s1", name: "测试源新版", version: "2.0", isEnabled: true, isPinned: false, groupName: "默认分组")
        try await engine.upsertSource(meta: v2, scriptBody: "var a=2;", isBundled: false)

        let all = try await engine.fetchAllSources()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.meta.version, "2.0")
        XCTAssertEqual(all.first?.meta.isEnabled, false)
        XCTAssertEqual(all.first?.meta.isPinned, true)
        XCTAssertEqual(all.first?.meta.groupName, "我的精选")
    }

    func testChapterCacheMagicHeaderAndCorruptRecovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSCacheTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ChapterCacheStore(baseDirectory: tempDir)
        let chapters = (0..<50).map { ChapterDTO(id: "ch-\($0)", index: $0, title: "第\($0 + 1)章", url: "https://example.com/\($0)") }
        try await store.saveChapters(chapters, bookID: "book-magic")

        let loaded = await store.loadChapters(bookID: "book-magic")
        XCTAssertEqual(loaded?.count, 50)

        // 注入损坏无魔数头数据：必须删文件并返回 nil，绝不返回空 [] 死锁
        let cacheFile = tempDir
            .appendingPathComponent("ChapterCache", isDirectory: true)
            .appendingPathComponent("\(DSCrypto.sha256Hex("book-magic")).dscache")
        try Data("BROKEN_NO_MAGIC_PAYLOAD".utf8).write(to: cacheFile)

        let afterCorrupt = await store.loadChapters(bookID: "book-magic")
        XCTAssertNil(afterCorrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testLibraryBackupCodecRoundTrip() throws {
        let payload = LibraryBackupPayload(books: [
            .init(
                id: "s::1", sourceID: "s", sourceName: "源", bookURL: "https://example.com/1",
                title: "三体", author: "刘慈欣", narrator: "王明军", coverURL: "",
                inShelf: true, isPinned: true, shelfGroupName: "科幻",
                lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastChapterIndex: 3, lastChapterTitle: "第四章", lastPositionMs: 42_000,
                skipConfig: SkipConfigDTO(introSeconds: 15, outroSeconds: 10)
            )
        ])
        let encoded = try LibraryBackupCodec.encode(payload)
        let decoded = try LibraryBackupCodec.decode(encoded)
        XCTAssertEqual(decoded.books.count, 1)
        XCTAssertEqual(decoded.books.first?.skipConfig.introSeconds, 15)
        XCTAssertEqual(decoded.books.first?.skipConfig.outroSeconds, 10)
    }

    @MainActor
    func testIsolatedAppSettingsStoreDoesNotPolluteStandardDefaults() {
        let suiteName = "com.dsnovel.v3.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.playbackRate = 1.75
        settings.nightDimEnabled = true
        XCTAssertEqual(AppSettingsStore(defaults: defaults).playbackRate, 1.75)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).nightDimEnabled)
    }
}
