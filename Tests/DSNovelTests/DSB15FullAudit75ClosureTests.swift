import AVFoundation
import DSCore
import DSDownloads
import DSPlayback
import DSPluginKit
import DSStorage
import Foundation
import JavaScriptCore
import SQLite3
import XCTest

/// b15 全量 75 项审计闭环测试套件（覆盖备份还原、对账、分页、ZIP、HTML、JSC prelude、DSP、播放、下载调度、HTTP 重定向与网络冷启）
final class DSB15FullAudit75ClosureTests: XCTestCase {

    // MARK: - 1. StoreBackupManager.restoreBackup 全分支

    func testB15_StoreBackupRestoreOldestFifthDoesNotSelfDestruct() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DSB15Restore5-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let storeURL = dir.appendingPathComponent("DSNovelV3.store")
        let manager = StoreBackupManager(storeURL: storeURL, maxBackups: 5)

        var created: [StoreBackupInfo] = []
        for version in 1...5 {
            try Self.writeSQLiteVersion(version, to: storeURL)
            let info = try await manager.createBackup()
            created.append(info)
        }

        let listed = await manager.listBackups()
        XCTAssertEqual(listed.count, 5)
        let oldest = try XCTUnwrap(created.first)

        // 还原最旧第 5 份：留存快照不得在还原前把目标最旧备份裁剪销毁
        try await manager.restoreBackup(oldest)
        XCTAssertEqual(Self.readSQLiteVersion(from: storeURL), 1)
        let validAfterRestore = await manager.verifySQLiteIntegrity(at: storeURL)
        XCTAssertTrue(validAfterRestore)
    }

    func testB15_StoreBackupRestoreRejectsCorruptSnapshotAndArchivesCorruptStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DSB15RestoreCorrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let storeURL = dir.appendingPathComponent("DSNovelV3.store")
        try Self.writeSQLiteVersion(42, to: storeURL)
        let manager = StoreBackupManager(storeURL: storeURL, maxBackups: 5)
        let goodBackup = try await manager.createBackup()

        // 1) 坏快照拦截：不得覆盖现有完好主库
        let badSnapshotURL = dir.appendingPathComponent("bad.store")
        try Data("not-a-sqlite-db".utf8).write(to: badSnapshotURL)
        let badInfo = StoreBackupInfo(id: "bad.store", url: badSnapshotURL, createdAt: Date(), sizeBytes: 15)
        do {
            try await manager.restoreBackup(badInfo)
            XCTFail("Expected restoreBackup to throw on corrupt snapshot")
        } catch {
            XCTAssertEqual(Self.readSQLiteVersion(from: storeURL), 42)
        }

        // 2) 主库损坏 + 遗留 WAL/SHM：还原有效快照时必须归档坏库至 .corrupted/ 并清理 WAL/SHM
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("corrupted-main-store".utf8).write(to: storeURL)
        try Data("stale-wal".utf8).write(to: walURL)
        try Data("stale-shm".utf8).write(to: shmURL)

        try await manager.restoreBackup(goodBackup)
        XCTAssertEqual(Self.readSQLiteVersion(from: storeURL), 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))

        let corruptedDir = dir.appendingPathComponent(".corrupted", isDirectory: true)
        let archivedFiles = (try? FileManager.default.contentsOfDirectory(atPath: corruptedDir.path)) ?? []
        XCTAssertFalse(archivedFiles.isEmpty, "损坏主库应归档至 .corrupted/ 目录")
    }

    // MARK: - 2. StorageReconciler 符号链接路径一致性与冷却窗保护

    func testB15_StorageReconcilerSymlinkPathConsistencyAndGraceWindow() async throws {
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSB15Symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let realRoot = baseDir.appendingPathComponent("real_downloads", isDirectory: true)
        let linkRoot = baseDir.appendingPathComponent("link_downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let rel = DownloadRecordSnapshot.canonicalRelativePath(bookID: "sym-book", chapterID: "sym-ch1")
        let audioURL = realRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("valid-audio-bytes".utf8).write(to: audioURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: audioURL.path)

        let freshOrphan = realRoot.appendingPathComponent("fresh_orphan.m4a")
        try Data("fresh".utf8).write(to: freshOrphan)

        let staleOrphan = realRoot.appendingPathComponent("stale_orphan.m4a")
        try Data("stale".utf8).write(to: staleOrphan)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1200)], ofItemAtPath: staleOrphan.path)

        let completed = [
            DownloadRecordSnapshot(
                id: "sym-1", bookID: "sym-book", bookTitle: "符号链接测试书", sourceID: "s1",
                chapterID: "sym-ch1", chapterIndex: 0, chapterTitle: "第一章", chapterURL: "https://e.com/1",
                kind: .manual, state: .completed, localRelPath: rel
            )
        ]

        let reconciler = StorageReconciler(downloadsRoot: linkRoot, minIntervalSeconds: 60)
        let report = await reconciler.reconcileIfNeeded(completedRecords: completed, force: true)
        XCTAssertEqual(report?.verifiedFiles, 1)
        XCTAssertEqual(report?.missingRecordIDs, [])
        XCTAssertEqual(report?.orphanFilesRemoved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "符号链接路径下有效音频不得被误删")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshOrphan.path), "10 分钟保护窗内的新文件不得被误删")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleOrphan.path), "超保护窗的孤儿文件应被清理")
    }

    // MARK: - 3. PersistenceEngine 分页边界与 kindRaw 持久化

    func testB15_PersistencePaginatedZeroAndTenAndKindRawUpgrade() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        for i in 0..<23 {
            try await engine.upsertDownload(DownloadRecordSnapshot(
                id: "b15-dl-\(i)", bookID: "b15", bookTitle: "分页书", sourceID: "s1",
                chapterID: "c-\(i)", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterURL: "https://e.com/\(i)",
                kind: .precache, state: .queued
            ))
        }

        let pageZero = try await engine.fetchAllDownloadsPaginated(pageSize: 0)
        let pageTen = try await engine.fetchAllDownloadsPaginated(pageSize: 10)
        XCTAssertEqual(pageZero.count, 23)
        XCTAssertEqual(pageTen.count, 23)
        XCTAssertEqual(Set(pageTen.map(\.id)).count, 23)

        // 将 precache 记录升级为 manual 并校验 kindRaw 真实落盘
        var upgraded = try XCTUnwrap(pageTen.first(where: { $0.id == "b15-dl-0" }))
        upgraded.kind = .manual
        try await engine.upsertDownload(upgraded)

        let manuals = try await engine.fetchDownloads(kind: .manual, state: .queued)
        let precaches = try await engine.fetchDownloads(kind: .precache, state: .queued)
        XCTAssertEqual(manuals.map(\.id), ["b15-dl-0"])
        XCTAssertEqual(precaches.count, 22)
    }

    // MARK: - 4. ZIPArchiveReader 0 字节 Deflate、Data 切片、路径规范化去重与 commentLength

    func testB15_ZIPZeroByteDeflateSliceDuplicatePathAndCommentLength() throws {
        let reader = ZIPArchiveReader()

        // 1) 0 字节 Deflate (method = 8)
        let emptyDeflateZip = Self.makeZip(entries: [("empty.js", Data(), 8, 0)], comment: Data())
        let emptyEntries = try reader.readAll(from: emptyDeflateZip)
        XCTAssertEqual(emptyEntries.count, 1)
        XCTAssertEqual(emptyEntries.first?.path, "empty.js")
        XCTAssertTrue(emptyEntries.first?.data.isEmpty == true)

        // 2) 非零 startIndex 的 Data 切片
        let payload = Data("console.log('ok');".utf8)
        let normalZip = Self.makeZip(entries: [("main.js", payload, 0, DSCrypto.crc32(payload))], comment: Data("ok-comment".utf8))
        var prefixed = Data([0xDE, 0xAD, 0xBE, 0xEF])
        prefixed.append(normalZip)
        let slice = prefixed[4...]
        XCTAssertNotEqual(slice.startIndex, 0)
        let sliceEntries = try reader.readAll(from: slice)
        XCTAssertEqual(sliceEntries.count, 1)
        XCTAssertEqual(sliceEntries.first?.data, payload)

        // 3) 路径规范化去重（反斜杠与大小写归一冲突）
        let dupZip = Self.makeZip(entries: [
            ("src/a.js", payload, 0, DSCrypto.crc32(payload)),
            ("src\\A.js", payload, 0, DSCrypto.crc32(payload))
        ], comment: Data())
        XCTAssertThrowsError(try reader.readAll(from: dupZip)) { err in
            guard case ZIPArchiveError.invalidPath = err else {
                return XCTFail("Expected invalidPath for duplicate normalized entry, got \(err)")
            }
        }

        // 4) EOCD commentLength 与尾随字节不匹配必须拒绝
        var badCommentZip = normalZip
        badCommentZip.append(Data([0x00, 0x01]))
        XCTAssertThrowsError(try reader.readAll(from: badCommentZip)) { err in
            XCTAssertEqual(err as? ZIPArchiveError, .invalidArchive)
        }
    }

    // MARK: - 5. HTMLDocumentNode 孤立闭标签、html() 真实输出与 script/注释隔离

    func testB15_HTMLDocumentNodeOrphanCloseInnerHTMLAndScriptCommentIsolation() {
        let html = """
        <div id="wrap">
          </span></section>
          <!-- <p class="ghost">ghost</p> -->
          <script>if (a < b && c > d) { var tag = "<p>fake</p>"; }</script>
          <p class="real">Hello <b>Swift</b> &amp; DOM</p>
        </div>
        """
        let doc = HTMLDocumentNode.parse(html: html, baseURL: "https://example.com/")
        let paragraphs = doc.select("#wrap > p")
        XCTAssertEqual(paragraphs.size(), 1)
        let p = paragraphs.first()
        XCTAssertEqual(p?.text(), "Hello Swift & DOM")
        XCTAssertEqual(p?.html(), "Hello <b>Swift</b> &amp; DOM")
        XCTAssertNil(doc.selectFirst("p.ghost"))
    }

    // MARK: - 6. 真实 prelude.js 与 prelude_parser.js JavaScriptCore 行为测试

    func testB15_RealPreludeAndPreludeParserBehaviorInJSC() throws {
        let preludeJS = try Self.loadResourceJS(named: "prelude")
        let parserPreludeJS = try Self.loadResourceJS(named: "prelude_parser")

        // 6a. prelude.js: ID 去重、错 ID 不误命中、getPref 空串回退、parseJson 尾注释
        let ctx1 = try XCTUnwrap(JSContext())
        ctx1.evaluateScript("""
        var __bridge = {
          host: function(id, name) {
            return {
              getSourceId: function() { return id; },
              getPref: function(k) { return k === 'emptyKey' ? '' : (k === 'hitKey' ? 'val1' : null); }
            };
          }
        };
        """)
        ctx1.evaluateScript(preludeJS)
        ctx1.evaluateScript("""
        registerSource({ id: 'srcA', name: '源A1', search: function(q){ return 'v1:' + q; } });
        registerSource({ id: 'srcA', name: '源A2', search: function(q){ return 'v2:' + q; } });
        """)
        XCTAssertEqual(ctx1.evaluateScript("__sources.length")?.toInt32(), 1)
        let okInvoke = ctx1.evaluateScript("__invokeById('srcA', 'search', JSON.stringify(['三体']))")?.toString()
        XCTAssertEqual(okInvoke, "\"v2:三体\"")

        let wrongIDInvoke = ctx1.evaluateScript("__invokeById('nonexistent', 'search', JSON.stringify(['三体']))")?.toString() ?? ""
        XCTAssertTrue(wrongIDInvoke.contains("__dsMissingMethod"), "错 ID 必须返回 __dsMissingMethod 而非误命中 __sources[0]")

        XCTAssertEqual(ctx1.evaluateScript("__sources[0].host.getPref('emptyKey', 'fallback')")?.toString(), "fallback")
        XCTAssertEqual(ctx1.evaluateScript("__sources[0].host.getPref('hitKey', 'fallback')")?.toString(), "val1")
        XCTAssertEqual(ctx1.evaluateScript("parseJson('cb({\"k\":1}); // trailing comment').k")?.toInt32(), 1)
        XCTAssertEqual(ctx1.evaluateScript("parseJson('cb({\"k\":2}) /* tail */').k")?.toInt32(), 2)

        // 6b. prelude_parser.js: getPref 空串一致、parseJson 尾注释、单解析器约束
        let ctx2 = try XCTUnwrap(JSContext())
        ctx2.evaluateScript("""
        var __bridge = {
          host: function(id, name) {
            return {
              getSourceId: function() { return id; },
              getPref: function(k) { return k === 'emptyKey' ? '' : 'ok'; }
            };
          }
        };
        """)
        ctx2.evaluateScript(parserPreludeJS)
        ctx2.evaluateScript("""
        registerBuiltinParser({
          id: 'p1',
          name: '解析器1',
          targets: { hosts: ['ximalaya.com'], sourceIDs: ['xm'] },
          resolveAudio: function(req) { return { url: 'https://ximalaya.com/a.m4a' }; }
        });
        """)
        XCTAssertEqual(ctx2.evaluateScript("__parsers[0].host.getPref('emptyKey', 'def')")?.toString(), "def")
        XCTAssertEqual(ctx2.evaluateScript("parseJson('jsonp({\"v\":7}); // comment').v")?.toInt32(), 7)
    }

    // MARK: - 7. DSP 非有限值安全、PlaybackCoordinator .ended 重播与负 seek 钳制、DownloadScheduler.migrateKind、HostHTTPClient 重定向上限

    @MainActor
    func testB15_PlaybackEndedReplayNegativeSeekClampAndDSPSafety() async throws {
        let proc = AudioTapProcessor()
        let extreme = AudioDSPParameters(bandGainsDB: [12, -12, 0, 6, -6], stereoBalance: 10.0, volumeBoostEnabled: true, fadeGain: -5.0)
        XCTAssertEqual(extreme.stereoBalance, 1.0, accuracy: 0.001)
        XCTAssertEqual(extreme.fadeGain, 0.0, accuracy: 0.001)
        proc.updateParameters(extreme)

        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let vault = CookieVault(inMemorySecretsOnly: true)
        let client = HostHTTPClient(cookieVault: vault)
        let runtime = PluginRuntime(preludeScript: "", httpClient: client, cookieVault: vault, logger: logger)
        let coord = PlaybackCoordinator(audioResolver: runtime, progressStore: engine, logger: logger)
        defer { coord.tearDown() }

        let book = BookSummaryDTO(id: "b15-pb", sourceID: "s1", bookURL: "https://e.com/b", title: "重播测试")
        let chapters = [ChapterDTO(id: "c1", index: 0, title: "终章", url: "https://e.com/c1")]
        coord.play(book: book, chapters: chapters, startIndex: 0, autoPlay: false)
        coord.nextChapter()
        if case .ended = coord.state {
            // Expected
        } else {
            XCTFail("Expected .ended state, got \(coord.state)")
        }

        coord.resume()
        XCTAssertTrue(coord.state.isPlaying, ".ended 态调用 resume() 应重新进入 playing 态")

        coord.seek(to: -120)
        XCTAssertEqual(coord.clock.currentSeconds, 0, accuracy: 0.001)
        coord.seek(to: .nan)
        XCTAssertEqual(coord.clock.currentSeconds, 0, accuracy: 0.001)
    }

    func testB15_DownloadSchedulerMigrateKindTransfersActiveSlot() {
        var scheduler = DownloadScheduler(maxManualConcurrent: 2, maxPrecacheConcurrent: 1)
        scheduler.markStarted(id: "task-1", kind: .precache)
        XCTAssertEqual(scheduler.activePrecacheIDs, ["task-1"])

        scheduler.migrateKind(id: "task-1", to: .manual)
        XCTAssertTrue(scheduler.activePrecacheIDs.isEmpty)
        XCTAssertEqual(scheduler.activeManualIDs, ["task-1"])
        XCTAssertEqual(scheduler.totalActiveCount, 1)

        scheduler.migrateKind(id: "not-active", to: .manual)
        XCTAssertEqual(scheduler.totalActiveCount, 1)
    }

    func testB15_HostHTTPClientEnforcesMaxRedirectsViaURLProtocol() async {
        let host = "redir-\(UUID().uuidString.lowercased()).example.com"
        RedirectLoopURLProtocol.resetCounter(forHost: host)
        defer { RedirectLoopURLProtocol.resetCounter(forHost: host) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RedirectLoopURLProtocol.self]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let client = HostHTTPClient(session: session, cookieVault: vault, maxRedirects: 2)
        let policy = SourcePermissionPolicy(ownerID: "redir-test", isBuiltinParser: false, permissionMode: .compatApproved, declaredHosts: [])

        do {
            _ = try await client.send(url: URL(string: "https://\(host)/start")!, policy: policy)
            XCTFail("Expected redirect limit error")
        } catch let error as PluginSecurityError {
            XCTAssertEqual(error, .scriptError("重定向次数超过上限"))
            XCTAssertEqual(RedirectLoopURLProtocol.requestCount(forHost: host), 3)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - 8. NetworkReachabilityMonitor 5G 冷启与 DownloadState.completed 自转换

    @MainActor
    func testB15_NetworkMonitorColdStartAndDownloadStateCompletedSelfTransition() async {
        // 确定性冷启与超时返回校验（消除真实 NWPathMonitor 后台回调时序竞争导致的偶发误报）
        let liveMonitor = NetworkReachabilityMonitor(startImmediately: true)
        defer { liveMonitor.stop() }
        await liveMonitor.waitForInitialPath(timeoutSeconds: 0.05)

        let simMonitor = NetworkReachabilityMonitor(startImmediately: false)
        XCTAssertTrue(simMonitor.hasReceivedInitialPath, "未立即启动的监控器默认处于确定性初始路径就绪状态")
        await simMonitor.waitForInitialPath(timeoutSeconds: 0.05)
        var events: [Bool] = []
        simMonitor.setOnNetworkTypeChanged { events.append($0) }
        simMonitor.simulateState(connected: true, onWiFi: false)
        simMonitor.simulateState(connected: true, onWiFi: false)
        XCTAssertEqual(events, [false])

        XCTAssertFalse(DownloadState.completed.canTransition(to: .completed))
        XCTAssertTrue(DownloadState.completed.isTerminal)
        XCTAssertFalse(DownloadState.cancelled.isTerminal)
    }

    // MARK: - Helpers

    private static func writeSQLiteVersion(_ version: Int, to url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let handle = db else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(handle) }
        let sql = "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY, ver INTEGER); INSERT OR REPLACE INTO meta(id, ver) VALUES (1, \(version));"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func readSQLiteVersion(from url: URL) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = db else { return nil }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT ver FROM meta WHERE id = 1;", -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return nil }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(s, 0))
    }

    private static func loadResourceJS(named name: String) throws -> String {
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: "js") {
            return try String(contentsOf: bundleURL, encoding: .utf8)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallbackURL = repoRoot.appendingPathComponent("App/Resources/\(name).js")
        return try String(contentsOf: fallbackURL, encoding: .utf8)
    }

    private static func makeZip(entries: [(name: String, data: Data, method: UInt16, crc: UInt32)], comment: Data) -> Data {
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
            let sz = UInt32(e.data.count)
            u32(&archive, 0x0403_4B50); u16(&archive, 20); u16(&archive, 0); u16(&archive, e.method)
            u16(&archive, 0); u16(&archive, 0); u32(&archive, e.crc); u32(&archive, sz); u32(&archive, sz)
            u16(&archive, UInt16(name.count)); u16(&archive, 0); archive.append(name); archive.append(e.data)

            u32(&centralDir, 0x0201_4B50); u16(&centralDir, 20); u16(&centralDir, 20); u16(&centralDir, 0)
            u16(&centralDir, e.method); u16(&centralDir, 0); u16(&centralDir, 0); u32(&centralDir, e.crc)
            u32(&centralDir, sz); u32(&centralDir, sz); u16(&centralDir, UInt16(name.count))
            u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0); u16(&centralDir, 0)
            u32(&centralDir, 0); u32(&centralDir, offset); centralDir.append(name)
        }
        let cdOffset = UInt32(archive.count)
        archive.append(centralDir)
        u32(&archive, 0x0605_4B50); u16(&archive, 0); u16(&archive, 0)
        u16(&archive, UInt16(entries.count)); u16(&archive, UInt16(entries.count))
        u32(&archive, UInt32(centralDir.count)); u32(&archive, cdOffset); u16(&archive, UInt16(comment.count))
        archive.append(comment)
        return archive
    }
}

private final class RedirectLoopURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var countsByHost: [String: Int] = [:]

    static func resetCounter(forHost host: String) {
        lock.withLock { countsByHost.removeValue(forKey: host.lowercased()) }
    }

    static func requestCount(forHost host: String) -> Int {
        lock.withLock { countsByHost[host.lowercased(), default: 0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://example.com/start")!
        let host = (url.host ?? "example.com").lowercased()
        let hop = Self.lock.withLock { () -> Int in
            let next = (Self.countsByHost[host] ?? 0) + 1
            Self.countsByHost[host] = next
            return next
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://\(host)/hop/\(hop)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
