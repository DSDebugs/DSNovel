import DSCore
import DSStorage
import Foundation
import SQLite3
import XCTest

final class DSStoragePackageTests: XCTestCase {
    func testInMemoryContainerPersistenceRoundTrip() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let book = BookSummaryDTO(id: "pkg-b1", sourceID: "s1", bookURL: "https://e.com/b1", title: "测试书")
        try await engine.upsertBook(book, addToShelf: true)
        let shelf = try await engine.fetchShelfBooks()
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf.first?.id, "pkg-b1")
    }

    func testPaginatedDownloadsHandlesZeroAndMultiPage() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        for i in 0..<25 {
            try await engine.upsertDownload(DownloadRecordSnapshot(
                id: "dl-\(i)", bookID: "b1", bookTitle: "书", sourceID: "s1",
                chapterID: "c-\(i)", chapterIndex: i, chapterTitle: "章\(i)", chapterURL: "https://e.com/\(i)",
                kind: i % 2 == 0 ? .manual : .precache, state: .queued
            ))
        }
        let page10 = try await engine.fetchAllDownloadsPaginated(pageSize: 10)
        let pageZero = try await engine.fetchAllDownloadsPaginated(pageSize: 0)
        XCTAssertEqual(Set(page10.map(\.id)).count, 25)
        XCTAssertEqual(page10.count, 25)
        XCTAssertEqual(pageZero.count, 25)
    }

    func testChapterCacheStoreSaveLoadAndRemove() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DSStoragePkgCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChapterCacheStore(baseDirectory: dir)
        let chapters = [ChapterDTO(id: "c1", index: 0, title: "序章", url: "https://e.com/0")]
        try await store.saveChapters(chapters, bookID: "b1")
        let loaded = await store.loadChapters(bookID: "b1")
        XCTAssertEqual(loaded?.count, 1)
        await store.removeChapters(bookID: "b1")
        let afterRemove = await store.loadChapters(bookID: "b1")
        XCTAssertNil(afterRemove)
    }

    func testStoreBackupManagerCreateVerifyAndRestore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DSStoragePkgBak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let storeURL = dir.appendingPathComponent("DSNovelV3.store")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT); INSERT INTO kv VALUES ('ver','1');", nil, nil, nil), SQLITE_OK)

        let manager = StoreBackupManager(storeURL: storeURL, maxBackups: 5)
        let backup = try await manager.createBackup()
        let isValid = await manager.verifySQLiteIntegrity(at: backup.url)
        XCTAssertTrue(isValid)
        if let handle = db {
            sqlite3_close(handle)
            db = nil
        }
        try await manager.restoreBackup(backup)
        let restoredValid = await manager.verifySQLiteIntegrity(at: storeURL)
        XCTAssertTrue(restoredValid)
    }
}
