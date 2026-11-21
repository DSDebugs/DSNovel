import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import Foundation
import XCTest

final class DSPlaybackAndDownloadsTests: XCTestCase {
    @MainActor
    func testAudioTapDSPImmediateHLSFallbackAndWatchdog() async {
        let dsp = AudioTapDSP()
        var fallbackFired = false
        dsp.prepareForStream(
            isHLS: true,
            mimeType: "application/vnd.apple.mpegurl",
            assetURL: URL(string: "https://cdn.example.com/live/stream")!,
            onFallback: { fallbackFired = true }
        )
        XCTAssertTrue(dsp.isUsingNativeVolumeFallback)
        XCTAssertTrue(fallbackFired)

        // 使用短看门狗超时验证无后缀流媒体自动降级（零 950ms 硬等）
        let dsp2 = AudioTapDSP(watchdogTimeoutNanoseconds: 25_000_000)
        var watchdogFired = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            dsp2.prepareForStream(
                isHLS: false,
                mimeType: nil,
                assetURL: URL(string: "https://cdn.example.com/stream?id=123")!,
                onFallback: {
                    watchdogFired = true
                    cont.resume()
                }
            )
            XCTAssertFalse(dsp2.isUsingNativeVolumeFallback)
        }
        XCTAssertTrue(dsp2.isUsingNativeVolumeFallback)
        XCTAssertTrue(watchdogFired)
    }

    @MainActor
    func testSleepTimerWallClockAndPerChapter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = now.addingTimeInterval(900)
        XCTAssertEqual(SleepTimerEngine.computeRemainingSeconds(deadline: deadline, now: now.addingTimeInterval(300)), 600)
        XCTAssertEqual(SleepTimerEngine.computeRemainingSeconds(deadline: deadline, now: now.addingTimeInterval(905)), 0)

        let engine = SleepTimerEngine()
        engine.startAfterChapters(2)
        XCTAssertFalse(engine.consumeChapterFinished())
        XCTAssertEqual(engine.displayBadge, "播完1章")
        XCTAssertTrue(engine.consumeChapterFinished())
        XCTAssertFalse(engine.isActive)
    }

    func testDownloadSchedulerDualPoolPreventsPrecacheStarvation() {
        let scheduler = DownloadScheduler(maxManualConcurrent: 3, maxPrecacheConcurrent: 1)
        let now = Date()

        // 制造 25 条 precache 任务 + 2 条 manual 任务，manual 必须立刻获得调度
        let precache = (0..<25).map { i in
            DownloadRecordSnapshot(
                id: "pre-\(i)", bookID: "b1", bookTitle: "书1", sourceID: "s1",
                chapterID: "p-\(i)", chapterIndex: i, chapterTitle: "预缓\(i)", chapterURL: "https://example.com/p/\(i)",
                kind: .precache, state: .queued, createdAt: now.addingTimeInterval(Double(i))
            )
        }
        let manual = (0..<2).map { i in
            DownloadRecordSnapshot(
                id: "man-\(i)", bookID: "b1", bookTitle: "书1", sourceID: "s1",
                chapterID: "m-\(i)", chapterIndex: 100 + i, chapterTitle: "手动\(i)", chapterURL: "https://example.com/m/\(i)",
                kind: .manual, state: .queued, createdAt: now.addingTimeInterval(100 + Double(i))
            )
        }

        let batch = scheduler.pickNextBatch(manualCandidates: manual, precacheCandidates: precache, now: now)
        let manualPicked = batch.filter { $0.kind == .manual }
        let precachePicked = batch.filter { $0.kind == .precache }
        XCTAssertEqual(manualPicked.count, 2)
        XCTAssertEqual(precachePicked.count, 1)
    }

    func testStorageReconcilerDetectsMissingAndCleansOrphans() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DSReconcile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let validRel = DownloadRecordSnapshot.canonicalRelativePath(bookID: "b1", chapterID: "c1")
        let validFile = tempRoot.appendingPathComponent(validRel)
        try FileManager.default.createDirectory(at: validFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio-bytes".utf8).write(to: validFile)

        let orphanFile = tempRoot.appendingPathComponent("orphan.m4a")
        try Data("orphan".utf8).write(to: orphanFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1200)], ofItemAtPath: orphanFile.path)

        let completed = [
            DownloadRecordSnapshot(
                id: "ok", bookID: "b1", bookTitle: "书1", sourceID: "s1",
                chapterID: "c1", chapterIndex: 0, chapterTitle: "一", chapterURL: "https://example.com/1",
                kind: .manual, state: .completed, localRelPath: validRel
            ),
            DownloadRecordSnapshot(
                id: "missing", bookID: "b1", bookTitle: "书1", sourceID: "s1",
                chapterID: "c2", chapterIndex: 1, chapterTitle: "二", chapterURL: "https://example.com/2",
                kind: .manual, state: .completed, localRelPath: "nonexistent/file.m4a"
            )
        ]

        let reconciler = StorageReconciler(downloadsRoot: tempRoot, minIntervalSeconds: 60)
        let report = await reconciler.reconcileIfNeeded(completedRecords: completed, force: true)
        XCTAssertEqual(report?.verifiedFiles, 1)
        XCTAssertEqual(report?.missingRecordIDs, ["missing"])
        XCTAssertEqual(report?.orphanFilesRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFile.path))
    }

    func testCoverPipelineRejects200HTMLFakeImage() {
        let fakeHTML = Data("<html><body>403 Forbidden</body></html>".utf8)
        XCTAssertNil(CoverImagePipeline.validateAndDecodeImage(data: fakeHTML, contentType: "text/html"))
        XCTAssertNil(CoverImagePipeline.validateAndDecodeImage(data: fakeHTML, contentType: "image/jpeg"))
    }
}
