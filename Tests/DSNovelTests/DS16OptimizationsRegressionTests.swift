import AVFoundation
import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSPluginKit
import DSStorage
import Foundation
import UIKit
import XCTest

/// 16 项十轮审计优化定向回归测试套件（验证全部 P0/P1/P2 改造点无回归）
final class DS16OptimizationsRegressionTests: XCTestCase {
    // ARC-01: 整理模式 updateSourceOrganization 必须真实落盘分组/排序/启停
    func testARC01_UpdateSourceOrganizationPersistsGroupAndOrder() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        try await engine.upsertSource(
            meta: SourceMetaDTO(id: "src-org", name: "测试源", isEnabled: true, isPinned: false, groupName: "默认分组", sortOrder: 0),
            scriptBody: "var x = 1;",
            isBundled: false
        )
        try await engine.updateSourceOrganization(
            id: "src-org",
            isEnabled: false,
            isPinned: true,
            groupName: "玄幻精选",
            sortOrder: 5
        )
        let fetched = try await engine.fetchAllSources().first(where: { $0.meta.id == "src-org" })?.meta
        XCTAssertEqual(fetched?.isEnabled, false)
        XCTAssertEqual(fetched?.isPinned, true)
        XCTAssertEqual(fetched?.groupName, "玄幻精选")
        XCTAssertEqual(fetched?.sortOrder, 5)
    }

    // UI-03: 详情页续播进度读取
    func testUI03_FetchBookLastPlaybackReturnsSavedChapter() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        let book = BookSummaryDTO(id: "b-resume", sourceID: "s", bookURL: "u", title: "续播测试")
        let ch = ChapterDTO(id: "c-42", index: 41, title: "第四十二章", url: "u42")
        let before = await engine.fetchBookLastPlayback(bookID: book.id)
        XCTAssertNil(before)

        await engine.saveProgress(book: book, chapter: ch, positionMs: 33_000, durationMs: 180_000, isFinished: false, overrideFinished: false)
        let after = await engine.fetchBookLastPlayback(bookID: book.id)
        XCTAssertEqual(after?.chapterIndex, 41)
        XCTAssertEqual(after?.chapterTitle, "第四十二章")
        XCTAssertEqual(after?.positionMs, 33_000)
    }

    // ARC-06: 分页拉取突破单页限制，支持千章下载恢复
    func testARC06_FetchAllDownloadsPaginatedLoadsAcrossPages() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        for i in 0..<120 {
            try await engine.upsertDownload(DownloadRecordSnapshot(
                id: "pg-\(i)", bookID: "b-big", bookTitle: "千章书", sourceID: "s",
                chapterID: "c-\(i)", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterURL: "https://e.com/\(i)",
                kind: i % 2 == 0 ? .manual : .precache,
                state: i % 3 == 0 ? .completed : .queued
            ))
        }
        let all = try await engine.fetchAllDownloadsPaginated(pageSize: 50)
        XCTAssertEqual(all.count, 120)

        let manualQueued = try await engine.fetchDownloads(kind: .manual, state: .queued, limit: 200)
        XCTAssertEqual(manualQueued.count, 40)
    }

    // UI-02 + ARC-08: NetworkReachabilityMonitor 触发网络切换回调
    @MainActor
    func testUI02_NetworkReachabilityMonitorFiresOnWiFiSwitch() {
        let monitor = NetworkReachabilityMonitor(startImmediately: false)
        var observedEvents: [Bool] = []
        monitor.setOnNetworkTypeChanged { isWiFi in
            observedEvents.append(isWiFi)
        }
        monitor.simulateState(connected: true, onWiFi: false)
        monitor.simulateState(connected: true, onWiFi: false) // 相同状态不重复触发
        monitor.simulateState(connected: true, onWiFi: true)
        XCTAssertEqual(observedEvents, [false, true])
        XCTAssertTrue(monitor.isOnWiFi)
        XCTAssertFalse(monitor.isExpensive)
    }

    // UI-07: CoverImagePipeline 同步内存快路径零闪烁命中
    func testUI07_CoverImagePipelineSyncMemoryCacheHit() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSCoverSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pipeline = CoverImagePipeline(diskDirectory: tempDir)
        let key = "https://cdn.example.com/cover.jpg"
        XCTAssertNil(pipeline.cachedImageSync(for: key))

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let img = renderer.image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        await pipeline.storeInMemoryForTesting(img, urlString: key)
        XCTAssertNotNil(pipeline.cachedImageSync(for: key))
    }

    // ARC-04: BuiltinParserEngine 冷启从磁盘恢复并拦截被篡改的脚本
    func testARC04_BuiltinParserEngineReloadsFromDiskAndRejectsTamperedSHA() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSParserReload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let client = HostHTTPClient(cookieVault: vault)
        let logger = DSDiagnosticLogStore()
        let prelude = """
        var __parsers = [];
        function registerBuiltinParser(p){ __parsers.push(p); return p; }
        function __metaParser(){ return JSON.stringify(__parsers.map(function(p){ return { id:p.id, name:p.name, version:p.version||'1.0.0', hosts:p.targets.hosts||[], sourceIDs:p.targets.sourceIDs||[] }; })); }
        """
        let script = """
        registerBuiltinParser({
          id: 'xmly-reloaded',
          name: 'XMLY Parser',
          version: '1.2.0',
          targets: { hosts: ['ximalaya.com'], sourceIDs: ['ximalaya'] },
          resolveAudio: function(req) { return { url: 'https://www.ximalaya.com/a.m4a' }; }
        });
        """

        let engine1 = BuiltinParserEngine(preludeParserScript: prelude, storageDir: tempDir, httpClient: client, cookieVault: vault, logger: logger)
        let installed = try await engine1.installParser(scriptBody: script)
        XCTAssertEqual(installed.id, "xmly-reloaded")

        // 模拟冷启新实例，应自动恢复 1 个解析器
        let engine2 = BuiltinParserEngine(preludeParserScript: prelude, storageDir: tempDir, httpClient: client, cookieVault: vault, logger: logger)
        let count = await engine2.loadPersistedParsers()
        XCTAssertEqual(count, 1)
        let list = await engine2.listParsers()
        XCTAssertEqual(list.first?.id, "xmly-reloaded")

        // 篡改磁盘 script.js 后冷启，SHA-256 校验失败必须拒绝加载
        let tamperedURL = tempDir
            .appendingPathComponent(DSCrypto.sha256Hex("xmly-reloaded"), isDirectory: true)
            .appendingPathComponent("script.js")
        try Data("/* tampered */".utf8).write(to: tamperedURL)

        let engine3 = BuiltinParserEngine(preludeParserScript: prelude, storageDir: tempDir, httpClient: client, cookieVault: vault, logger: logger)
        let tamperedCount = await engine3.loadPersistedParsers()
        XCTAssertEqual(tamperedCount, 0)
    }

    // ARC-05: CookieVault.matchingCookies 供无头浏览器预注入
    func testARC05_CookieVaultMatchingCookiesFiltersCorrectly() async {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let valid = HTTPCookie(properties: [.domain: "m.ximalaya.com", .path: "/", .name: "1&_token", .value: "ok", .secure: "TRUE"])!
        let other = HTTPCookie(properties: [.domain: "other.com", .path: "/", .name: "x", .value: "1"])!
        await vault.setCookies([valid, other])

        let httpsMatched = await vault.matchingCookies(for: URL(string: "https://m.ximalaya.com/sound/1")!)
        let httpMatched = await vault.matchingCookies(for: URL(string: "http://m.ximalaya.com/sound/1")!)
        XCTAssertEqual(httpsMatched.count, 1)
        XCTAssertEqual(httpsMatched.first?.name, "1&_token")
        XCTAssertTrue(httpMatched.isEmpty)
    }

    // ARC-03: AudioTapProcessor 离音频线程连续高频切换预设并验证越界 DSP 参数钳制
    func testARC03_AudioTapProcessorRapidPresetSwitchingOffAudioThread() {
        let processor = AudioTapProcessor()
        for preset in AudioEQPreset.allCases {
            let params = AudioDSPParameters(
                bandGainsDB: preset.bandGainsDB,
                stereoBalance: 1.8,
                volumeBoostEnabled: true,
                fadeGain: 1.5
            )
            XCTAssertEqual(params.bandGainsDB, preset.bandGainsDB)
            XCTAssertEqual(params.stereoBalance, 1.0, accuracy: 0.001)
            XCTAssertEqual(params.fadeGain, 1.0, accuracy: 0.001)
            processor.updateParameters(params)
        }
        let fallbackBands = AudioDSPParameters(bandGainsDB: [1, 2, 3], stereoBalance: -9.0, fadeGain: -0.25)
        XCTAssertEqual(fallbackBands.bandGainsDB, [0, 0, 0, 0, 0])
        XCTAssertEqual(fallbackBands.stereoBalance, -1.0, accuracy: 0.001)
        XCTAssertEqual(fallbackBands.fadeGain, 0.0, accuracy: 0.001)
        processor.updateParameters(fallbackBands)
    }

    // UI-02: DownloadCoordinator 真实队列下动态更新 Wi-Fi 策略与并发上限
    @MainActor
    func testUI02_DownloadCoordinatorDynamicPolicyUpdate() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let vault = CookieVault(inMemorySecretsOnly: true)
        let client = HostHTTPClient(cookieVault: vault)
        let runtime = PluginRuntime(preludeScript: "", httpClient: client, cookieVault: vault, logger: logger)
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DSDlPol-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let transport = BackgroundTransferTransport(baseDirectory: tempRoot, sessionIdentifier: "com.dsnovel.test.\(UUID().uuidString)")
        defer { transport.invalidate() }
        let coord = DownloadCoordinator(persistence: engine, audioResolver: runtime, downloadsRoot: tempRoot, transport: transport, logger: logger)
        coord.updatePolicy(wifiOnly: true, maxManualConcurrent: 5, isOnWiFi: false)
        XCTAssertTrue(coord.isWaitingForWiFi)

        let book = BookSummaryDTO(id: "b-pol", sourceID: "s1", bookURL: "https://example.com/pol", title: "策略测试书")
        let chapters = [
            ChapterDTO(id: "p1", index: 0, title: "一", url: "https://example.com/p1"),
            ChapterDTO(id: "p2", index: 1, title: "二", url: "https://example.com/p2"),
        ]
        await coord.enqueueManual(book: book, chapters: chapters, quality: .standard)
        XCTAssertEqual(coord.manualRecords.count, 2)
        XCTAssertTrue(coord.manualRecords.allSatisfy { $0.state == .queued })

        coord.updatePolicy(wifiOnly: false, maxManualConcurrent: 2, isOnWiFi: false)
        XCTAssertFalse(coord.isWaitingForWiFi)
        await coord.pauseAll()
        XCTAssertTrue(coord.manualRecords.allSatisfy { $0.state == .paused })
    }

    // UI-04: AudioTapDSP 睡眠渐弱因子越界钳制与原生音量降级联动
    @MainActor
    func testUI04_AudioTapDSPSleepFadeClamping() {
        let dsp = AudioTapDSP()
        let player = AVPlayer()

        dsp.applyFadeVolume(to: player, factor: -0.5)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 0.0, accuracy: 0.001)
        XCTAssertEqual(player.volume, 1.0, accuracy: 0.001)

        dsp.applyFadeVolume(to: player, factor: 2.5)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 1.0, accuracy: 0.001)

        dsp.applyFadeVolume(to: player, factor: 0.4)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 0.4, accuracy: 0.001)

        dsp.activateFallback(reason: "fallback-test")
        dsp.applyFadeVolume(to: player, factor: 0.35)
        XCTAssertEqual(player.volume, 0.35, accuracy: 0.001)
        XCTAssertEqual(dsp.currentParameters().fadeGain, 1.0, accuracy: 0.001)

        dsp.preset = .night
        XCTAssertEqual(dsp.currentParameters().bandGainsDB, AudioEQPreset.night.bandGainsDB)
    }
}
