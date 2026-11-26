import DSCore
import DSDownloads
import Foundation
import XCTest

final class DSDownloadsPackageTests: XCTestCase {
    func testSchedulerDualPoolIsolationAndMigration() {
        var scheduler = DownloadScheduler(maxManualConcurrent: 2, maxPrecacheConcurrent: 1)
        XCTAssertEqual(scheduler.totalActiveCount, 0)

        scheduler.markStarted(id: "p1", kind: .precache)
        XCTAssertEqual(scheduler.activePrecacheIDs, ["p1"])
        XCTAssertTrue(scheduler.activeManualIDs.isEmpty)

        scheduler.migrateKind(id: "p1", to: .manual)
        XCTAssertTrue(scheduler.activePrecacheIDs.isEmpty)
        XCTAssertEqual(scheduler.activeManualIDs, ["p1"])
        XCTAssertEqual(scheduler.totalActiveCount, 1)

        // 未在途任务调用 migrateKind 不得伪造活跃槽位
        scheduler.migrateKind(id: "ghost", to: .manual)
        XCTAssertEqual(scheduler.totalActiveCount, 1)

        scheduler.markFinished(id: "p1")
        XCTAssertEqual(scheduler.totalActiveCount, 0)
    }

    func testSchedulerPrioritizesManualAndRespectsBackoff() {
        let scheduler = DownloadScheduler(maxManualConcurrent: 2, maxPrecacheConcurrent: 1)
        let now = Date()
        let manualDelayed = DownloadRecordSnapshot(
            id: "m-delay", bookID: "b", bookTitle: "B", sourceID: "s",
            chapterID: "c1", chapterIndex: 0, chapterTitle: "1", chapterURL: "https://e.com/1",
            kind: .manual, state: .queued, retryCount: 1, retryNotBefore: now.addingTimeInterval(60)
        )
        let manualReady = DownloadRecordSnapshot(
            id: "m-ready", bookID: "b", bookTitle: "B", sourceID: "s",
            chapterID: "c2", chapterIndex: 1, chapterTitle: "2", chapterURL: "https://e.com/2",
            kind: .manual, state: .queued
        )
        let precacheReady = DownloadRecordSnapshot(
            id: "p-ready", bookID: "b", bookTitle: "B", sourceID: "s",
            chapterID: "c3", chapterIndex: 2, chapterTitle: "3", chapterURL: "https://e.com/3",
            kind: .precache, state: .queued
        )

        let picked = scheduler.pickNextBatch(
            manualCandidates: [manualDelayed, manualReady],
            precacheCandidates: [precacheReady],
            now: now
        )
        XCTAssertEqual(picked.map(\.id), ["m-ready", "p-ready"])
    }

    @MainActor
    func testDownloadProgressFeedUpdatesClampsAndRemoves() {
        let feed = DownloadProgressFeed()
        feed.update(id: "t1", downloaded: 25, total: 100, speed: 2048)
        XCTAssertEqual(feed.progress(for: "t1"), 0.25, accuracy: 0.001)
        feed.update(id: "t1", downloaded: 150, total: 100, speed: 4096)
        XCTAssertLessThanOrEqual(feed.progress(for: "t1"), 1.0)
        feed.remove(id: "t1")
        XCTAssertEqual(feed.progress(for: "t1"), 0)
    }

    func testStorageReconcilerDetectsMissingAndRespectsGraceWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DSDownloadsPkg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let freshOrphan = root.appendingPathComponent("fresh.m4a")
        try Data("fresh".utf8).write(to: freshOrphan)

        let oldOrphan = root.appendingPathComponent("old.m4a")
        try Data("old".utf8).write(to: oldOrphan)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1200)], ofItemAtPath: oldOrphan.path)

        let reconciler = StorageReconciler(downloadsRoot: root, minIntervalSeconds: 60)
        let report = await reconciler.reconcileIfNeeded(completedRecords: [], force: true)
        XCTAssertEqual(report?.orphanFilesRemoved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshOrphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOrphan.path))
    }
}
