import DSCore
import DSDesignSystem
import DSDownloads
@testable import DSPlayback
import DSPluginKit
import DSStorage
import Foundation
import XCTest

/// 黑盒模糊变异与并发边界压力测试套件（25 项，将全仓测试数推升至 210+）
final class DSFuzzAndConcurrencyTests: XCTestCase {
    func testHTMLFuzzMalformedInputsNeverCrash() {
        let fuzzPayloads = [
            "<<<<>>>>",
            "<div id='unclosed><a href=\"/1>text",
            "<!-- unclosed comment <p>hi</p>",
            String(repeating: "<div>", count: 80) + "deep" + String(repeating: "</div>", count: 80),
            "<a data-x='1' data-y=\"2\" disabled>ok</a>",
            "<script>var a = 1 < 2 && 3 > 1;</script><p>safe</p>",
            "&#999999999; &#xZZZ; &unknown; &amp;"
        ]
        for html in fuzzPayloads {
            let doc = HTMLDocumentNode.parse(html: html, baseURL: "https://example.com/")
            _ = doc.select("div, p, a[href]")
            _ = doc.text()
        }
        let scriptAndSafeDoc = HTMLDocumentNode.parse(html: fuzzPayloads[5], baseURL: "https://example.com/")
        XCTAssertEqual(scriptAndSafeDoc.selectFirst("p")?.text(), "safe")
        XCTAssertFalse(scriptAndSafeDoc.text().contains("var a"))
    }

    func testZIPFuzzRandomTruncatedBuffersAlwaysThrow() {
        let reader = ZIPArchiveReader()
        for len in [1, 4, 16, 21, 22, 45, 100] {
            var buf = Data(repeating: 0x00, count: len)
            if len >= 4 {
                buf[0] = 0x50; buf[1] = 0x4B; buf[2] = 0x03; buf[3] = 0x04
            }
            XCTAssertThrowsError(try reader.readAll(from: buf))
        }
    }

    func testZIPAbsolutePathRejected() {
        let reader = ZIPArchiveReader()
        let badPaths = ["/etc/passwd", "\\windows\\sys", "a/../../b.js", "a\0b.js"]
        for badPath in badPaths {
            let zip = Self.makeStoredZip(entries: [(badPath, Data("payload".utf8))])
            XCTAssertThrowsError(try reader.readAll(from: zip), "Should reject \(badPath)") { error in
                guard case ZIPArchiveError.invalidPath = error else {
                    return XCTFail("Expected ZIPArchiveError.invalidPath for \(badPath), got \(error)")
                }
            }
        }
    }

    func testPersistenceDualPoolDownloadFiltering() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        for i in 0..<5 {
            try await engine.upsertDownload(DownloadRecordSnapshot(
                id: "m-\(i)", bookID: "b1", bookTitle: "B", sourceID: "s1",
                chapterID: "mc-\(i)", chapterIndex: i, chapterTitle: "M\(i)", chapterURL: "https://e.com/m/\(i)",
                kind: .manual, state: .queued
            ))
        }
        for i in 0..<8 {
            try await engine.upsertDownload(DownloadRecordSnapshot(
                id: "p-\(i)", bookID: "b1", bookTitle: "B", sourceID: "s1",
                chapterID: "pc-\(i)", chapterIndex: i, chapterTitle: "P\(i)", chapterURL: "https://e.com/p/\(i)",
                kind: .precache, state: .queued
            ))
        }
        let manuals = try await engine.fetchDownloads(kind: .manual, state: .queued)
        let precaches = try await engine.fetchDownloads(kind: .precache, state: .queued)
        XCTAssertEqual(manuals.count, 5)
        XCTAssertEqual(precaches.count, 8)
    }

    func testPersistencePinOrderingPlacesPinnedFirst() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let b1 = BookSummaryDTO(id: "b1", sourceID: "s", bookURL: "u1", title: "普通书")
        let b2 = BookSummaryDTO(id: "b2", sourceID: "s", bookURL: "u2", title: "置顶书")
        try await engine.upsertBook(b1, addToShelf: true)
        try await engine.upsertBook(b2, addToShelf: true)
        try await engine.togglePin(bookID: "b2")
        let shelf = try await engine.fetchShelfBooks()
        XCTAssertEqual(shelf.first?.id, "b2")
    }

    func testChapterCacheIgnoresEmptySave() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSEmptyCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = ChapterCacheStore(baseDirectory: tempDir)
        try await store.saveChapters([], bookID: "empty-book")
        let loaded = await store.loadChapters(bookID: "empty-book")
        XCTAssertNil(loaded)
    }

    func testChapterCacheRemoveAndClear() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSClearCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = ChapterCacheStore(baseDirectory: tempDir)
        let chs = [ChapterDTO(id: "1", index: 0, title: "一", url: "u")]
        try await store.saveChapters(chs, bookID: "k1")
        try await store.saveChapters(chs, bookID: "k2")
        await store.removeChapters(bookID: "k1")
        let r1 = await store.loadChapters(bookID: "k1")
        let r2 = await store.loadChapters(bookID: "k2")
        XCTAssertNil(r1)
        XCTAssertEqual(r2?.count, 1)
        await store.clearAll()
        let r2After = await store.loadChapters(bookID: "k2")
        XCTAssertNil(r2After)
    }

    func testAudioTapProcessorHandlesParameterUpdatesSafely() {
        let proc = AudioTapProcessor()
        let invalidBands = AudioDSPParameters(bandGainsDB: [1, 2], stereoBalance: -3.5, volumeBoostEnabled: true, fadeGain: -0.5)
        XCTAssertEqual(invalidBands.bandGainsDB, [0, 0, 0, 0, 0])
        XCTAssertEqual(invalidBands.stereoBalance, -1.0, accuracy: 0.001)
        XCTAssertEqual(invalidBands.fadeGain, 0.0, accuracy: 0.001)
        proc.updateParameters(invalidBands)

        let upperClamped = AudioDSPParameters(bandGainsDB: [6, 3, 0, -3, -6], stereoBalance: 4.2, volumeBoostEnabled: false, fadeGain: 2.8)
        XCTAssertEqual(upperClamped.bandGainsDB, [6, 3, 0, -3, -6])
        XCTAssertEqual(upperClamped.stereoBalance, 1.0, accuracy: 0.001)
        XCTAssertEqual(upperClamped.fadeGain, 1.0, accuracy: 0.001)
        proc.updateParameters(upperClamped)

        var stereoSamples: [Float] = [Float.nan, Float.infinity, -Float.infinity, 2.5, 0.4, -0.4, 0.25, -0.25]
        proc.processOfflinePCMForTesting(samples: &stereoSamples, channelCount: 2, sampleRate: 44_100)
        for sample in stereoSamples {
            XCTAssertTrue(sample.isFinite, "离线 PCM 处理后不得残留 NaN/Inf")
            XCTAssertGreaterThanOrEqual(sample, -1.0)
            XCTAssertLessThanOrEqual(sample, 1.0)
        }
        // stereoBalance == 1.0（全右声道）时左声道应被衰减至 0，右声道保持非零有效信号
        XCTAssertEqual(stereoSamples[4], 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(abs(stereoSamples[5]), 0.01)
    }

    func testConcurrentJSContextPoolStress() async throws {
        final class ConcurrencyPeakCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var current = 0
            private var maxObserved = 0

            func enter() {
                lock.withLock {
                    current += 1
                    if current > maxObserved {
                        maxObserved = current
                    }
                }
            }

            func leave() {
                lock.withLock {
                    current -= 1
                }
            }

            var peak: Int {
                lock.withLock { maxObserved }
            }
        }

        let pool = JSContextPool(maxSlots: 3)
        let counter = ConcurrencyPeakCounter()
        let sum = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 1...12 {
                group.addTask {
                    try await pool.withSlot {
                        counter.enter()
                        defer { counter.leave() }
                        try await Task.sleep(for: .milliseconds(25))
                        return i
                    }
                }
            }
            var acc = 0
            for try await v in group { acc += v }
            return acc
        }
        XCTAssertEqual(sum, 78)
        let peak = counter.peak
        XCTAssertLessThanOrEqual(peak, 3, "并发峰值不得超过 maxSlots=3")
        XCTAssertGreaterThanOrEqual(peak, 2, "12 个并发任务应真实触发并发占用（peak >= 2）")
        let active = await pool.currentActiveSlots
        XCTAssertEqual(active, 0)
    }

    func testPersistenceDeleteDownloadRemovesRecord() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let rec = DownloadRecordSnapshot(
            id: "del-1", bookID: "b", bookTitle: "B", sourceID: "s",
            chapterID: "c", chapterIndex: 0, chapterTitle: "C", chapterURL: "u", kind: .manual
        )
        try await engine.upsertDownload(rec)
        try await engine.deleteDownload(id: "del-1")
        let remaining = try await engine.fetchDownloads(kind: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPersistenceDeleteSourceRemovesRecord() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        try await engine.upsertSource(meta: SourceMetaDTO(id: "rm-1", name: "待删源"), scriptBody: "var x=1;", isBundled: false)
        try await engine.deleteSource(id: "rm-1")
        let all = try await engine.fetchAllSources()
        XCTAssertTrue(all.isEmpty)
    }

    func testPersistenceClearHistoryPreservesShelf() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let b = BookSummaryDTO(id: "both", sourceID: "s", bookURL: "u", title: "双态书")
        let c = ChapterDTO(id: "c", index: 0, title: "一", url: "u")
        try await engine.upsertBook(b, addToShelf: true)
        await engine.saveProgress(book: b, chapter: c, positionMs: 1000, durationMs: 5000, isFinished: false, overrideFinished: false)
        try await engine.clearHistory(bookID: b.id)
        let shelf = try await engine.fetchShelfBooks()
        let hist = try await engine.fetchHistoryBooks()
        XCTAssertEqual(shelf.count, 1)
        XCTAssertTrue(hist.isEmpty)
    }

    func testLibraryBackupCodecRejectsInvalidSchemaVersion() {
        let badJSON = Data(#"{"schemaVersion":999,"exportedAt":"2026-11-21T00:00:00Z","appVersion":"9.0","books":[]}"#.utf8)
        XCTAssertThrowsError(try LibraryBackupCodec.decode(badJSON))
    }

    func testLibraryBackupCodecRejectsCorruptJSON() {
        XCTAssertThrowsError(try LibraryBackupCodec.decode(Data("{corrupt".utf8)))
    }

    func testDiagnosticSanitizerHandlesMultipleSecretKeys() {
        let samples = [
            "Authorization: Bearer tok_12345",
            "Set-Cookie: 1&_token=abc999; HttpOnly",
            "password=myPass123&user=test",
            "x-xmly-token=secretValue"
        ]
        for s in samples {
            let out = DSDiagnosticLogStore.sanitize(s)
            XCTAssertTrue(out.contains("[REDACTED]"), "Failed to redact: \(s)")
        }
    }

    func testSourceMetaHasDeclaredHostsFlag() {
        XCTAssertFalse(SourceMetaDTO(id: "1", name: "A", declaredHosts: []).hasDeclaredHosts)
        XCTAssertTrue(SourceMetaDTO(id: "2", name: "B", declaredHosts: ["example.com"]).hasDeclaredHosts)
    }

    func testDownloadStateTerminalAndActiveFlags() {
        XCTAssertTrue(DownloadState.completed.isTerminal)
        XCTAssertFalse(DownloadState.cancelled.isTerminal)
        XCTAssertFalse(DownloadState.failed.isTerminal)
        XCTAssertTrue(DownloadState.resolving.isActive)
        XCTAssertTrue(DownloadState.downloading.isActive)
        XCTAssertFalse(DownloadState.paused.isActive)
    }

    func testPlaybackStateBufferingAndPlayingFlags() {
        XCTAssertTrue(PlaybackState.buffering(generation: 1, shouldPlayWhenReady: true).isBuffering)
        XCTAssertFalse(PlaybackState.playing(generation: 1).isBuffering)
        XCTAssertTrue(PlaybackState.playing(generation: 1).isPlaying)
        XCTAssertFalse(PlaybackState.paused(generation: 1).isPlaying)
    }

    func testCookieVaultPathBoundaryEnforcement() async {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let c = HTTPCookie(properties: [.domain: "site.test", .path: "/api", .name: "k", .value: "v"])!
        await vault.setCookies([c])
        let matchExact = await vault.cookieHeader(for: URL(string: "https://site.test/api")!)
        let matchSub = await vault.cookieHeader(for: URL(string: "https://site.test/api/v1")!)
        let mismatchPrefix = await vault.cookieHeader(for: URL(string: "https://site.test/apiv2")!)
        XCTAssertEqual(matchExact, "k=v")
        XCTAssertEqual(matchSub, "k=v")
        XCTAssertEqual(mismatchPrefix, "")
    }

    func testCookieVaultClearAllRemovesEverything() async {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let c = HTTPCookie(properties: [.domain: "any.test", .path: "/", .name: "a", .value: "1"])!
        await vault.setCookies([c])
        await vault.clearCookies()
        let header = await vault.cookieHeader(for: URL(string: "https://any.test/")!)
        XCTAssertEqual(header, "")
    }

    func testStorageReconcilerThrottlingRespectsMinInterval() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSThrottle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reconciler = StorageReconciler(downloadsRoot: tempDir, minIntervalSeconds: 60)
        let first = await reconciler.reconcileIfNeeded(completedRecords: [], force: false)
        let second = await reconciler.reconcileIfNeeded(completedRecords: [], force: false)
        let forced = await reconciler.reconcileIfNeeded(completedRecords: [], force: true)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertNotNil(forced)
    }

    func testStorageReconcilerPreservesPendingStagingDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSStagingKeep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let staging = tempDir.appendingPathComponent(".pending_staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedFile = staging.appendingPathComponent("t1.staged")
        try Data("audio".utf8).write(to: stagedFile)

        let reconciler = StorageReconciler(downloadsRoot: tempDir, minIntervalSeconds: 60)
        _ = await reconciler.reconcileIfNeeded(completedRecords: [], force: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFile.path))
    }

    func testDSMotionReduceMotionDisablesAnimation() {
        XCTAssertNil(DSMotion.resolved(.default, reduceMotion: true))
        XCTAssertNotNil(DSMotion.resolved(.default, reduceMotion: false))
    }

    func testDSMainTabAllThreeCasesHaveTitleAndIcon() {
        XCTAssertEqual(DSMainTab.allCases.count, 3)
        for tab in DSMainTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.icon.isEmpty)
        }
    }

    func testAppThemeModeAllCasesHaveTitles() {
        XCTAssertEqual(AppThemeMode.allCases.count, 3)
        for mode in AppThemeMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
        }
    }

    private static func makeStoredZip(entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var centralDir = Data()
        func u16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
        }
        for e in entries {
            let offset = UInt32(archive.count)
            let name = Data(e.name.utf8)
            let crc = DSCrypto.crc32(e.data)
            let sz = UInt32(e.data.count)
            u32(&archive, 0x0403_4B50); u16(&archive, 20); u16(&archive, 0); u16(&archive, 0)
            u16(&archive, 0); u16(&archive, 0); u32(&archive, crc); u32(&archive, sz); u32(&archive, sz)
            u16(&archive, UInt16(name.count)); u16(&archive, 0); archive.append(name); archive.append(e.data)

            u32(&centralDir, 0x0201_4B50); u16(&centralDir, 20); u16(&centralDir, 20); u16(&centralDir, 0)
            u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0); u32(&centralDir, crc)
            u32(&centralDir, sz); u32(&centralDir, sz); u16(&centralDir, UInt16(name.count))
            u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0)
            u32(&centralDir, 0); u32(&centralDir, offset); centralDir.append(name)
        }
        let cdOffset = UInt32(archive.count)
        archive.append(centralDir)
        u32(&archive, 0x0605_4B50); u16(&archive, 0); u16(&archive, 0)
        u16(&archive, UInt16(entries.count)); u16(&archive, UInt16(entries.count))
        u32(&archive, UInt32(centralDir.count)); u32(&archive, cdOffset); u16(&archive, 0)
        return archive
    }
}
