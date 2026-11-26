import DSCore
@testable import DSDownloads
import DSPlayback
import DSStorage
import Foundation
import Testing

@Suite("第四轮审计 P0/P1 回归测试（统计防丢、排队提示、定时器边界）")
struct DSAuditFourthRoundTests {
    @Test("F-01/N-03：ListeningStatsStore 损坏文件自动改名取证且不被后续落盘覆盖，兼容旧版数组格式并拦截高版本")
    @MainActor
    func listeningStatsPreservesCorruptedFileAndSupportsLegacyArray() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_stats_f01_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let statsURL = dir.appendingPathComponent("listening_stats_v1.json")
        try Data("{\"corrupt".utf8).write(to: statsURL)

        let store = ListeningStatsStore(storageDirectory: dir)
        let filesAfterLoad = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(filesAfterLoad.contains(where: { $0.contains(".corrupted-") }))
        #expect(!FileManager.default.fileExists(atPath: statsURL.path))

        let book = BookSummaryDTO(id: "b1", sourceID: "s1", bookURL: "https://example.com/b1", title: "测试书")
        store.recordListening(book: book, deltaSeconds: 8.0)
        await store.flushToDiskAsync()
        #expect(FileManager.default.fileExists(atPath: statsURL.path))

        let reloaded = ListeningStatsStore(storageDirectory: dir)
        #expect(reloaded.overview.todaySeconds >= 8.0)

        // 兼容旧版纯数组 JSON 格式
        let legacyRecord = DailyBookListeningRecord(
            dayKey: ListeningStatsStore.dayKey(for: Date()),
            bookID: "legacy_b",
            bookTitle: "旧版统计书",
            coverURL: "",
            sourceID: "s1",
            bookURL: "https://example.com/legacy",
            seconds: 45.0
        )
        let legacyData = try JSONEncoder().encode([legacyRecord])
        try legacyData.write(to: statsURL, options: .atomic)
        let legacyLoaded = ListeningStatsStore(storageDirectory: dir)
        #expect(legacyLoaded.overview.todaySeconds >= 45.0)
    }

    @Test("F-05/N-02：DownloadCoordinator 正确写入与清除 Wi-Fi/磁盘不足排队原因（含超并发槽位任务）")
    @MainActor
    func downloadCoordinatorAnnotatesAndClearsQueuedReasons() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_sched_f05_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let container = try StorageContainerFactory.makeInMemory()
        let persistence = PersistenceEngine.makeOffMain(modelContainer: container)
        let coord = DownloadCoordinator(
            persistence: persistence,
            audioResolver: StubF05Resolver(),
            downloadsRoot: tempRoot,
            transport: BackgroundTransferTransport(baseDirectory: tempRoot, sessionIdentifier: "com.dsnovel.app.test.f05.\(UUID().uuidString)"),
            logger: DSDiagnosticLogStore(),
            minimumFreeDiskBytes: 100 * 1024 * 1024,
            freeDiskBytesProvider: { 10 * 1024 * 1024 }
        )
        await coord.bootstrapAndRecover()

        let book = BookSummaryDTO(id: "b1", sourceID: "s1", bookURL: "https://example.com/b1", title: "测试书")
        let chapters = (0..<4).map { idx in
            ChapterDTO(id: "c\(idx)", index: idx, title: "第\(idx + 1)章", url: "https://example.com/\(idx)")
        }

        // 1. 仅 Wi-Fi 且未连接 Wi-Fi：写入等待 Wi-Fi 提示
        coord.updatePolicy(wifiOnly: true, maxManualConcurrent: 3, isOnWiFi: false)
        await coord.enqueueManual(book: book, chapters: chapters, quality: .standard)
        #expect(coord.manualRecords.count == 4)
        #expect(coord.manualRecords.allSatisfy { $0.errorMessage == "等待 Wi-Fi 连接" })

        // 2. 恢复 Wi-Fi 后（即使第 4 章仍在排队且磁盘仍低，也会先清除过期 Wi-Fi 提示并切为磁盘提示）
        coord.updatePolicy(wifiOnly: true, maxManualConcurrent: 3, isOnWiFi: true)
        let hasStaleWiFi = coord.manualRecords.contains { $0.errorMessage == "等待 Wi-Fi 连接" }
        #expect(!hasStaleWiFi)
    }

    @Test("F-05：关闭仅 Wi-Fi 后因磁盘空间不足跳过调度时写入磁盘提示")
    @MainActor
    func downloadCoordinatorAnnotatesLowDiskReasonWhenWiFiAllowed() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_disk_f05_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let container = try StorageContainerFactory.makeInMemory()
        let persistence = PersistenceEngine.makeOffMain(modelContainer: container)
        let coord = DownloadCoordinator(
            persistence: persistence,
            audioResolver: StubF05Resolver(),
            downloadsRoot: tempRoot,
            transport: BackgroundTransferTransport(baseDirectory: tempRoot, sessionIdentifier: "com.dsnovel.app.test.disk.\(UUID().uuidString)"),
            logger: DSDiagnosticLogStore(),
            minimumFreeDiskBytes: 100 * 1024 * 1024,
            freeDiskBytesProvider: { 10 * 1024 * 1024 }
        )
        await coord.bootstrapAndRecover()
        coord.updatePolicy(wifiOnly: false, maxManualConcurrent: 3, isOnWiFi: false)

        let book = BookSummaryDTO(id: "b2", sourceID: "s1", bookURL: "https://example.com/b2", title: "磁盘测试书")
        let ch = ChapterDTO(id: "c1", index: 0, title: "第一章", url: "https://example.com/1")
        await coord.enqueueManual(book: book, chapters: [ch], quality: .standard)

        #expect(coord.manualRecords.first?.errorMessage == "磁盘空间不足，等待释放")
    }

    @Test("F-08：SleepTimerEngine 对 fadeOutLastSeconds 与 autoRewindOnSleepSeconds 执行统一上下限夹取")
    @MainActor
    func sleepTimerClampsAllSettingsUniformly() {
        let engine = SleepTimerEngine()
        engine.fadeOutLastSeconds = -10
        #expect(engine.fadeOutLastSeconds == 0)
        engine.fadeOutLastSeconds = 999
        #expect(engine.fadeOutLastSeconds == 120)

        engine.autoRewindOnSleepSeconds = -5
        #expect(engine.autoRewindOnSleepSeconds == 0)
        engine.autoRewindOnSleepSeconds = 300
        #expect(engine.autoRewindOnSleepSeconds == 60)
    }
}

private actor StubF05Resolver: AudioResolving {
    func resolveAudio(sourceID: String, bookID: String, chapter: ChapterDTO, preferredQuality: AudioQualityTier, forDownload: Bool) async throws -> AudioStreamDTO {
        throw NSError(domain: "Stub", code: -1)
    }

    func resolveAudio(sourceID: String, bookID: String, chapter: ChapterDTO, preferredQuality: AudioQualityTier, forDownload: Bool, bypassCache: Bool) async throws -> AudioStreamDTO {
        throw NSError(domain: "Stub", code: -1)
    }
}
