import DSCore
import DSStorage
import Foundation
import XCTest

/// 第六轮 4 项精修（b8）定向回归测试套件（总单测数达 276 项）
final class DSB8SixthAuditRegressionTests: XCTestCase {
    // B8-01: pruneOldChapterProgress 突破原 fetchLimit=200 恒假死代码，精准裁剪超额旧记录
    func testB8_01_PruneOldChapterProgressDeletesExcessAboveKeepLimit() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let book = BookSummaryDTO(id: "prune-book", sourceID: "s1", bookURL: "https://e.com/b", title: "裁剪测试书")

        for i in 0..<15 {
            let chapter = ChapterDTO(id: "ch-\(i)", index: i, title: "第\(i + 1)章", url: "https://e.com/c/\(i)")
            await engine.saveProgress(
                book: book,
                chapter: chapter,
                positionMs: (i + 1) * 1000,
                durationMs: 60_000,
                isFinished: false,
                overrideFinished: false
            )
        }

        let deleted = try await engine.pruneOldChapterProgress(keepLatestPerBook: 10)
        XCTAssertEqual(deleted, 5)

        let secondPass = try await engine.pruneOldChapterProgress(keepLatestPerBook: 10)
        XCTAssertEqual(secondPass, 0)
    }

    // B8-01: 记录数未超阈值时返回 0 且不误删
    func testB8_01_PruneOldChapterProgressNoOpWhenWithinLimit() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let book = BookSummaryDTO(id: "keep-book", sourceID: "s1", bookURL: "https://e.com/k", title: "保留测试书")

        for i in 0..<3 {
            let chapter = ChapterDTO(id: "keep-\(i)", index: i, title: "第\(i + 1)章", url: "https://e.com/k/\(i)")
            await engine.saveProgress(
                book: book,
                chapter: chapter,
                positionMs: 5000,
                durationMs: 60_000,
                isFinished: false,
                overrideFinished: false
            )
        }

        let deleted = try await engine.pruneOldChapterProgress(keepLatestPerBook: 500)
        XCTAssertEqual(deleted, 0)
        let loaded = await engine.loadChapterProgress(bookID: "keep-book", chapterID: "keep-0")
        XCTAssertEqual(loaded?.positionMs, 5000)
    }

    // B8-02: 单事务批量删除整本书下载记录，不影响其他书籍记录
    func testB8_02_DeleteDownloadsBatchRemovesAllTargetsInOneTransaction() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        var batch: [DownloadRecordSnapshot] = []
        var targetIDs: [String] = []
        for i in 0..<20 {
            let id = "bookA-\(i)"
            targetIDs.append(id)
            batch.append(DownloadRecordSnapshot(
                id: id, bookID: "book-A", bookTitle: "甲书", sourceID: "s1",
                chapterID: "ca-\(i)", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterURL: "https://e.com/a/\(i)",
                kind: .manual, state: .completed
            ))
        }
        for i in 0..<5 {
            batch.append(DownloadRecordSnapshot(
                id: "bookB-\(i)", bookID: "book-B", bookTitle: "乙书", sourceID: "s1",
                chapterID: "cb-\(i)", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterURL: "https://e.com/b/\(i)",
                kind: .manual, state: .completed
            ))
        }

        try await engine.upsertDownloadsBatch(batch)
        let deleted = try await engine.deleteDownloadsBatch(ids: targetIDs)
        XCTAssertEqual(deleted, 20)

        let remaining = try await engine.fetchAllDownloadsPaginated(pageSize: 100)
        XCTAssertEqual(remaining.count, 5)
        XCTAssertTrue(remaining.allSatisfy { $0.bookID == "book-B" })
    }

    // B8-02: 空数组批量删除安全返回 0
    func testB8_02_DeleteDownloadsBatchEmptyIsNoOp() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let deleted = try await engine.deleteDownloadsBatch(ids: [])
        XCTAssertEqual(deleted, 0)
    }
}
