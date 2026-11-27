@testable import DSNovel
import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSPluginKit
import DSStorage
import Foundation
import XCTest

/// 第三轮 12 项终版收口（b4）定向回归测试套件（16 项，总单测数达 256 项）
final class DSB4ThirdAuditRegressionTests: XCTestCase {
    // UX3-02: archiveCorruptedAndResetStore 归档坏库并清理主库/WAL/SHM
    func testUX3_02_ArchiveCorruptedAndResetStoreCreatesArchiveAndCleansWAL() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSCorruptReset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let storeURL = tempDir.appendingPathComponent("DSNovelV3.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("bad-db".utf8).write(to: storeURL)
        try Data("bad-wal".utf8).write(to: walURL)
        try Data("bad-shm".utf8).write(to: shmURL)

        let manager = StoreBackupManager(storeURL: storeURL)
        let archived = try await manager.archiveCorruptedAndResetStore()
        XCTAssertNotNil(archived)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))
    }

    // UX3-01 + UX3-05: DownloadCoordinator completedRevision & isWaitingForWiFi
    @MainActor
    func testUX3_01_05_DownloadCoordinatorRevisionAndWaitingForWiFiFlag() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let vault = CookieVault(inMemorySecretsOnly: true)
        let client = HostHTTPClient(cookieVault: vault)
        let runtime = PluginRuntime(preludeScript: "", httpClient: client, cookieVault: vault, logger: logger)
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DSB4Rev-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let transport = BackgroundTransferTransport(baseDirectory: tempRoot, sessionIdentifier: "com.dsnovel.test.\(UUID().uuidString)")
        defer { transport.invalidate() }
        let coord = DownloadCoordinator(persistence: engine, audioResolver: runtime, downloadsRoot: tempRoot, transport: transport, logger: logger)
        XCTAssertEqual(coord.completedRevision, 0)
        coord.updatePolicy(wifiOnly: true, maxManualConcurrent: 3, isOnWiFi: false)
        XCTAssertTrue(coord.isWaitingForWiFi)
        coord.updatePolicy(wifiOnly: true, maxManualConcurrent: 3, isOnWiFi: true)
        XCTAssertFalse(coord.isWaitingForWiFi)

        await coord.cancelAndDelete(id: "nonexistent")
        XCTAssertEqual(coord.completedRevision, 1)
    }

    // UX3-06: SearchViewModel 按书源筛选芯片与去重列表
    @MainActor
    func testUX3_06_SearchViewModelSourceFilterChips() {
        let vm = SearchViewModel()
        vm.results = [
            BookSummaryDTO(id: "a1", sourceID: "s1", sourceName: "源甲", bookURL: "u1", title: "书1"),
            BookSummaryDTO(id: "a2", sourceID: "s2", sourceName: "源乙", bookURL: "u2", title: "书2"),
            BookSummaryDTO(id: "a3", sourceID: "s1", sourceName: "源甲", bookURL: "u3", title: "书3"),
        ]
        XCTAssertEqual(vm.availableResultSources.count, 2)
        XCTAssertEqual(vm.filteredResults.count, 3)

        vm.selectedSourceFilterID = "s1"
        XCTAssertEqual(vm.filteredResults.map(\.id), ["a1", "a3"])
        vm.selectedSourceFilterID = "s2"
        XCTAssertEqual(vm.filteredResults.map(\.id), ["a2"])
        vm.selectedSourceFilterID = nil
        XCTAssertEqual(vm.filteredResults.count, 3)
    }

    // UX3-04: AudioTapDSP 自定义 5 段手动 EQ 同步到参数快照
    @MainActor
    func testUX3_04_AudioTapDSPCustomFiveBandUpdate() {
        let dsp = AudioTapDSP()
        dsp.customBands = [6.0, -3.5, 4.0, 2.5, -1.0]
        XCTAssertEqual(dsp.currentParameters().bandGainsDB, [6.0, -3.5, 4.0, 2.5, -1.0])
        dsp.preset = .flat
        XCTAssertEqual(dsp.currentParameters().bandGainsDB, [0, 0, 0, 0, 0])
    }

    // SYS3-02 / P0-13: 调用真实 SourceContractAdapter.decodeBookDetail 验证过滤脏章节后重映射连续 0..<count
    func testSYS3_02_OfflineChapterSequentialIndexRemapping() {
        let fallback = BookSummaryDTO(id: "s1::b1", sourceID: "s1", bookURL: "https://example.com/b1", title: "测试书")
        let rawJSON = #"""
        {
          "title": "测试书",
          "chapters": [
            {"title": "坏章一缺少URL"},
            {"id": "c10", "title": "第十章", "url": "https://example.com/c10", "duration": 120},
            {"url": "https://example.com/no-title"},
            {"id": "c11", "title": "第十一章", "url": "https://example.com/c11", "durationMs": 240000},
            {"id": "c12", "name": "第十二章", "playUrl": "https://example.com/c12"}
          ]
        }
        """#
        let detail = SourceContractAdapter.decodeBookDetail(rawJSON, fallback: fallback)
        XCTAssertEqual(detail.chapters.count, 3)
        XCTAssertEqual(detail.summary.totalChapters, 3)
        XCTAssertEqual(detail.chapters.map(\.index), [0, 1, 2])
        XCTAssertEqual(detail.chapters.map(\.title), ["第十章", "第十一章", "第十二章"])
        XCTAssertEqual(detail.chapters[0].durationMs, 120_000)
        XCTAssertEqual(detail.chapters[1].durationMs, 240_000)
    }

    // 额外 11 项回归与边界保护测试
    func testDiscoverCategoryDTOEquatableAndID() {
        let c1 = DiscoverCategoryDTO(id: "s::hot", title: "热门", url: "/hot")
        let c2 = DiscoverCategoryDTO(id: "s::hot", title: "热门", url: "/hot")
        XCTAssertEqual(c1, c2)
    }

    func testBookDetailDTODefaultEmptyTags() {
        let s = BookSummaryDTO(id: "1", sourceID: "s", bookURL: "u", title: "T")
        let d = BookDetailDTO(summary: s, chapters: [])
        XCTAssertTrue(d.tags.isEmpty)
        XCTAssertEqual(d.updateTime, "")
    }

    func testChapterDTODurationClampsNegativeToZero() {
        let c = ChapterDTO(id: "1", index: 0, title: "一", url: "u", durationMs: -500)
        XCTAssertEqual(c.durationMs, 0)
    }

    func testBookSummaryDTOTotalChaptersClampsNegative() {
        let b = BookSummaryDTO(id: "1", sourceID: "s", bookURL: "u", title: "T", totalChapters: -10)
        XCTAssertEqual(b.totalChapters, 0)
    }

    func testAudioQualityTierAllCasesCount() {
        XCTAssertEqual(AudioQualityTier.allCases.count, 4)
    }

    func testParserHealthStatusRawValues() {
        XCTAssertEqual(ParserHealthStatus(rawValue: "healthy"), .healthy)
        XCTAssertEqual(ParserHealthStatus(rawValue: "degraded"), .degraded)
        XCTAssertEqual(ParserHealthStatus(rawValue: "failed"), .failed)
        XCTAssertEqual(ParserHealthStatus(rawValue: "unknown"), .unknown)
    }

    func testSourcePermissionModeRawValues() {
        XCTAssertEqual(SourcePermissionMode(rawValue: "declaredHosts"), .declaredHosts)
        XCTAssertEqual(SourcePermissionMode(rawValue: "compatApproved"), .compatApproved)
    }

    func testDiagnosticLogStoreClearEmptiesEntries() async {
        let store = DSDiagnosticLogStore()
        await store.record(category: .ui, level: "INFO", message: "hello")
        await store.clear()
        let snap = await store.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }

    func testZIPArchiveErrorDescriptionsNonEmpty() {
        let errors: [ZIPArchiveError] = [
            .invalidArchive,
            .entryLimitExceeded(128),
            .entrySizeExceeded("a.js", 9_000_000),
            .totalSizeExceeded(40_000_000),
            .invalidPath("../a"),
            .truncatedLocalHeader("a.js"),
            .unsupportedCompression(99),
            .decompressionFailed("a.js"),
            .crcMismatch(entry: "a.js", expected: 1, actual: 2)
        ]
        for err in errors {
            XCTAssertFalse((err.errorDescription ?? "").isEmpty)
        }
    }

    func testPluginSecurityErrorDescriptionsNonEmpty() {
        let errors: [PluginSecurityError] = [
            .networkDisabledInPreview,
            .invalidURL("bad"),
            .ssrfBlocked("127.0.0.1"),
            .hostNotAllowed(host: "evil.com", ownerID: "s"),
            .timeout(seconds: 5),
            .scriptError("err"),
            .cancelled
        ]
        for err in errors {
            XCTAssertFalse((err.errorDescription ?? "").isEmpty)
        }
    }

    func testDownloadKindRawValues() {
        XCTAssertEqual(DownloadKind(rawValue: "manual"), .manual)
        XCTAssertEqual(DownloadKind(rawValue: "precache"), .precache)
    }
}
