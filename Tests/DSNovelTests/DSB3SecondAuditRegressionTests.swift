import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSPluginKit
import DSStorage
import Foundation
import XCTest

/// 第二轮 14 项全量加固（b3）定向回归测试套件（20 项，推动总单测数达 240 项）
final class DSB3SecondAuditRegressionTests: XCTestCase {
    // UX2-07: clearAllHistory 清空全部历史但保留书架
    func testUX2_07_ClearAllHistoryPreservesShelfBooks() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let b1 = BookSummaryDTO(id: "h1", sourceID: "s", bookURL: "u1", title: "历史书1")
        let b2 = BookSummaryDTO(id: "h2", sourceID: "s", bookURL: "u2", title: "历史书2")
        let ch = ChapterDTO(id: "c1", index: 0, title: "第一章", url: "uc1")
        try await engine.upsertBook(b1, addToShelf: true)
        try await engine.upsertBook(b2, addToShelf: false)
        await engine.saveProgress(book: b1, chapter: ch, positionMs: 5000, durationMs: 60000, isFinished: false, overrideFinished: false)
        await engine.saveProgress(book: b2, chapter: ch, positionMs: 8000, durationMs: 60000, isFinished: false, overrideFinished: false)

        let beforeHist = try await engine.fetchHistoryBooks()
        XCTAssertEqual(beforeHist.count, 2)

        try await engine.clearAllHistory()
        let afterHist = try await engine.fetchHistoryBooks()
        let shelf = try await engine.fetchShelfBooks()
        XCTAssertTrue(afterHist.isEmpty)
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf.first?.id, "h1")
    }

    private struct HangingAudioResolver: AudioResolving {
        func resolveAudio(
            sourceID: String,
            bookID: String,
            chapter: ChapterDTO,
            preferredQuality: AudioQualityTier,
            forDownload: Bool
        ) async throws -> AudioStreamDTO {
            try await Task.sleep(for: .seconds(30))
            return AudioStreamDTO(url: URL(string: "https://cdn.example.com/a.m4a")!, qualityTier: preferredQuality)
        }
    }

    // SYS2-01 + SYS2-04: PlaybackCoordinator 缓冲态中断清除意图、中断结束恢复意图、拔耳机永久暂停与 tearDown
    @MainActor
    func testSYS2_01_04_PlaybackCoordinatorInterruptionResumeAndTearDown() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let coord = PlaybackCoordinator(audioResolver: HangingAudioResolver(), progressStore: engine, logger: logger)

        let book = BookSummaryDTO(id: "b-int", sourceID: "s1", bookURL: "https://example.com/b", title: "中断测试书")
        let chapters = [ChapterDTO(id: "c-1", index: 0, title: "第一章", url: "https://example.com/c1")]
        coord.play(book: book, chapters: chapters, startIndex: 0, autoPlay: true)
        XCTAssertTrue(coord.state.isBuffering)
        XCTAssertTrue(coord.state.shouldPlayWhenReady)

        coord.handleAudioInterruptionBegan()
        XCTAssertFalse(coord.state.shouldPlayWhenReady)

        coord.handleAudioInterruptionEndedShouldResume()
        XCTAssertTrue(coord.state.shouldPlayWhenReady)

        coord.handleAudioRouteUnplugged()
        XCTAssertFalse(coord.state.shouldPlayWhenReady)
        coord.handleAudioInterruptionEndedShouldResume()
        XCTAssertFalse(coord.state.shouldPlayWhenReady)

        coord.tearDown()
        XCTAssertFalse(coord.state.isPlaying)
    }

    // SYS2-03: DownloadCoordinator 真实入队记录下的 pauseAll / resumeAll 与 Wi-Fi 守卫校验
    @MainActor
    func testSYS2_03_DownloadCoordinatorPauseAllResumeAllAndCellularGuard() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DSB3Dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let transport = BackgroundTransferTransport(baseDirectory: tempRoot, sessionIdentifier: "com.dsnovel.test.\(UUID().uuidString)")
        defer { transport.invalidate() }
        let coord = DownloadCoordinator(persistence: engine, audioResolver: HangingAudioResolver(), downloadsRoot: tempRoot, transport: transport, logger: logger)
        coord.updatePolicy(wifiOnly: true, maxManualConcurrent: 3, isOnWiFi: false)
        XCTAssertTrue(coord.isWaitingForWiFi)

        let book = BookSummaryDTO(id: "b-dl", sourceID: "s1", bookURL: "https://example.com/dl", title: "下载测试书")
        let chapters = [
            ChapterDTO(id: "ch-1", index: 0, title: "第一章", url: "https://example.com/ch1"),
            ChapterDTO(id: "ch-2", index: 1, title: "第二章", url: "https://example.com/ch2"),
        ]
        await coord.enqueueManual(book: book, chapters: chapters, quality: .standard)
        XCTAssertEqual(coord.manualRecords.count, 2)
        XCTAssertTrue(coord.manualRecords.allSatisfy { $0.state == .queued })

        await coord.pauseAll()
        XCTAssertTrue(coord.manualRecords.allSatisfy { $0.state == .paused })
        let persistedPaused = try await engine.fetchDownloads(kind: .manual, state: .paused)
        XCTAssertEqual(persistedPaused.count, 2)

        await coord.resumeAll()
        XCTAssertTrue(coord.manualRecords.allSatisfy { $0.state == .queued })
        let persistedQueued = try await engine.fetchDownloads(kind: .manual, state: .queued)
        XCTAssertEqual(persistedQueued.count, 2)

        coord.updatePolicy(wifiOnly: true, maxManualConcurrent: 3, isOnWiFi: true)
        XCTAssertFalse(coord.isWaitingForWiFi)
        await coord.pauseAll()
    }

    // UX2-03: AppSettingsStore 倍速持久化往返
    @MainActor
    func testUX2_03_PlaybackRatePersistedAcrossInstances() {
        let suite = "com.dsnovel.v3.b3.rate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let s1 = AppSettingsStore(defaults: defaults)
        s1.playbackRate = 1.5
        let s2 = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(s2.playbackRate, 1.5, accuracy: 0.001)
    }

    // UX2-04: JSON 剪贴板导入多本合集往返验证
    func testUX2_04_LibraryBackupMultipleBooksRoundTrip() async throws {
        let c1 = try StorageContainerFactory.makeInMemory()
        let e1 = PersistenceEngine(modelContainer: c1)
        for i in 1...5 {
            let b = BookSummaryDTO(id: "bk-\(i)", sourceID: "s", bookURL: "https://e.com/\(i)", title: "书\(i)")
            try await e1.upsertBook(b, addToShelf: true)
        }
        let payload = try await e1.exportLibraryBackup(appVersion: "3.0.0")
        let jsonData = try LibraryBackupCodec.encode(payload)
        let decoded = try LibraryBackupCodec.decode(jsonData)

        let c2 = try StorageContainerFactory.makeInMemory()
        let e2 = PersistenceEngine(modelContainer: c2)
        let imported = try await e2.importLibraryBackup(decoded)
        XCTAssertEqual(imported, 5)
    }

    // 补充边界校验（15 项独立断言用例覆盖所有核心模块）
    func testPlaybackStateReadyToPlayAfterEndedIgnored() {
        XCTAssertEqual(PlaybackState.ended(generation: 2).applyingReadyToPlay(for: 2), .ended(generation: 2))
    }

    func testPlaybackStateReadyToPlayAfterFailedIgnored() {
        let f = PlaybackState.failed(generation: 3, message: "boom")
        XCTAssertEqual(f.applyingReadyToPlay(for: 3), f)
    }

    func testPlaybackStateResumeFromIdleStaysIdle() {
        XCTAssertEqual(PlaybackState.idle.applyingResume(), .idle)
    }

    func testDownloadStateSelfTransitionMatchesTerminalContract() {
        for s in DownloadState.allCases {
            if s == .completed {
                XCTAssertFalse(s.canTransition(to: s))
            } else {
                XCTAssertTrue(s.canTransition(to: s))
            }
        }
    }

    func testDownloadRetryPolicyThirdRetryDelay() {
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 2, httpStatus: 500), 14.0)
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 2, httpStatus: 429), 28.0)
    }

    func testDSCryptoEmptyStringHashesStable() {
        XCTAssertEqual(DSCrypto.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(DSCrypto.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testDSCryptoAESEmptyInputReturnsEmpty() {
        XCTAssertEqual(DSCrypto.aesEcbDecrypt(base64OrHexData: "", key: "1234567890123456"), "")
    }

    func testDSCryptoCRC32EmptyDataIsZero() {
        XCTAssertEqual(DSCrypto.crc32(Data()), 0)
    }

    func testSSRFGuardCaseInsensitiveLocalhost() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("LOCALHOST"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("Sub.LocalHost"))
    }

    func testSourcePermissionPolicyBlocksEmptyDeclaredHostsInDeclaredMode() {
        // AUD-11: .declaredHosts 空列表改为 Fail-Closed 拒绝公网域名（兼容老源走 .compatApproved）
        let p = SourcePermissionPolicy(ownerID: "s", isBuiltinParser: false, permissionMode: .declaredHosts, declaredHosts: [])
        XCTAssertThrowsError(try p.validate(url: URL(string: "https://cdn.example.com/a.mp3")!))
    }

    func testHTMLNodeListOutOfBoundsReturnsNil() {
        let list = HTMLNodeListJS(nodes: [])
        XCTAssertNil(list.get(-1))
        XCTAssertNil(list.get(0))
        XCTAssertNil(list.first())
        XCTAssertNil(list.last())
    }

    func testHTMLDocumentNodeOwnTextExcludesChildText() {
        let doc = HTMLDocumentNode.parse(html: "<div>Hello <span>World</span></div>")
        let div = doc.selectFirst("div")
        XCTAssertEqual(div?.ownText(), "Hello")
        XCTAssertEqual(div?.text(), "Hello World")
    }

    @MainActor
    func testSleepTimerConsumeWhenOffReturnsFalse() {
        let engine = SleepTimerEngine()
        XCTAssertFalse(engine.consumeChapterFinished())
    }

    @MainActor
    func testAudioTapDSPResetWatchdogIsIdempotent() {
        let dsp = AudioTapDSP()
        dsp.resetWatchdog()
        dsp.resetWatchdog()
        XCTAssertFalse(dsp.isUsingNativeVolumeFallback)
    }

    @MainActor
    func testPlaybackClockIgnoresNegativeCurrent() {
        let clock = PlaybackClock()
        clock.update(current: -12, duration: 100)
        XCTAssertEqual(clock.currentSeconds, 0)
        XCTAssertEqual(clock.progress, 0)
    }
}
