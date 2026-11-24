import DSCore
import DSPlayback
import DSStorage
import Foundation
import XCTest

/// 第五轮 6 项微距精修（b7）定向回归测试套件（总单测数达 272 项）
final class DSB7MicroPolishTests: XCTestCase {
    // SYS5-02: 单事务批量写入下载记录验证
    func testSYS5_02_UpsertDownloadsBatchSingleTransaction() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let batch = (0..<50).map { i in
            DownloadRecordSnapshot(
                id: "batch-\(i)", bookID: "b1", bookTitle: "批量书", sourceID: "s1",
                chapterID: "c-\(i)", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterURL: "https://e.com/\(i)",
                kind: .manual, state: .queued
            )
        }
        try await engine.upsertDownloadsBatch(batch)
        let loaded = try await engine.fetchAllDownloadsPaginated(pageSize: 100)
        XCTAssertEqual(loaded.count, 50)
    }

    // SYS5-02: 单事务批量移出书架验证
    func testSYS5_02_SetInShelfBatchRemovesMultipleBooksAtomically() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        for i in 1...4 {
            let b = BookSummaryDTO(id: "rm-\(i)", sourceID: "s", bookURL: "u\(i)", title: "书\(i)")
            try await engine.upsertBook(b, addToShelf: true)
        }
        try await engine.setInShelfBatch(bookIDs: ["rm-1", "rm-2", "rm-3"], inShelf: false)
        let remaining = try await engine.fetchShelfBooks()
        XCTAssertEqual(remaining.map(\.id), ["rm-4"])
    }

    // SYS5-03: .auto 音质在 Wi-Fi 与蜂窝流量下差异化前向缓冲
    @MainActor
    func testSYS5_03_AutoQualityBufferDurationAdaptsToWiFiState() {
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .auto, isOnWiFi: true), 60)
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .auto, isOnWiFi: false), 20)
        XCTAssertEqual(PlaybackCoordinator.forwardBufferDuration(for: .saver, isOnWiFi: false), 15)
    }

    // 边界回归（3 项）
    func testUpsertDownloadsBatchEmptyIsNoOp() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        try await engine.upsertDownloadsBatch([])
        let all = try await engine.fetchAllDownloadsPaginated()
        XCTAssertTrue(all.isEmpty)
    }

    func testSetInShelfBatchEmptyIsNoOp() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        try await engine.setInShelfBatch(bookIDs: [], inShelf: false)
        let shelf = try await engine.fetchShelfBooks()
        XCTAssertTrue(shelf.isEmpty)
    }

    func testUpsertDownloadsBatchUpdatesExistingRecords() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let initial = DownloadRecordSnapshot(
            id: "upd-1", bookID: "b1", bookTitle: "B", sourceID: "s",
            chapterID: "c1", chapterIndex: 0, chapterTitle: "一", chapterURL: "u",
            kind: .manual, state: .queued
        )
        try await engine.upsertDownloadsBatch([initial])
        var updated = initial
        updated.state = .completed
        updated.totalBytes = 4096
        try await engine.upsertDownloadsBatch([updated])
        let loaded = try await engine.fetchDownloads(kind: .manual, state: .completed)
        XCTAssertEqual(loaded.first?.totalBytes, 4096)
    }
}
