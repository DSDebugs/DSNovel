import AVFoundation
import DSCore
import DSPlayback
import DSStorage
import Foundation
import XCTest

/// 第八轮 4 项精修（b10）定向回归测试套件（总单测数达 286 项）
final class DSB10EighthAuditRegressionTests: XCTestCase {
    // B10-01: AudioTapDSP 双通道淡出音量互斥归位验证（HLS 降级切回非降级时必须把 player.volume 复位为 1.0）
    @MainActor
    func testB10_01_ApplyFadeVolumeResetsOppositeChannelOnFallbackSwitch() {
        let dsp = AudioTapDSP()
        let player = AVPlayer()

        dsp.activateFallback(reason: "HLS")
        dsp.applyFadeVolume(to: player, factor: 0.25)
        XCTAssertEqual(player.volume, 0.25, accuracy: 0.001)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 1.0, accuracy: 0.001)

        // 切回非降级（本地音频 Tap）并恢复音量
        dsp.markTapReceiptReceived()
        dsp.applyFadeVolume(to: player, factor: 0.6)
        XCTAssertEqual(player.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 0.6, accuracy: 0.001)
    }

    // B10-01: 非降级态恢复 1.0 时双通道均为 1.0
    @MainActor
    func testB10_01_ApplyFadeVolumeUnityRestoresBothChannels() {
        let dsp = AudioTapDSP()
        let player = AVPlayer()
        player.volume = 0.2
        dsp.markTapReceiptReceived()
        dsp.applyFadeVolume(to: player, factor: 1.0)
        XCTAssertEqual(player.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 1.0, accuracy: 0.001)
    }

    // B10-02: importLibraryBackup 单事务批量插入与更新（零 2N 查询/落盘）
    func testB10_02_ImportLibraryBackupInsertsAndUpdatesInSingleTransaction() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        let existing = BookSummaryDTO(id: "bk-1", sourceID: "s1", bookURL: "https://e.com/1", title: "旧标题")
        try await engine.upsertBook(existing, addToShelf: false)

        let payload = LibraryBackupPayload(
            appVersion: "3.0.0",
            books: [
                LibraryBackupPayload.BackupBook(
                    id: "bk-1", sourceID: "s1", sourceName: "源一", bookURL: "https://e.com/1",
                    title: "新标题", author: "作者甲", narrator: "播音甲", coverURL: "",
                    inShelf: true, isPinned: true, shelfGroupName: "常听",
                    lastPlayedAt: Date(), lastChapterIndex: 12, lastChapterTitle: "第13章",
                    lastPositionMs: 42_000, skipConfig: SkipConfigDTO(introSeconds: 15, outroSeconds: 10)
                ),
                LibraryBackupPayload.BackupBook(
                    id: "bk-2", sourceID: "s1", sourceName: "源一", bookURL: "https://e.com/2",
                    title: "新书二", author: "作者乙", narrator: "播音乙", coverURL: "",
                    inShelf: true, isPinned: false, shelfGroupName: "",
                    lastPlayedAt: nil, lastChapterIndex: 0, lastChapterTitle: "",
                    lastPositionMs: 0, skipConfig: SkipConfigDTO()
                ),
            ]
        )

        let count = try await engine.importLibraryBackup(payload)
        XCTAssertEqual(count, 2)

        let shelf = try await engine.fetchShelfBooks()
        XCTAssertEqual(shelf.count, 2)
        let skip = await engine.loadBookSkipConfig(bookID: "bk-1")
        XCTAssertEqual(skip.introSeconds, 15)
        XCTAssertEqual(skip.outroSeconds, 10)
        let last = await engine.fetchBookLastPlayback(bookID: "bk-1")
        XCTAssertEqual(last?.chapterIndex, 12)
        XCTAssertEqual(last?.positionMs, 42_000)
    }

    // B10-02: 空书架备份导入安全返回 0
    func testB10_02_ImportLibraryBackupEmptyReturnsZero() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let count = try await engine.importLibraryBackup(LibraryBackupPayload(appVersion: "3.0.0", books: []))
        XCTAssertEqual(count, 0)
    }

    // B10-03: 批量写入恢复状态后可被分页全量准确读取
    func testB10_03_BatchRecoveryUpdatesDownloadingRecordsToQueued() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let interrupted = (0..<8).map { i in
            DownloadRecordSnapshot(
                id: "rec-\(i)", bookID: "bk", bookTitle: "书", sourceID: "s1",
                chapterID: "c-\(i)", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterURL: "https://e.com/\(i)",
                kind: .manual, state: .downloading
            )
        }
        try await engine.upsertDownloadsBatch(interrupted)
        let recovered = interrupted.map { rec -> DownloadRecordSnapshot in
            var copy = rec
            copy.state = .queued
            return copy
        }
        try await engine.upsertDownloadsBatch(recovered)
        let queued = try await engine.fetchDownloads(kind: .manual, state: .queued)
        XCTAssertEqual(queued.count, 8)
    }
}
