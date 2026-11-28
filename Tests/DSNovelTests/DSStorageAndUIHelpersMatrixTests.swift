@testable import DSNovel
import DSCore
import DSDesignSystem
import DSStorage
import Foundation
import SQLite3
import XCTest

final class DSStorageAndUIHelpersMatrixTests: XCTestCase {

    func testBookTitleFormatter_cleanBracketFree() {
        XCTAssertEqual(BookTitleFormatter.cleanTitle("【免费全集】凡人修仙传"), "凡人修仙传")
    }

    func testBookTitleFormatter_cleanBracketAudio() {
        XCTAssertEqual(BookTitleFormatter.cleanTitle("【多人有声剧】三体"), "三体")
    }

    func testBookTitleFormatter_cleanSquareBracket() {
        XCTAssertEqual(BookTitleFormatter.cleanTitle("[免费]雪中悍刀行"), "雪中悍刀行")
    }

    func testBookTitleFormatter_preserveNormal() {
        XCTAssertEqual(BookTitleFormatter.cleanTitle("明朝那些事儿"), "明朝那些事儿")
    }

    func testBookTitleFormatter_trimWhitespace() {
        XCTAssertEqual(BookTitleFormatter.cleanTitle("  诡秘之主  "), "诡秘之主")
    }

    func testBookTitleFormatter_fallbackIfAllNoise() {
        XCTAssertEqual(BookTitleFormatter.cleanTitle("【免费全集】"), "【免费全集】")
    }

    func testNarratorDisplay_both() {
        XCTAssertEqual(BookTitleFormatter.narratorDisplay(author: "刘慈欣", narrator: "王明军"), "刘慈欣 · 王明军 播讲")
    }

    func testNarratorDisplay_narratorOnly() {
        XCTAssertEqual(BookTitleFormatter.narratorDisplay(author: "", narrator: "大灰狼"), "大灰狼 播讲")
    }

    func testNarratorDisplay_authorOnly() {
        XCTAssertEqual(BookTitleFormatter.narratorDisplay(author: "忘语", narrator: ""), "忘语")
    }

    func testNarratorDisplay_emptyBoth() {
        XCTAssertEqual(BookTitleFormatter.narratorDisplay(author: "", narrator: ""), "")
    }

    @MainActor
    func testAppRouterSelectTabAndPopToRoot() {
        let router = AppRouter()
        router.selectTab(.discover)
        XCTAssertEqual(router.selectedTab, .discover)
        router.push(.sources, on: .discover)
        XCTAssertEqual(router.discoverPath.count, 1)
        router.selectTab(.discover)
        XCTAssertTrue(router.discoverPath.isEmpty)
        router.selectTab(.discover)
        XCTAssertEqual(router.scrollToTopTrigger[.discover], 1)
    }

    @MainActor
    func testAppRouterIndependentTabStacks() {
        let router = AppRouter()
        router.push(.history, on: .library)
        router.push(.downloads, on: .me)
        XCTAssertEqual(router.libraryPath.count, 1)
        XCTAssertEqual(router.mePath.count, 1)
        XCTAssertTrue(router.discoverPath.isEmpty)
        router.popToRoot(on: .me)
        XCTAssertTrue(router.mePath.isEmpty)
        XCTAssertEqual(router.libraryPath.count, 1)
    }

    @MainActor
    func testBannerCoordinatorSheetNestingPreventsDoubleBanner() {
        let banner = DSBannerCoordinator()
        XCTAssertFalse(banner.isSheetPresenting)
        banner.registerSheetAppear()
        banner.registerSheetAppear()
        XCTAssertTrue(banner.isSheetPresenting)
        banner.registerSheetDisappear()
        XCTAssertTrue(banner.isSheetPresenting)
        banner.registerSheetDisappear()
        XCTAssertFalse(banner.isSheetPresenting)
    }

    @MainActor
    func testBannerCoordinatorShowAndDismiss() {
        let banner = DSBannerCoordinator()
        banner.show("操作成功", tone: .success, duration: 10)
        XCTAssertEqual(banner.current?.text, "操作成功")
        banner.dismiss()
        XCTAssertNil(banner.current)
    }

    func testLibraryOrganizerFilterByTitleAuthorNarrator() {
        let books = [
            BookSummaryDTO(id: "1", sourceID: "s", bookURL: "u1", title: "三体", author: "刘慈欣", narrator: "王明军"),
            BookSummaryDTO(id: "2", sourceID: "s", bookURL: "u2", title: "凡人修仙传", author: "忘语", narrator: "大灰狼"),
        ]
        XCTAssertEqual(LibraryOrganizerHelper.filterBooks(books, keyword: "").count, 2)
        XCTAssertEqual(LibraryOrganizerHelper.filterBooks(books, keyword: "刘慈欣").map(\.id), ["1"])
        XCTAssertEqual(LibraryOrganizerHelper.filterBooks(books, keyword: "大灰狼").map(\.id), ["2"])
        XCTAssertEqual(LibraryOrganizerHelper.filterBooks(books, keyword: "不存在").count, 0)
    }

    @MainActor
    func testPlayerChapterListModelFilterAndReverse() {
        let chapters = [
            ChapterDTO(id: "1", index: 0, title: "第一章 启程", url: "u1"),
            ChapterDTO(id: "2", index: 1, title: "第二章 归来", url: "u2"),
            ChapterDTO(id: "3", index: 2, title: "第三章 终局", url: "u3"),
        ]
        let model = PlayerChapterListModel()
        XCTAssertEqual(model.displayedRows(from: chapters).map(\.id), ["1", "2", "3"])
        model.isDescending = true
        XCTAssertEqual(model.displayedRows(from: chapters).map(\.id), ["3", "2", "1"])
        model.keyword = "归来"
        XCTAssertEqual(model.displayedRows(from: chapters).map(\.id), ["2"])
    }

    @MainActor
    func testSourceOrganizeModelCrossGroupMoveAndFlatten() {
        let model = SourceOrganizeModel()
        let sources = [
            SourceMetaDTO(id: "s1", name: "源一", groupName: "A组", sortOrder: 0),
            SourceMetaDTO(id: "s2", name: "源二", groupName: "A组", sortOrder: 1),
            SourceMetaDTO(id: "s3", name: "源三", groupName: "B组", sortOrder: 0),
        ]
        model.load(from: sources)
        XCTAssertEqual(model.groups.count, 2)
        model.toggleSelection("s1")
        model.moveSelected(toGroup: "B组")
        let flat = model.flattenedForSave()
        XCTAssertEqual(flat.first(where: { $0.id == "s1" })?.groupName, "B组")
        XCTAssertEqual(flat.count, 3)
    }

    func testDownloadsDataHelperGroupingAndSorting() {
        let recs = [
            DownloadRecordSnapshot(id: "1", bookID: "b1", bookTitle: "书A", sourceID: "s", chapterID: "c2", chapterIndex: 2, chapterTitle: "二", chapterURL: "u", kind: .manual, state: .completed, totalBytes: 100),
            DownloadRecordSnapshot(id: "2", bookID: "b1", bookTitle: "书A", sourceID: "s", chapterID: "c1", chapterIndex: 1, chapterTitle: "一", chapterURL: "u", kind: .manual, state: .completed, totalBytes: 200),
            DownloadRecordSnapshot(id: "3", bookID: "b2", bookTitle: "书B", sourceID: "s", chapterID: "c1", chapterIndex: 0, chapterTitle: "零", chapterURL: "u", kind: .manual, state: .downloading, totalBytes: 0),
        ]
        XCTAssertEqual(DownloadsDataHelper.activeTasks(from: recs).map(\.id), ["3"])
        let groups = DownloadsDataHelper.completedBookGroups(from: recs)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.totalBytes, 300)
        XCTAssertEqual(DownloadsDataHelper.completedChapters(for: "b1", from: recs).map(\.chapterIndex), [1, 2])
    }

    func testBundledSourceSeederStripsUTF8BOM() {
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"ok":true}"#.utf8)
        let stripped = BundledSourceSeeder.stripUTF8BOM(withBOM)
        XCTAssertEqual(String(data: stripped, encoding: .utf8), #"{"ok":true}"#)
        let plain = Data(#"{"ok":true}"#.utf8)
        XCTAssertEqual(BundledSourceSeeder.stripUTF8BOM(plain), plain)
    }

    func testStoreBackupManagerRotationKeepsLatestFive() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSBackupTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("DSNovelV3.store")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT); INSERT INTO books VALUES (1, '凡人修仙传');", nil, nil, nil), SQLITE_OK)

        let manager = StoreBackupManager(storeURL: storeURL, maxBackups: 5)
        for _ in 0..<7 {
            let info = try await manager.createBackup()
            let valid = await manager.verifySQLiteIntegrity(at: info.url)
            XCTAssertTrue(valid)
        }
        let list = await manager.listBackups()
        XCTAssertEqual(list.count, 5)
        for item in list {
            let ok = await manager.verifySQLiteIntegrity(at: item.url)
            XCTAssertTrue(ok)
        }
    }

    func testPersistenceSearchHistoryDedupAndClear() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        try await engine.recordSearchKeyword("三体")
        try await engine.recordSearchKeyword("凡人")
        try await engine.recordSearchKeyword("三体")
        let hist = try await engine.fetchSearchHistory()
        XCTAssertEqual(hist.count, 2)
        XCTAssertEqual(hist.first, "三体")
        try await engine.clearSearchHistory()
        let empty = try await engine.fetchSearchHistory()
        XCTAssertTrue(empty.isEmpty)
    }

    func testPersistenceBookSkipConfigRoundTrip() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let book = BookSummaryDTO(id: "b-skip", sourceID: "s", bookURL: "u", title: "跳过测试")
        try await engine.upsertBook(book, addToShelf: true)
        await engine.saveBookSkipConfig(bookID: book.id, config: SkipConfigDTO(introSeconds: 30, outroSeconds: 20))
        let loaded = await engine.loadBookSkipConfig(bookID: book.id)
        XCTAssertEqual(loaded, SkipConfigDTO(introSeconds: 30, outroSeconds: 20))
    }

    func testPersistenceOverrideFinishedResetsFlag() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let book = BookSummaryDTO(id: "b-fin", sourceID: "s", bookURL: "u", title: "完播重置")
        let ch = ChapterDTO(id: "c1", index: 0, title: "一", url: "u1")
        await engine.saveProgress(book: book, chapter: ch, positionMs: 100_000, durationMs: 100_000, isFinished: true, overrideFinished: true)
        await engine.saveProgress(book: book, chapter: ch, positionMs: 10_000, durationMs: 100_000, isFinished: false, overrideFinished: true)
        let prog = await engine.loadChapterProgress(bookID: book.id, chapterID: ch.id)
        XCTAssertEqual(prog?.isFinished, false)
    }

    func testPersistenceLibraryBackupExportAndReimport() async throws {
        let c1 = try StorageContainerFactory.makeInMemory()
        let e1 = PersistenceEngine(modelContainer: c1)
        let book = BookSummaryDTO(id: "b-exp", sourceID: "s", bookURL: "u", title: "导出书")
        try await e1.upsertBook(book, addToShelf: true)
        let payload = try await e1.exportLibraryBackup(appVersion: "3.0.0")
        let data = try LibraryBackupCodec.encode(payload)

        let c2 = try StorageContainerFactory.makeInMemory()
        let e2 = PersistenceEngine(modelContainer: c2)
        let decoded = try LibraryBackupCodec.decode(data)
        let imported = try await e2.importLibraryBackup(decoded)
        XCTAssertEqual(imported, 1)
        let shelf = try await e2.fetchShelfBooks()
        XCTAssertEqual(shelf.first?.title, "导出书")
    }
}
