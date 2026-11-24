import CommonCrypto
@testable import DSCore
@testable import DSDesignSystem
@testable import DSDownloads
@testable import DSNovel
@testable import DSPlayback
@testable import DSPluginKit
@testable import DSStorage
import Foundation
import UIKit
import XCTest

/// b16 全量 67 项审计闭环回归测试套件（100% 对齐最新生产代码签名与 Swift 6 严格并发，无 Flaky sleep）
final class DSB16FullAudit67ClosureTests: XCTestCase {

    // MARK: - 1. P0-02: DSCrypto.aesEcbDecrypt 32 位 Hex AES-128 密钥与 UTF-8 密钥双路解密

    func testP0_02_DSCryptoAESECBDecryptHex128AndUTF8KeyDualPath() throws {
        // 喜马拉雅真实格式：32 位 Hex 字符串解码为 16 字节 AES-128 密钥
        let hexKey = "aaad3e4fd540b0f79dca95606e72bf93"
        let hexKeyData = try XCTUnwrap(Self.dataFromHex(hexKey))
        XCTAssertEqual(hexKeyData.count, 16)

        let plaintext1 = "https://audiopay.cos.tx.xmcdn.com/download/1.0.0/demo_track.m4a?token=abc"
        let cipher1 = try Self.aesEcbEncrypt(plaintext: plaintext1, keyData: hexKeyData)
        let cipher1Base64 = cipher1.base64EncodedString()
        let cipher1Hex = cipher1.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(DSCrypto.aesEcbDecrypt(base64OrHexData: cipher1Base64, key: hexKey), plaintext1)
        XCTAssertEqual(DSCrypto.aesEcbDecrypt(base64OrHexData: cipher1Hex, key: hexKey), plaintext1)

        // UTF-8 16 字节密钥路径
        let utf8Key = "dsnovel_aes_key!"
        let plaintext2 = "https://cdn.example.com/audio/ch001.mp3"
        let cipher2 = try Self.aesEcbEncrypt(plaintext: plaintext2, keyData: Data(utf8Key.utf8))
        XCTAssertEqual(DSCrypto.aesEcbDecrypt(base64OrHexData: cipher2.base64EncodedString(), key: utf8Key), plaintext2)
    }

    // MARK: - 2. P0-01 & P1-09 & P2-08: HTMLDocumentNode 裸 <、属性撇号、script/style 隔离、absUrl 与选择器去重

    func testP0_01_P1_09_P2_08_HTMLDocumentNodeParsingAbsURLAndSelectorDedup() {
        let html = """
        <div class="box">
          <style>.hidden { color: red; }</style>
          <script>if (1 < 2 && 3 > 1) { var s = "<p>fake</p>"; }</script>
          <p title="Don't break > here">比较 1 < 2 成立</p>
          <a id="cn" href="/书目/三体 第一部.html">中文链接</a>
          <a id="proto" href="//cdn.example.com/audio/1.m4a">协议相对</a>
          <section class="inner"><p class="leaf">叶节点</p></section>
        </div>
        """
        let doc = HTMLDocumentNode.parse(html: html, baseURL: "https://book.example.com/list/index.html")

        // 1) 裸 `<` 与属性中单引号/大于号不截断
        let firstP = doc.selectFirst("p[title]")
        XCTAssertEqual(firstP?.attr("title"), "Don't break > here")
        XCTAssertEqual(firstP?.text(), "比较 1 < 2 成立")

        // 2) <script>/<style> 不混入 text()
        let boxText = doc.selectFirst("div.box")?.text() ?? ""
        XCTAssertFalse(boxText.contains("color: red"))
        XCTAssertFalse(boxText.contains("var s"))
        XCTAssertTrue(boxText.contains("叶节点"))

        // 3) 中文/空格与协议相对 absUrl
        let cnAbs = doc.selectFirst("#cn")?.absUrl("href") ?? ""
        XCTAssertTrue(cnAbs.hasPrefix("https://book.example.com/"))
        XCTAssertTrue(cnAbs.contains("%20"), "空格应被百分号编码")
        XCTAssertEqual(doc.selectFirst("#proto")?.absUrl("href"), "https://cdn.example.com/audio/1.m4a")

        // 4) 多层选择器去重：同一叶节点被多条规则命中仅返回 1 次
        let deduped = doc.select("div p.leaf, section p.leaf, div.box section > p")
        XCTAssertEqual(deduped.size(), 1)
        XCTAssertEqual(deduped.first()?.text(), "叶节点")
    }

    // MARK: - 3. P0-03 & P0-04: HostBridge.parseRequestOptions 与 SandboxCancellationToken UUID 反注册

    func testP0_03_HostBridgeParseRequestOptionsFullMatrix() {
        let optionsJSON = #"""
        {
          "method": "POST",
          "contentType": "application/json; charset=utf-8",
          "desktop": true,
          "encoding": "gbk",
          "body": "{\"q\":\"三体\"}",
          "headers": {
            "X-Num": 42,
            "X-Bool": true,
            "X-Null": null,
            "X-Text": "ok"
          }
        }
        """#
        let parsed = HostHandleJS.parseRequestOptions(optionsJSON)
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.encoding, "gbk")
        XCTAssertEqual(parsed.body, Data(#"{"q":"三体"}"#.utf8))
        XCTAssertEqual(parsed.headers["X-Num"], "42")
        XCTAssertEqual(parsed.headers["X-Bool"], "true")
        XCTAssertNil(parsed.headers["X-Null"])
        XCTAssertEqual(parsed.headers["X-Text"], "ok")
        XCTAssertEqual(parsed.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(parsed.headers["User-Agent"], HostHTTPClient.desktopUserAgent)

        // 已显式传入小写 content-type / user-agent 时不得被覆盖
        let explicitJSON = #"""
        {
          "contentType": "text/plain",
          "desktop": true,
          "headers": {
            "content-type": "application/x-www-form-urlencoded",
            "user-agent": "CustomUA/1.0"
          }
        }
        """#
        let explicit = HostHandleJS.parseRequestOptions(explicitJSON)
        XCTAssertEqual(explicit.headers["content-type"], "application/x-www-form-urlencoded")
        XCTAssertNil(explicit.headers["Content-Type"])
        XCTAssertEqual(explicit.headers["user-agent"], "CustomUA/1.0")
        XCTAssertNil(explicit.headers["User-Agent"])
    }

    func testP0_04_SandboxCancellationTokenUUIDUnregister() {
        final class FiredBox: @unchecked Sendable {
            let lock = NSLock()
            var items: [String] = []
            func append(_ v: String) { lock.withLock { items.append(v) } }
            func snapshot() -> [String] { lock.withLock { items } }
        }
        let token = SandboxCancellationToken()
        let fired = FiredBox()

        let removedID = token.onCancel {
            fired.append("removed")
        }
        let keptID = token.onCancel {
            fired.append("kept")
        }
        XCTAssertNotEqual(removedID, keptID)

        token.removeCancelHandler(removedID)
        token.cancel()
        token.cancel() // 幂等，二次取消不重复触发

        XCTAssertEqual(fired.snapshot(), ["kept"])
        XCTAssertTrue(token.isCancelled)

        // 已取消后新增监听应立即触发
        _ = token.onCancel {
            fired.append("late")
        }
        XCTAssertEqual(fired.snapshot(), ["kept", "late"])
    }

    // MARK: - 4. P1-05 & P3-05: SourceContractAdapter isFree/artist/fallback 保护与脏数据过滤

    func testP1_05_P3_05_SourceContractAdapterMappingFallbackAndFiltering() {
        let booksJSON = #"""
        [
          {"title": "", "url": "https://e.com/empty-title"},
          {"title": "缺URL书", "url": "   "},
          {"title": "三体广播剧", "url": "https://e.com/b1", "artist": "演播甲"}
        ]
        """#
        let books = SourceContractAdapter.decodeBooks(booksJSON, sourceID: "xm", sourceName: "测试源")
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.title, "三体广播剧")
        XCTAssertEqual(books.first?.author, "演播甲")
        XCTAssertEqual(books.first?.narrator, "演播甲")

        let fallback = BookSummaryDTO(
            id: "xm::b1",
            sourceID: "xm",
            sourceName: "测试源",
            bookURL: "https://e.com/b1",
            title: "原始标题",
            author: "原著作者",
            narrator: "原始演播",
            coverURL: "https://e.com/cover.jpg",
            intro: "原始简介"
        )
        let detailJSON = #"""
        {
          "title": "   ",
          "author": "",
          "narrator": "",
          "cover": "",
          "intro": "",
          "chapters": [
            {"id": "c-bad-url", "title": "无链接", "url": ""},
            {"id": "c-bad-title", "title": " ", "url": "https://e.com/c0"},
            {"id": "c1", "title": "免费章", "url": "https://e.com/c1", "isFree": true},
            {"id": "c2", "title": "付费章", "url": "https://e.com/c2", "isFree": false},
            {"id": "c3", "title": "显式VIP", "url": "https://e.com/c3", "isVip": true, "isFree": true}
          ]
        }
        """#
        let detail = SourceContractAdapter.decodeBookDetail(detailJSON, fallback: fallback)
        // 非空 fallback 保护
        XCTAssertEqual(detail.summary.title, "原始标题")
        XCTAssertEqual(detail.summary.author, "原著作者")
        XCTAssertEqual(detail.summary.narrator, "原始演播")
        XCTAssertEqual(detail.summary.coverURL, "https://e.com/cover.jpg")
        XCTAssertEqual(detail.summary.intro, "原始简介")

        // 空 url/title 过滤 + isFree -> !isVIP 映射
        XCTAssertEqual(detail.chapters.count, 3)
        XCTAssertEqual(detail.chapters.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(detail.chapters[0].isVIP, false)
        XCTAssertEqual(detail.chapters[1].isVIP, true)
        XCTAssertEqual(detail.chapters[2].isVIP, true)
    }

    // MARK: - 5. P1-01 & P1-03: CoverImagePipeline 并发槽位上限与 clearAll() 代际隔离

    func testP1_01_P1_03_CoverImagePipelineConcurrencyCapAndClearAllEpochIsolation() async {
        let host = "cover-\(UUID().uuidString.lowercased()).example.com"
        CoverPipelineMockURLProtocol.reset(forHost: host)
        defer { CoverPipelineMockURLProtocol.reset(forHost: host) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSB16Cover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CoverPipelineMockURLProtocol.self]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let pipeline = CoverImagePipeline(diskDirectory: tempDir, session: session, maxConcurrent: 2)

        // 1) 并发槽位上限 <= 2
        let urls = (0..<6).map { "https://\(host)/img_\($0).png" }
        await withTaskGroup(of: UIImage?.self) { group in
            for u in urls {
                group.addTask { await pipeline.image(for: u) }
            }
            var decodedCount = 0
            for await img in group {
                if img != nil { decodedCount += 1 }
            }
            XCTAssertEqual(decodedCount, 6)
        }
        XCTAssertLessThanOrEqual(CoverPipelineMockURLProtocol.peakConcurrent(forHost: host), 2, "并发网络下载数不得超过 maxConcurrent=2")

        // 2) clearAll() 代际隔离：飞行中的旧代际请求在 clearAll() 后不得回写内存缓存
        let gatedURL = "https://\(host)/gated_epoch.png"
        CoverPipelineMockURLProtocol.armGate(forHost: host)
        let inflightTask = Task { await pipeline.image(for: gatedURL) }
        await CoverPipelineMockURLProtocol.waitUntilGateEntered(forHost: host)

        await pipeline.clearAll()
        CoverPipelineMockURLProtocol.releaseGate(forHost: host)
        _ = await inflightTask.value

        XCTAssertNil(pipeline.cachedImageSync(for: gatedURL), "clearAll() 前发起的旧代际图片不得污染新代际内存缓存")
    }

    // MARK: - 6. P1-02 & P2-03 & P3-03: PersistenceEngine 事务回滚、备份非空保护与跨章重置、togglePin 非书架拦截

    func testP1_02_P2_03_P3_03_PersistenceTransactionBackupProtectionAndTogglePinGuard() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        // 1) togglePin 拦截非书架书籍
        let nonShelf = BookSummaryDTO(id: "b-nonshelf", sourceID: "s1", bookURL: "https://e.com/ns", title: "非书架书")
        try await engine.upsertBook(nonShelf, addToShelf: false)
        try await engine.togglePin(bookID: nonShelf.id)
        let shelfEmpty = try await engine.fetchShelfBooks()
        XCTAssertTrue(shelfEmpty.isEmpty)

        // 加入书架后允许置顶，再次 togglePin 取消置顶
        try await engine.setInShelf(bookID: nonShelf.id, inShelf: true)
        try await engine.togglePin(bookID: nonShelf.id)
        let pinnedBackup = try await engine.exportLibraryBackup(appVersion: "3.0.0")
        XCTAssertEqual(pinnedBackup.books.first(where: { $0.id == nonShelf.id })?.isPinned, true)
        try await engine.togglePin(bookID: nonShelf.id)
        let unpinnedBackup = try await engine.exportLibraryBackup(appVersion: "3.0.0")
        XCTAssertEqual(unpinnedBackup.books.first(where: { $0.id == nonShelf.id })?.isPinned, false)

        // 2) importLibraryBackup 非空字段保护 + 跨章重置 lastChapterID
        let richBook = BookSummaryDTO(
            id: "b-merge",
            sourceID: "s1",
            sourceName: "喜马",
            bookURL: "https://e.com/m",
            title: "合集书",
            author: "名家作者",
            narrator: "金牌演播",
            coverURL: "https://e.com/rich.jpg"
        )
        let oldCh = ChapterDTO(id: "ch-old-1", index: 0, title: "第一章", url: "https://e.com/c1", durationMs: 60_000)
        try await engine.upsertBook(richBook, addToShelf: true)
        await engine.saveProgress(book: richBook, chapter: oldCh, positionMs: 12_000, durationMs: 60_000, isFinished: false, overrideFinished: false)

        let newerDate = Date().addingTimeInterval(600)
        let incomingItem = LibraryBackupPayload.BackupBook(
            id: "b-merge",
            sourceID: "s1",
            sourceName: "",
            bookURL: "https://e.com/m",
            title: "合集书",
            author: "",
            narrator: "",
            coverURL: "",
            inShelf: true,
            isPinned: false,
            shelfGroupName: "",
            lastPlayedAt: newerDate,
            lastChapterID: nil,
            lastChapterIndex: 5,
            lastChapterTitle: "第六章",
            lastPositionMs: 25_000,
            lastDurationMs: 180_000,
            skipConfig: SkipConfigDTO()
        )
        let payload = LibraryBackupPayload(appVersion: "3.0.0", books: [incomingItem])
        let importedCount = try await engine.importLibraryBackup(payload)
        XCTAssertEqual(importedCount, 1)

        let shelfAfterMerge = try await engine.fetchShelfBooks()
        let merged = try XCTUnwrap(shelfAfterMerge.first(where: { $0.id == "b-merge" }))
        XCTAssertEqual(merged.sourceName, "喜马", "空 sourceName 不得覆盖已有非空值")
        XCTAssertEqual(merged.author, "名家作者", "空 author 不得覆盖已有非空值")
        XCTAssertEqual(merged.narrator, "金牌演播", "空 narrator 不得覆盖已有非空值")
        XCTAssertEqual(merged.coverURL, "https://e.com/rich.jpg", "空 coverURL 不得覆盖已有非空值")

        let playbackOpt = await engine.fetchBookLastPlayback(bookID: "b-merge")
        let playback = try XCTUnwrap(playbackOpt)
        XCTAssertEqual(playback.chapterIndex, 5)
        XCTAssertEqual(playback.chapterTitle, "第六章")
        XCTAssertEqual(playback.positionMs, 25_000)
        let exportedAfterMerge = try await engine.exportLibraryBackup(appVersion: "3.0.0")
        let exportedBook = try XCTUnwrap(exportedAfterMerge.books.first(where: { $0.id == "b-merge" }))
        XCTAssertEqual(exportedBook.lastChapterID ?? "", "", "跨章备份缺少 lastChapterID 时必须重置旧章节 ID")
        XCTAssertEqual(exportedBook.lastDurationMs, 180_000)

        // 3) saveOrRollback 可正常提交无异常
        try await engine.saveOrRollback()
    }

    // MARK: - 7. P1-22 & P2-10: AudioTapProcessor.processOfflinePCMForTesting 单声道右平衡、NaN 限幅与 Biquad EQ

    func testP1_22_P2_10_AudioTapProcessorMonoBalanceNaNClampAndBiquadEQ() {
        let processor = AudioTapProcessor()

        // 1) 单声道右平衡 (+1.0) 不得静音
        processor.updateParameters(AudioDSPParameters(
            bandGainsDB: [0, 0, 0, 0, 0],
            stereoBalance: 1.0,
            volumeBoostEnabled: false,
            fadeGain: 1.0
        ))
        var mono: [Float] = [0.25, -0.25, 0.5, -0.5]
        processor.processOfflinePCMForTesting(samples: &mono, channelCount: 1, sampleRate: 44_100)
        XCTAssertEqual(mono[0], 0.25, accuracy: 0.01, "单声道在右平衡 +1.0 下不得被静音")
        XCTAssertEqual(mono[2], 0.5, accuracy: 0.01)

        // 2) NaN / ±Inf / 超界限幅防护
        var dirty: [Float] = [.nan, .infinity, -.infinity, 9.5, -9.5, 0.2]
        processor.processOfflinePCMForTesting(samples: &dirty, channelCount: 2, sampleRate: 44_100)
        for s in dirty {
            XCTAssertTrue(s.isFinite)
            XCTAssertGreaterThanOrEqual(s, -1.0)
            XCTAssertLessThanOrEqual(s, 1.0)
        }

        // 3) Biquad EQ 真实波形变化（对比 flat 与 +12dB 提升）
        let frameCount = 256
        let sampleRate = 44_100.0
        let baseWave: [Float] = (0..<frameCount).map { i in
            Float(0.25 * sin(2.0 * Double.pi * 1000.0 * Double(i) / sampleRate))
        }
        var flatPCM = baseWave
        processor.updateParameters(AudioDSPParameters(bandGainsDB: [0, 0, 0, 0, 0], stereoBalance: 0, volumeBoostEnabled: false, fadeGain: 1.0))
        processor.processOfflinePCMForTesting(samples: &flatPCM, channelCount: 1, sampleRate: sampleRate)

        var boostedPCM = baseWave
        processor.updateParameters(AudioDSPParameters(bandGainsDB: [6, 6, 12, 6, 6], stereoBalance: 0, volumeBoostEnabled: false, fadeGain: 1.0))
        processor.processOfflinePCMForTesting(samples: &boostedPCM, channelCount: 1, sampleRate: sampleRate)

        let maxDelta = zip(flatPCM, boostedPCM).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(maxDelta, 0.05, "Biquad 均衡器增益调整必须产生真实可测的波形变化")
    }

    // MARK: - 8. P1-13 & P1-12: BackgroundTransferTransport 唯一 session 创建/销毁与 headersHash 校验

    func testP1_13_P1_12_BackgroundTransferTransportSessionLifecycleAndHeadersHash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DSB16Transport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sid = "com.dsnovel.test.\(UUID().uuidString)"
        let transport = BackgroundTransferTransport(baseDirectory: dir, sessionIdentifier: sid)
        defer { transport.invalidate() }
        XCTAssertEqual(transport.sessionIdentifier, sid)

        // 校验 taskDescription 解析与扩展名白名单清洗
        let parsed = BackgroundTransferTransport.parseTaskDescription("book1::ch1|MP3")
        XCTAssertEqual(parsed.taskID, "book1::ch1")
        XCTAssertEqual(parsed.ext, "mp3")
        XCTAssertEqual(BackgroundTransferTransport.sanitizedExtension("../exe"), "m4a")

        // 构造带不匹配 headersHash 的磁盘 .resume 文件，startDownload 应消费并丢弃该失效 resumeData
        let taskID = "hash-check-1"
        let resumeFile = dir.appendingPathComponent(".resume_data", isDirectory: true).appendingPathComponent("\(taskID).resume")
        let stalePayload = #"{"urlString":"https://cdn.example.com/a.m4a","wifiOnly":false,"headersHash":"deadbeef","data":"ZHVtbXk="}"#
        try Data(stalePayload.utf8).write(to: resumeFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path))

        transport.startDownload(
            taskID: taskID,
            url: URL(string: "https://cdn.example.com/a.m4a")!,
            headers: ["Authorization": "Bearer fresh-token"],
            wifiOnly: false,
            preferredExtension: "m4a"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path), "不匹配 headersHash 的旧 resume 文件应被清理")
        transport.cancelDownload(taskID: taskID)
    }

    // MARK: - 9. P2-04 & P3-06: CookieVault 双向清主/子域与 200 条上限裁剪

    func testP2_04_P3_06_CookieVaultBidirectionalDomainClearAnd200Cap() async throws {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let parentCookie = try XCTUnwrap(HTTPCookie(properties: [.domain: ".ximalaya.com", .path: "/", .name: "p", .value: "1"]))
        let subCookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "m.ximalaya.com", .path: "/", .name: "s", .value: "2"]))
        let otherCookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "other.example.com", .path: "/", .name: "o", .value: "3"]))
        await vault.setCookies([parentCookie, subCookie, otherCookie])

        // 1) 清主域同时清掉子域，保留无关域
        await vault.clearCookies(forDomain: "ximalaya.com")
        let afterParentClearSub = await vault.cookieHeader(for: URL(string: "https://m.ximalaya.com/")!)
        let afterParentClearOther = await vault.cookieHeader(for: URL(string: "https://other.example.com/")!)
        XCTAssertEqual(afterParentClearSub, "")
        XCTAssertEqual(afterParentClearOther, "o=3")

        // 2) 清子域同时清掉覆盖它的父域 Cookie
        await vault.setCookies([parentCookie, subCookie])
        await vault.clearCookies(forDomain: "m.ximalaya.com")
        let afterSubClearParent = await vault.cookieHeader(for: URL(string: "https://www.ximalaya.com/")!)
        XCTAssertEqual(afterSubClearParent, "")

        // 3) 200 条上限裁剪（写入 235 条仅保留最新 200 条）
        await vault.clearCookies()
        var batch: [HTTPCookie] = []
        for i in 0..<235 {
            if let c = HTTPCookie(properties: [.domain: "cap.example.com", .path: "/", .name: "k\(i)", .value: "v\(i)"]) {
                batch.append(c)
            }
        }
        await vault.setCookies(batch)
        let matched = await vault.matchingCookies(for: URL(string: "https://cap.example.com/")!)
        XCTAssertEqual(matched.count, 200)
        XCTAssertFalse(matched.contains(where: { $0.name == "k0" }))
        XCTAssertTrue(matched.contains(where: { $0.name == "k234" }))
    }

    // MARK: - 10. P3-01 / P3-02 / P3-04 / P3-09 / P2-11 / P2-14 综合边界回归

    @MainActor
    func testP3_01_02_04_09_P2_11_14_UtilityBoundaryAndViewModelContracts() async throws {
        // P3-01: DSDiagnosticLogStore 负参安全钳制
        let logStore = DSDiagnosticLogStore(maxEntries: -10)
        for i in 0..<60 {
            await logStore.record(category: .ui, level: "INFO", message: "entry-\(i)")
        }
        let negSnap = await logStore.snapshot(limit: -5)
        XCTAssertTrue(negSnap.isEmpty)
        let fullSnap = await logStore.snapshot(limit: 100)
        XCTAssertEqual(fullSnap.count, 50, "maxEntries 负值应钳制为下限 50")

        // P3-02: DownloadRetryPolicy 负重试返回 nil
        XCTAssertNil(DownloadRetryPolicy.delaySeconds(retryCount: -1, httpStatus: 500))
        XCTAssertNil(DownloadRetryPolicy.delaySeconds(retryCount: 3, httpStatus: 500))
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 0, httpStatus: 500), 2.0)
        XCTAssertEqual(DownloadRetryPolicy.delaySeconds(retryCount: 0, httpStatus: 429), 4.0)

        // P3-04: NetworkReachabilityMonitor start() 重置初始路径标记
        let monitor = NetworkReachabilityMonitor(startImmediately: false)
        XCTAssertTrue(monitor.hasReceivedInitialPath)
        monitor.start()
        XCTAssertFalse(monitor.hasReceivedInitialPath, "重新 start() 应重置 hasReceivedInitialPath")
        monitor.stop()

        // P3-09: SearchViewModel.resetSearch() 全字段复位
        let searchVM = SearchViewModel()
        searchVM.results = [BookSummaryDTO(id: "b1", sourceID: "s1", bookURL: "u1", title: "测试书")]
        searchVM.selectedSourceFilterID = "s1"
        searchVM.failedSourceNames = ["超时源"]
        searchVM.isSearching = true
        searchVM.completedSources = 2
        searchVM.totalSources = 3
        searchVM.lastSearchedTerm = "三体"
        searchVM.resetSearch()
        XCTAssertTrue(searchVM.results.isEmpty)
        XCTAssertNil(searchVM.selectedSourceFilterID)
        XCTAssertTrue(searchVM.failedSourceNames.isEmpty)
        XCTAssertFalse(searchVM.isSearching)
        XCTAssertEqual(searchVM.completedSources, 0)
        XCTAssertEqual(searchVM.totalSources, 0)
        XCTAssertNil(searchVM.lastSearchedTerm)

        // P2-11: DiscoverViewModel 刷新失败保底（保留现有书籍列表并记录错误）
        let appContainer = try AppContainer(inMemoryOnly: true)
        defer {
            appContainer.playback.tearDown()
            appContainer.networkMonitor.stop()
        }
        let discoverVM = DiscoverViewModel()
        let existingBook = BookSummaryDTO(id: "keep-1", sourceID: "missing-src", bookURL: "https://e.com/k1", title: "保底书")
        discoverVM.selectedSourceID = "missing-src"
        discoverVM.categories = [DiscoverCategoryDTO(id: "missing-src::hot", title: "热门", url: "https://e.com/hot")]
        discoverVM.selectedCategoryID = "missing-src::hot"
        discoverVM.books = [existingBook]
        await discoverVM.refreshCurrentCategory(container: appContainer)
        XCTAssertEqual(discoverVM.books.map(\.id), ["keep-1"], "下拉刷新失败时应保留现有书籍列表")
        XCTAssertNotNil(discoverVM.errorMessage)

        // P2-14: PlayerSpeedFormatter 边界与格式化
        XCTAssertEqual(PlayerSpeedFormatter.format(0.1), "0.5x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.0), "1.0x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.25), "1.25x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.5), "1.5x")
        XCTAssertEqual(PlayerSpeedFormatter.format(2.0), "2.0x")
        XCTAssertEqual(PlayerSpeedFormatter.format(5.0), "3.0x")
    }

    // MARK: - ximalaya_parser-v1.5 宿主兼容适配回归测试

    func testAudioQualityTierFromParserTokenMapsNewAndLegacyTokens() {
        XCTAssertEqual(AudioQualityTier.fromParserToken("auto"), .auto)
        XCTAssertEqual(AudioQualityTier.fromParserToken("std"), .saver)
        XCTAssertEqual(AudioQualityTier.fromParserToken("hd"), .standard)
        XCTAssertEqual(AudioQualityTier.fromParserToken("uhd"), .high)
        XCTAssertEqual(AudioQualityTier.fromParserToken("FLAC_24"), .high)
        XCTAssertEqual(AudioQualityTier.fromParserToken("lossless"), .high)
        XCTAssertEqual(AudioQualityTier.saver.parserToken, "std")
        XCTAssertEqual(AudioQualityTier.standard.parserToken, "hd")
        XCTAssertEqual(AudioQualityTier.high.parserToken, "uhd")
        XCTAssertEqual(AudioQualityTier.fromParserToken("M4A_64"), .standard)
        XCTAssertNil(AudioQualityTier.fromParserToken("unknown_tier"))
    }

    func testBuiltinParserEnginePassesEpisodeURLTrackIdReadsMeasuredKbpsDownloadUrlAndCheckStatus() async throws {
        let prelude = try Self.loadResourceJS(name: "prelude_parser", ext: "js", fallbackRelativePath: "App/Resources/prelude_parser.js")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-b16-parser-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let logger = DSDiagnosticLogStore()
        let engine = BuiltinParserEngine(
            preludeParserScript: prelude,
            storageDir: tempDir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: logger
        )
        let script = """
        registerBuiltinParser({
          id: 'compat-test-parser',
          name: '兼容测试解析器',
          version: '1.5.1',
          targets: { hosts: ['ximalaya.com'], sourceIDs: ['src-xm-1'] },
          qualities: ['auto', 'std', 'hd', 'uhd'],
          checkStatus: function () {
            this.host.log('自检日志可见性测试');
            var sample = this.host.getPref('sampleTrackId', '');
            return { ok: true, message: '自检正常 sample=' + sample, latencyMs: 12, nickname: '测试号', vipExpireAt: '2027-01-01', maxLevelNote: '最高可用：超清' };
          },
          resolveAudio: function (request) {
            if (!request || !request.episodeURL || request.trackId !== '987654') {
              throw parserError('bad_track', 'missing episodeURL or trackId');
            }
            this.host.log('命中 trackId=' + request.trackId);
            return {
              url: 'https://audio.xmcdn.com/play.m4a',
              downloadUrl: 'https://audio.xmcdn.com/download.m4a',
              measuredKbps: 129,
              capped: false
            };
          }
        });
        """
        let meta = try await engine.installParser(scriptBody: script)
        XCTAssertEqual(meta.qualities, [.auto, .saver, .standard, .high])

        await engine.setPref(parserID: meta.id, key: "sampleTrackId", value: "987654")
        let savedPref = await engine.getPref(parserID: meta.id, key: "sampleTrackId")
        XCTAssertEqual(savedPref, "987654")

        let status = try await engine.checkStatus(id: meta.id)
        XCTAssertTrue(status.ok)
        XCTAssertTrue(status.message.contains("sample=987654"))
        XCTAssertEqual(status.nickname, "测试号")

        let chapter = ChapterDTO(id: "ch1", index: 0, title: "第一集", url: "xm:987654")
        let dlStream = try await engine.tryResolveAudio(sourceID: "src-xm-1", bookID: "b1", chapter: chapter, preferredQuality: .high, forDownload: true)
        XCTAssertEqual(dlStream?.url.absoluteString, "https://audio.xmcdn.com/download.m4a")
        XCTAssertEqual(dlStream?.bitrateKbps, 129)

        let combined = await engine.combinedLogs()
        XCTAssertTrue(combined.contains { $0.contains("自检正常") || $0.contains("命中 trackId=987654") })

        try await engine.setEnabled(id: meta.id, enabled: false)
        let disabledStream = try await engine.tryResolveAudio(sourceID: "src-xm-1", bookID: "b1", chapter: chapter, preferredQuality: .high, forDownload: false)
        XCTAssertNil(disabledStream)

        try await engine.deleteParser(id: meta.id)
        let afterDelete = await engine.listParsers()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    // MARK: - 内置解析脚本三连击解锁与幂等加载测试

    @MainActor
    func testAppSettingsStoreBuiltinParserUnlockedDefaultsFalseAndPersists() throws {
        let suite = "com.dsnovel.test.unlock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s1 = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(s1.builtinParserUnlocked)
        s1.builtinParserUnlocked = true
        let s2 = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(s2.builtinParserUnlocked)
    }

    func testBundledParserLoaderCoversInstallIdempotentReEnableUpgradeAndNoDowngrade() async throws {
        let prelude = try Self.loadResourceJS(name: "prelude_parser", ext: "js", fallbackRelativePath: "App/Resources/prelude_parser.js")
        let bundledScript = try Self.loadResourceJS(name: BundledParserLoader.bundledResourceName, ext: BundledParserLoader.bundledResourceExt, fallbackRelativePath: "App/Resources/BundledParsers/ximalaya_parser-v1.5.5.js")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-b16-bundled-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let engine = BuiltinParserEngine(
            preludeParserScript: prelude,
            storageDir: tempDir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )

        // 1. 首次安装
        let first = try await BundledParserLoader.installIfNeeded(engine: engine, scriptBody: bundledScript)
        XCTAssertEqual(first, .installed(name: "喜马拉雅解析", version: "1.5.5"))

        // 2. 同版本幂等
        let second = try await BundledParserLoader.installIfNeeded(engine: engine, scriptBody: bundledScript)
        XCTAssertEqual(second, .alreadyLatest(name: "喜马拉雅解析", version: "1.5.5"))

        // 3. 停用后重新启用
        try await engine.setEnabled(id: "ximalaya-vip", enabled: false)
        let reEnabled = try await BundledParserLoader.installIfNeeded(engine: engine, scriptBody: bundledScript)
        XCTAssertEqual(reEnabled, .reEnabled(name: "喜马拉雅解析", version: "1.5.5"))

        // 4. 低版本原地升级
        let olderScript = bundledScript.replacingOccurrences(of: "version: '1.5.5',", with: "version: '1.5.0',")
        _ = try await engine.installParser(scriptBody: olderScript)
        let upgraded = try await BundledParserLoader.installIfNeeded(engine: engine, scriptBody: bundledScript)
        XCTAssertEqual(upgraded, .upgraded(name: "喜马拉雅解析", fromVersion: "1.5.0", toVersion: "1.5.5"))

        // 5. 更高版本防降级
        let newerScript = bundledScript.replacingOccurrences(of: "version: '1.5.5',", with: "version: '1.6.0',")
        _ = try await engine.installParser(scriptBody: newerScript)
        let protected = try await BundledParserLoader.installIfNeeded(engine: engine, scriptBody: bundledScript)
        XCTAssertEqual(protected, .newerInstalled(name: "喜马拉雅解析", installedVersion: "1.6.0", bundledVersion: "1.5.5"))
    }

    // MARK: - R1-R7 跨边界闭环回归测试

    func testBuiltinParserBusinessRejectionKeepsHealthyAndActualLevelMapsQualityTier() async throws {
        let prelude = try Self.loadResourceJS(name: "prelude_parser", ext: "js", fallbackRelativePath: "App/Resources/prelude_parser.js")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-b16-r1r7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let engine = BuiltinParserEngine(
            preludeParserScript: prelude,
            storageDir: tempDir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )
        let script = """
        registerBuiltinParser({
          id: 'r1r7-test-parser',
          name: 'R1-R7测试解析器',
          version: '1.5.5',
          targets: { hosts: ['ximalaya.com'], sourceIDs: ['src-r1r7'] },
          resolveAudio: function (req) {
            if (req.trackId === '1001') {
              throw parserError('trial_only', '仅提供试听');
            }
            this.host.writeCache('resolved_links_v1.json', '{"k":1}');
            return {
              url: req.bypassCache ? 'https://audio.xmcdn.com/fresh.m4a' : 'https://audio.xmcdn.com/cached.m4a',
              actualLevel: 1,
              actualQuality: 'M4A_64',
              capped: true,
              measuredKbps: 64
            };
          }
        });
        """
        let meta = try await engine.installParser(scriptBody: script)

        // R2 & R3: trial_only throws .parserRejected and keeps parser .healthy
        let trialChapter = ChapterDTO(id: "c1", index: 0, title: "试听章", url: "xm:1001", isVIP: true)
        do {
            _ = try await engine.tryResolveAudio(sourceID: "src-r1r7", bookID: "b1", chapter: trialChapter, preferredQuality: .high, forDownload: false)
            XCTFail("Expected parserRejected for trial_only")
        } catch let err as PluginSecurityError {
            if case .parserRejected(let reason, _) = err {
                XCTAssertEqual(reason, "trial_only")
            } else {
                XCTFail("Unexpected PluginSecurityError: \(err)")
            }
        }
        let afterTrial = await engine.listParsers().first { $0.id == meta.id }
        XCTAssertEqual(afterTrial?.healthStatus, .healthy)

        // R1 & R4 & R7: actualLevel=1 maps to .standard even when preferredQuality=.high; bypassCache=true reaches script; clearParserCache removes .cache
        let normalChapter = ChapterDTO(id: "c2", index: 1, title: "正片章", url: "xm:2002", isVIP: false)
        let stream = try await engine.tryResolveAudio(sourceID: "src-r1r7", bookID: "b1", chapter: normalChapter, preferredQuality: .high, forDownload: false, bypassCache: true)
        XCTAssertEqual(stream?.url.absoluteString, "https://audio.xmcdn.com/fresh.m4a")
        XCTAssertEqual(stream?.qualityTier, .standard)
        XCTAssertEqual(stream?.isCappedFallback, true)

        let cleared = await engine.clearParserCache(id: meta.id)
        XCTAssertGreaterThanOrEqual(cleared, 1)
    }

    func testAudioQualityTierAutoResolvesToHighOnWiFiAndSaverOnCellular() {
        // 已解锁内置解析：开放 4 档，自适应 Wi-Fi -> 超清(.high)，蜂窝 -> 标清(.saver)
        XCTAssertEqual(AudioQualityTier.availableTiers(builtinParserUnlocked: true), [.auto, .saver, .standard, .high])
        XCTAssertEqual(AudioQualityTier.auto.resolved(isOnWiFi: true, allowUltraHigh: true), .high)
        XCTAssertEqual(AudioQualityTier.auto.resolved(isOnWiFi: true, allowUltraHigh: true).parserToken, "uhd")
        XCTAssertEqual(AudioQualityTier.auto.resolved(isOnWiFi: false, allowUltraHigh: true), .saver)
        XCTAssertEqual(AudioQualityTier.auto.resolved(isOnWiFi: false, allowUltraHigh: true).parserToken, "std")

        // 未解锁内置解析：隐藏超清（仅 3 档），自适应 Wi-Fi -> 高清(.standard)，蜂窝 -> 标清(.saver)，且 .high 钳制为 .standard
        XCTAssertEqual(AudioQualityTier.availableTiers(builtinParserUnlocked: false), [.auto, .saver, .standard])
        XCTAssertEqual(AudioQualityTier.auto.resolved(isOnWiFi: true, allowUltraHigh: false), .standard)
        XCTAssertEqual(AudioQualityTier.auto.resolved(isOnWiFi: false, allowUltraHigh: false), .saver)
        XCTAssertEqual(AudioQualityTier.high.resolved(isOnWiFi: true, allowUltraHigh: false), .standard)
        XCTAssertEqual(AudioQualityTier.auto.badgeLabel(allowUltraHigh: false), "Wi-Fi 高清 · 蜂窝标准")
        XCTAssertEqual(AudioQualityTier.auto.badgeLabel(allowUltraHigh: true), "Wi-Fi 超清 · 蜂窝标准")
    }

    func testBuiltinParserNetworkHostsDoNotTriggerChapterMatchAndMultiQualityScoping() async throws {
        let prelude = try Self.loadResourceJS(name: "prelude_parser", ext: "js", fallbackRelativePath: "App/Resources/prelude_parser.js")
        let bundled = try Self.loadResourceJS(name: BundledParserLoader.bundledResourceName, ext: BundledParserLoader.bundledResourceExt, fallbackRelativePath: "App/Resources/BundledParsers/ximalaya_parser-v1.5.5.js")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-b16-nethost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let engine = BuiltinParserEngine(
            preludeParserScript: prelude,
            storageDir: tempDir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )
        let meta = try await engine.installParser(scriptBody: bundled)
        XCTAssertEqual(meta.hosts, ["ximalaya.com", "xmcdn.com"])
        XCTAssertEqual(meta.networkHosts, ["raw.githubusercontent.com"])

        let ghChapter = ChapterDTO(id: "g1", index: 0, title: "无关章", url: "https://raw.githubusercontent.com/foo/bar.mp3")
        let unmatched = try await engine.tryResolveAudio(sourceID: "other-source", bookID: "b1", chapter: ghChapter, preferredQuality: .high, forDownload: false)
        XCTAssertNil(unmatched)

        let xmSupported = await engine.supportsMultiQuality(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", chapterURL: "xm:123")
        let otherSupported = await engine.supportsMultiQuality(sourceID: "other-source", chapterURL: "https://m.tingshuwang.cc/play/1")
        XCTAssertTrue(xmSupported)
        XCTAssertFalse(otherSupported)
    }

    func testPluginSecurityErrorAudioFailureClassification() {
        XCTAssertFalse(PluginSecurityError.parserRejected(reason: "not_vip", message: "无权限").isRetryableAudioFailure)
        XCTAssertFalse(PluginSecurityError.parserRejected(reason: "trial_only", message: "仅试听").isRetryableAudioFailure)
        XCTAssertFalse(PluginSecurityError.hostNotAllowed(host: "evil.com", ownerID: "x").isRetryableAudioFailure)
        XCTAssertTrue(PluginSecurityError.timeout(seconds: 30).isRetryableAudioFailure)
        XCTAssertTrue(PluginSecurityError.scriptError("网络抖动").isRetryableAudioFailure)
    }

    // MARK: - Helpers

    private static func loadResourceJS(name: String, ext: String, fallbackRelativePath: String) throws -> String {
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return try String(contentsOf: bundleURL, encoding: .utf8)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(fallbackRelativePath), encoding: .utf8)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    private static func aesEcbEncrypt(plaintext: String, keyData: Data) throws -> Data {
        let input = Data(plaintext.utf8)
        var outBytes = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outLength: size_t = 0
        let status = keyData.withUnsafeBytes { keyPtr in
            input.withUnsafeBytes { dataPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyPtr.baseAddress,
                    keyData.count,
                    nil,
                    dataPtr.baseAddress,
                    input.count,
                    &outBytes,
                    outBytes.count,
                    &outLength
                )
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "DSB16CryptoTest", code: Int(status))
        }
        return Data(outBytes.prefix(outLength))
    }
}

// MARK: - CoverImagePipeline 确定性并发与代际门控 Mock URLProtocol

private final class CoverPipelineMockURLProtocol: URLProtocol, @unchecked Sendable {
    private struct HostState {
        var active: Int = 0
        var peak: Int = 0
        var gateArmed: Bool = false
        var gateEntered: Bool = false
        var enteredWaiter: CheckedContinuation<Void, Never>?
        var releaseSem: DispatchSemaphore?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var states: [String: HostState] = [:]
    private static let onePixelPNG: Data = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let img = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return img.pngData() ?? Data()
    }()

    static func reset(forHost host: String) {
        let sem: DispatchSemaphore? = lock.withLock {
            let old = states.removeValue(forKey: host.lowercased())
            old?.enteredWaiter?.resume()
            return old?.releaseSem
        }
        sem?.signal()
    }

    static func peakConcurrent(forHost host: String) -> Int {
        lock.withLock { states[host.lowercased()]?.peak ?? 0 }
    }

    static func armGate(forHost host: String) {
        lock.withLock {
            var st = states[host.lowercased(), default: HostState()]
            st.gateArmed = true
            st.gateEntered = false
            st.releaseSem = DispatchSemaphore(value: 0)
            states[host.lowercased()] = st
        }
    }

    static func waitUntilGateEntered(forHost host: String) async {
        await withCheckedContinuation { cont in
            let already = lock.withLock { () -> Bool in
                var st = states[host.lowercased(), default: HostState()]
                if st.gateEntered { return true }
                st.enteredWaiter = cont
                states[host.lowercased()] = st
                return false
            }
            if already { cont.resume() }
        }
    }

    static func releaseGate(forHost host: String) {
        let sem: DispatchSemaphore? = lock.withLock {
            var st = states[host.lowercased(), default: HostState()]
            st.gateArmed = false
            let s = st.releaseSem
            st.releaseSem = nil
            states[host.lowercased()] = st
            return s
        }
        sem?.signal()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://example.com/1.png")!
        let host = (url.host ?? "example.com").lowercased()
        let (semToWait, waiterToResume): (DispatchSemaphore?, CheckedContinuation<Void, Never>?) = Self.lock.withLock {
            var st = Self.states[host, default: HostState()]
            st.active += 1
            if st.active > st.peak { st.peak = st.active }
            var sem: DispatchSemaphore?
            var waiter: CheckedContinuation<Void, Never>?
            if st.gateArmed {
                st.gateEntered = true
                waiter = st.enteredWaiter
                st.enteredWaiter = nil
                sem = st.releaseSem
            }
            Self.states[host] = st
            return (sem, waiter)
        }
        waiterToResume?.resume()
        if let semToWait {
            _ = semToWait.wait(timeout: .now() + 2.0)
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.onePixelPNG)
        client?.urlProtocolDidFinishLoading(self)

        Self.lock.withLock {
            if var st = Self.states[host] {
                st.active = max(0, st.active - 1)
                Self.states[host] = st
            }
        }
    }

    override func stopLoading() {}
}
