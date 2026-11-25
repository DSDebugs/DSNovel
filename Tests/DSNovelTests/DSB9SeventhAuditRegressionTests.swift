import DSCore
import DSPlayback
import DSStorage
import Foundation
import XCTest

/// 第七轮 4 项精修（b9）定向回归测试套件（总单测数达 281 项）
final class DSB9SeventhAuditRegressionTests: XCTestCase {
    // B9-01: 睡眠定时在淡出期取消时，必须先收到 < 1.0 的淡出系数，取消后立即恢复 1.0
    @MainActor
    func testB9_01_CancelDuringFadeOutRestoresVolumeFactorToUnity() async {
        let engine = SleepTimerEngine(tickIntervalNanoseconds: 10_000_000)
        engine.fadeOutLastSeconds = 120
        var receivedFactors: [Float] = []

        engine.startCountdown(
            minutes: 1,
            onFadeFactor: { factor in receivedFactors.append(factor) },
            onFire: {}
        )
        let deadline = ContinuousClock.now + .seconds(2)
        while !receivedFactors.contains(where: { $0 < 1.0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(receivedFactors.contains(where: { $0 >= 0.05 && $0 < 1.0 }), "应先进入淡出区间收到 < 1.0 的系数")
        engine.cancel()

        XCTAssertFalse(engine.isActive)
        XCTAssertEqual(receivedFactors.last, 1.0)
    }

    // B9-01: 倒计时淡出期切为按章定时，先确认进入淡出区间再验证立即恢复 1.0
    @MainActor
    func testB9_01_SwitchToAfterChaptersDuringFadeOutRestoresVolumeFactor() async {
        let engine = SleepTimerEngine(tickIntervalNanoseconds: 10_000_000)
        engine.fadeOutLastSeconds = 120
        var receivedFactors: [Float] = []

        engine.startCountdown(
            minutes: 1,
            onFadeFactor: { factor in receivedFactors.append(factor) },
            onFire: {}
        )
        let deadline = ContinuousClock.now + .seconds(2)
        while !receivedFactors.contains(where: { $0 < 1.0 }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(receivedFactors.contains(where: { $0 >= 0.05 && $0 < 1.0 }), "应先进入淡出区间收到 < 1.0 的系数")
        engine.startAfterChapters(1)

        XCTAssertEqual(engine.mode, .afterChapters(remaining: 1))
        XCTAssertEqual(receivedFactors.last, 1.0)
    }

    // B9-04: 单事务批量保存书源整理结果（排序、分组、置顶、启停）
    func testB9_04_UpdateSourcesOrganizationBatchPersistsAtomically() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let s1 = SourceMetaDTO(id: "org-1", name: "源一", groupName: "默认", sortOrder: 0)
        let s2 = SourceMetaDTO(id: "org-2", name: "源二", groupName: "默认", sortOrder: 1)
        try await engine.upsertSource(meta: s1, scriptBody: "function search(){}", isBundled: false)
        try await engine.upsertSource(meta: s2, scriptBody: "function search(){}", isBundled: false)

        let updated = [
            SourceMetaDTO(id: "org-2", name: "源二", isEnabled: true, isPinned: true, groupName: "精选", sortOrder: 0),
            SourceMetaDTO(id: "org-1", name: "源一", isEnabled: false, isPinned: false, groupName: "备用", sortOrder: 1),
        ]
        try await engine.updateSourcesOrganizationBatch(updated)

        let all = try await engine.fetchAllSources()
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.meta.id, $0.meta) })
        XCTAssertEqual(map["org-2"]?.groupName, "精选")
        XCTAssertEqual(map["org-2"]?.isPinned, true)
        XCTAssertEqual(map["org-2"]?.sortOrder, 0)
        XCTAssertEqual(map["org-1"]?.isEnabled, false)
        XCTAssertEqual(map["org-1"]?.groupName, "备用")
        XCTAssertEqual(map["org-1"]?.sortOrder, 1)
    }

    // B9-04: 空数组批量更新书源整理安全无副作用
    func testB9_04_UpdateSourcesOrganizationBatchEmptyIsNoOp() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        try await engine.updateSourcesOrganizationBatch([])
        let all = try await engine.fetchAllSources()
        XCTAssertTrue(all.isEmpty)
    }

    // B9-02: 单事务批量暂停/恢复状态写入验证（upsertDownloadsBatch 状态流转）
    func testB9_02_BatchStateTransitionPersistsPausedAndQueued() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let initial = (0..<12).map { i in
            DownloadRecordSnapshot(
                id: "dl-\(i)", bookID: "bk", bookTitle: "测试书", sourceID: "s1",
                chapterID: "c-\(i)", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterURL: "https://e.com/\(i)",
                kind: .manual, state: .queued
            )
        }
        try await engine.upsertDownloadsBatch(initial)
        let paused = initial.map { rec -> DownloadRecordSnapshot in
            var copy = rec
            copy.state = .paused
            return copy
        }
        try await engine.upsertDownloadsBatch(paused)
        let loaded = try await engine.fetchDownloads(kind: .manual, state: .paused)
        XCTAssertEqual(loaded.count, 12)
    }
}
