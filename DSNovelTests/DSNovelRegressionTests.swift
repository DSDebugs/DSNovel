import XCTest
import JavaScriptCore
import SwiftData
@testable import DSNovel

/// 针对三个已反馈 Bug 的回归测试（本地文件导入 / 选章加载 / 新书进度时间）
final class DSNovelRegressionTests: XCTestCase {

    // MARK: - 辅助：手工构造 Store(无压缩) ZIP

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func makeStoredZip(entries: [(name: String, data: Data)], flags: UInt16 = 0, method: UInt16 = 0) -> Data {
        var body = [UInt8]()
        var central = [UInt8]()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let offset = UInt32(body.count)
            body += [0x50, 0x4B, 0x03, 0x04] + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0)
            let crc = ZIPArchiveReader.crc32(of: entry.data)
            body += le32(crc) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count))
            body += le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + Array(entry.data)

            central += [0x50, 0x4B, 0x01, 0x02] + le16(20) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0)
            central += le32(crc) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count))
            central += le16(UInt16(nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)
            central += nameBytes
        }
        let cdOffset = UInt32(body.count)
        var eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0)
        eocd += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        eocd += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        return Data(body + central + eocd)
    }

    // MARK: - Bug 1：本地文件导入

    /// 带 UTF-8 BOM 的单个 .js 书源脚本必须能被识别并解析出书源
    func testImportSingleJSWithUTF8BOM() async throws {
        let script = """
        registerSource({ id: 'bom_src', name: 'BOM 测试源', url: 'https://example.com',
          search: function (kw, page) { return { books: [] }; } });
        """
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(script.utf8))
        let preview = try await PluginRuntime.shared.prepareImportPreview(from: data)
        XCTAssertEqual(preview.sources.map(\.id), ["bom_src"])
    }

    /// GB18030 编码的 .js 书源脚本（国内常见）同样可导入
    func testDecodeScriptTextGB18030() {
        let text = "registerSource({ id: 'gb', name: '中文书源' });"
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = text.data(using: String.Encoding(rawValue: gb))!
        XCTAssertNil(String(data: data, encoding: .utf8))          // 纯 UTF-8 解码会失败
        XCTAssertEqual(PluginRuntime.decodeScriptText(data), text) // 新解码器可还原
    }

    /// ZIP 内容位于子目录（macOS「压缩文件夹」的常见结构）时，manifest.json / 脚本仍能被找到
    func testZIPWithSubfolderIsFlattened() throws {
        let zip = makeStoredZip(entries: [
            (name: "pkg/", data: Data()),
            (name: "pkg/manifest.json", data: Data("{}".utf8)),
            (name: "pkg/source.js", data: Data("var a=1;".utf8)),
            (name: "__MACOSX/pkg/._source.js", data: Data([0, 1, 2]))
        ])
        let files = try ZIPArchiveReader.extractAll(from: zip)
        XCTAssertEqual(Set(files.keys), ["manifest.json", "source.js"])
        XCTAssertEqual(files["source.js"], Data("var a=1;".utf8))
    }

    /// 加密 / 不支持的压缩方式必须给出明确报错，而不是静默忽略后提示「没有找到脚本」
    func testZIPEncryptedAndUnsupportedMethodThrowReadableError() {
        let encrypted = makeStoredZip(entries: [(name: "a.js", data: Data("x".utf8))], flags: 0x1)
        XCTAssertThrowsError(try ZIPArchiveReader.extractAll(from: encrypted))

        let lzma = makeStoredZip(entries: [(name: "a.js", data: Data("x".utf8))], method: 14)
        XCTAssertThrowsError(try ZIPArchiveReader.extractAll(from: lzma))
    }

    // MARK: - Bug 3：章节时长归一化

    func testChapterDurationNormalization() {
        func ch(_ d: Int?) -> ChapterDTO { ChapterDTO(index: 0, title: "t", url: "u", durationSec: d) }
        XCTAssertEqual(ch(1800).normalizedDurationSec, 1800)          // 正常秒
        XCTAssertEqual(ch(1_800_000).normalizedDurationSec, 1800)     // 毫秒折算为秒
        XCTAssertNil(ch(0).normalizedDurationSec)
        XCTAssertNil(ch(-5).normalizedDurationSec)
        XCTAssertNil(ch(nil).normalizedDurationSec)
        XCTAssertNil(ch(Int.max).normalizedDurationSec)               // 离谱值视为未知
        XCTAssertEqual(ch(1_800_000).hintDurationSec, 1800)
        XCTAssertEqual(ch(nil).hintDurationSec, 0)
    }

    /// 进度时间文本：极端/异常输入不得产生乱码
    func testPlaybackClockFormatting() {
        XCTAssertEqual(PlaybackClock.formatSeconds(-3), "00:00")
        XCTAssertEqual(PlaybackClock.formatSeconds(.nan), "00:00")
        XCTAssertEqual(PlaybackClock.formatSeconds(65), "01:05")
        XCTAssertEqual(PlaybackClock.formatSeconds(3725), "1:02:05")
    }

    // MARK: - Bug 2：章节目录缓存

    func testChapterCacheRoundTripAndAge() {
        let bookID = "regression::\(UUID().uuidString)"
        let chapters = (0..<3000).map { ChapterDTO(index: $0, title: "第\($0)集", url: "https://e.com/\($0)", durationSec: 600) }
        ChapterCacheStore.saveChapters(chapters, for: bookID)
        XCTAssertEqual(ChapterCacheStore.loadChapters(for: bookID)?.count, 3000)
        let age = ChapterCacheStore.cacheAge(for: bookID)
        XCTAssertNotNil(age)
        XCTAssertLessThan(age ?? 999, 60)
        XCTAssertNil(ChapterCacheStore.cacheAge(for: "regression::missing"))
    }

    // MARK: - A-1(b)：书源未提供 duration 时按上次成功播放实测时长回填（120s 下限）

    @MainActor
    func testA1ObservedDurationBackfillAnd120sFloor() {
        // 1. 书源本身给出有效 hintDurationSec 时优先采信书源值
        XCTAssertEqual(
            PlayerEngine.resolveExpectedDuration(hintDurationSec: 420, observedDurationMs: 600_000),
            420
        )

        // 2. 书源无 duration 时，实测时长 <= 120s（含 120_000ms 边界与短试听片段）不得采信
        XCTAssertNil(PlayerEngine.resolveExpectedDuration(hintDurationSec: 0, observedDurationMs: 0))
        XCTAssertNil(PlayerEngine.resolveExpectedDuration(hintDurationSec: 0, observedDurationMs: 60_000))
        XCTAssertNil(PlayerEngine.resolveExpectedDuration(hintDurationSec: 0, observedDurationMs: 120_000))

        // 3. 实测时长 > 120s 时按秒回填
        XCTAssertEqual(
            PlayerEngine.resolveExpectedDuration(hintDurationSec: 0, observedDurationMs: 121_000),
            121.0
        )

        // 4. 与 ChapterProgressCache 联动读写校验
        let bookID = "a1_backfill_\(UUID().uuidString)"
        let chapterID = "ch_1"
        ChapterProgressCache.shared.setFinished(bookID: bookID, chapterID: chapterID, isFinished: false, durationMs: 360_000)
        let observedMs = ChapterProgressCache.shared.progress(bookID: bookID, chapterID: chapterID)?.durationMs ?? 0
        XCTAssertEqual(
            PlayerEngine.resolveExpectedDuration(hintDurationSec: 0, observedDurationMs: observedMs),
            360.0
        )
    }

    // MARK: - R3-1：BookDetailModel 章节快照 downloadItemID 格式回归

    @MainActor
    func testBookDetailModelDownloadItemIDFormat() {
        let ref = BookRef(
            sourceID: "src_r3",
            bookURL: "https://example.com/book/42",
            title: "测试书目"
        )
        let model = BookDetailModel(book: ref)
        let ch1 = ChapterDTO(index: 0, title: "第1章 开篇", url: "https://example.com/book/42/ch1", durationSec: 300)
        let ch2 = ChapterDTO(index: 1, title: "第2章 续篇", url: "https://example.com/book/42/ch2", durationSec: 360)
        model.applyChapters([ch1, ch2])

        let snapshots = model.visibleChapterSnapshots(
            currentPlayingChapterID: nil,
            isEnginePlaying: false
        )
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].downloadItemID, "\(ref.id)::\(ch1.id)")
        XCTAssertEqual(snapshots[1].downloadItemID, "\(ref.id)::\(ch2.id)")
    }

    // MARK: - T3 & R3-8：AppRouter.openBuiltinParser 空源回退 .sourceList 与防套娃

    @MainActor
    func testAppRouterOpenBuiltinParserNilFallsBackToSourceList() {
        let router = AppRouter.shared
        router.resetForTesting()

        router.selectedTab = .library
        router.mePath = [.downloads]

        router.openBuiltinParser(sourceID: nil)
        XCTAssertEqual(router.selectedTab, .me)
        XCTAssertEqual(router.mePath, [.sourceList])
        XCTAssertNil(router.consumePendingParserFocus())

        // 空串同样回退 .sourceList 且若已存在 .sourceList 则回退至该节点不套娃
        router.resetForTesting()
        router.selectedTab = .discover
        router.mePath = [.sourceList, .sourceDetail(id: "old_src", focus: nil)]
        router.openBuiltinParser(sourceID: "   ")
        XCTAssertEqual(router.selectedTab, .me)
        XCTAssertEqual(router.mePath, [.sourceList])
        XCTAssertNil(router.consumePendingParserFocus())

        router.resetForTesting()
    }

    // MARK: - 10-5(1)：HostBridge 跨源隔离、预览态隔离、内部符号销毁与路径防穿越

    func testHostBridgeCrossSourceIsolationPreviewGuardAndPathTraversal() throws {
        let parserA = "iso_a_\(UUID().uuidString.prefix(8))"
        let parserB = "iso_b_\(UUID().uuidString.prefix(8))"
        defer {
            BuiltinParserKeychain.set(nil, forKey: "parser_pref_\(parserA).token")
            BuiltinParserKeychain.set(nil, forKey: "parser_pref_\(parserB).token")
        }

        // 1) 正常解析器 A 写入 Keychain pref，且全局内部桥接符号已被 delete
        guard let ctxA = JSContext(virtualMachine: JSVirtualMachine()),
              let ctxB = JSContext(virtualMachine: JSVirtualMachine()),
              let ctxPreview = JSContext(virtualMachine: JSVirtualMachine()) else {
            XCTFail("无法创建 JSContext")
            return
        }
        JsHostBridge.installParserNative(into: ctxA, parserID: parserA, parserName: "A", allowedHosts: ["a.invalid"], allowNetwork: true)
        JsHostBridge.installParserNative(into: ctxB, parserID: parserB, parserName: "B", allowedHosts: ["b.invalid"], allowNetwork: true)
        JsHostBridge.installParserNative(into: ctxPreview, parserID: parserA, parserName: "Preview", allowedHosts: ["a.invalid"], allowNetwork: false)

        // 全局 __n_* 内部符号必须已被销毁
        let leakedSymbols = ctxA.evaluateScript("[typeof __n_getPref, typeof __n_setPref, typeof __n_readCache, typeof __n_writeCache, typeof __n_cacheAge, typeof __n_request].join(',')")?.toString()
        XCTAssertEqual(leakedSymbols, "undefined,undefined,undefined,undefined,undefined,undefined")

        // A 写入自己的 token
        _ = ctxA.evaluateScript("var hA = __bridge.host('\(parserA)', 'A'); hA.setPref('token', 'secret_A');")
        XCTAssertEqual(ctxA.evaluateScript("hA.getPref('token')")?.toString(), "secret_A")

        // B 即使伪造 __bridge.host(parserA, ...) 也只能落到 Swift 硬绑定的 parserB 命名空间，绝不能读出 A 的 Keychain
        let spoofRead = ctxB.evaluateScript("var hSpoof = __bridge.host('\(parserA)', 'Spoof'); hSpoof.getPref('token');")
        XCTAssertTrue(spoofRead?.isNull == true, "M-P0-7：跨源伪造 ownerID 不得读取其他解析器的 Keychain")

        // 2) 预览态（allowNetwork == false）隔离 pref 读取/写入与 cache 写入
        let previewRead = ctxPreview.evaluateScript("var hP = __bridge.host('\(parserA)', 'Preview'); hP.getPref('token');")
        XCTAssertTrue(previewRead?.isNull == true, "M-P0-7：预览态不得读取已持久化 pref")
        _ = ctxPreview.evaluateScript("hP.setPref('token', 'hijacked'); hP.writeCache('k', 'v');")
        XCTAssertEqual(BuiltinParserKeychain.string(forKey: "parser_pref_\(parserA).token"), "secret_A")
        XCTAssertEqual(ctxPreview.evaluateScript("hP.cacheAge('k')")?.toDouble(), -1)

        // 3) isHostAllowed 仅允许 http/https 协议
        XCTAssertTrue(JsHostBridge.isHostAllowed("https://api.example.com/v1", allowedHosts: ["example.com"]))
        XCTAssertTrue(JsHostBridge.isHostAllowed("http://example.com/v1", allowedHosts: ["example.com"]))
        XCTAssertFalse(JsHostBridge.isHostAllowed("file:///etc/passwd", allowedHosts: ["example.com"]))
        XCTAssertFalse(JsHostBridge.isHostAllowed("ftp://example.com/a", allowedHosts: ["example.com"]))
        XCTAssertFalse(JsHostBridge.isHostAllowed("javascript:alert(1)", allowedHosts: ["example.com"]))

        // 4) 缓存路径防穿越校验
        XCTAssertNil(JsHostBridge.safeCacheFileURL(namespace: "../../etc", name: "passwd", createDirectory: false))
        XCTAssertNil(JsHostBridge.safeCacheFileURL(namespace: "Parser/../../etc", name: "passwd", createDirectory: false))
        let validURL = JsHostBridge.safeCacheFileURL(namespace: "Parser/\(parserA)", name: "item1", createDirectory: false)
        XCTAssertNotNil(validURL)
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PluginCache", isDirectory: true).standardizedFileURL.path
        XCTAssertTrue(validURL?.standardizedFileURL.path.hasPrefix(cacheRoot + "/") == true)
    }

    // MARK: - 10-5(2)：302 跨域重定向剥离原手动 Cookie 头并按目标域重新匹配

    func testCrossDomainRedirectStripsManualCookieAndReinjectsTargetDomain() {
        let hostA = "a.redir-cookie-test.invalid"
        let hostB = "b.redir-cookie-test.invalid"
        let hostC = "c.redir-cookie-test.invalid"
        defer {
            if let all = HTTPCookieStorage.shared.cookies {
                for c in all where c.domain.lowercased().contains("redir-cookie-test.invalid") {
                    HTTPCookieStorage.shared.deleteCookie(c)
                }
            }
        }

        if let cookieA = HTTPCookie(properties: [
            .name: "sid", .value: "secret_a", .domain: hostA, .path: "/", .secure: "TRUE"
        ]) {
            CookieSync.storeCookie(cookieA)
        }
        if let cookieB = HTTPCookie(properties: [
            .name: "sid", .value: "target_b", .domain: hostB, .path: "/"
        ]) {
            CookieSync.storeCookie(cookieB)
        }

        let originURL = URL(string: "https://\(hostA)/start")!

        // 跨域跳转至无 Cookie 目标域 C：原手动 Cookie 必须彻底剥离
        var toC = URLRequest(url: URL(string: "https://\(hostC)/next")!)
        toC.setValue("sid=secret_a; leaked=1", forHTTPHeaderField: "Cookie")
        let sanitizedC = JsHostBridge.sanitizedRedirectRequest(toC, from: originURL)
        XCTAssertNil(sanitizedC.value(forHTTPHeaderField: "Cookie"))

        // 跨域跳转至有独立 Cookie 的目标域 B：剥离 secret_a 并仅注入 target_b
        var toB = URLRequest(url: URL(string: "https://\(hostB)/next")!)
        toB.setValue("sid=secret_a; leaked=1", forHTTPHeaderField: "Cookie")
        let sanitizedB = JsHostBridge.sanitizedRedirectRequest(toB, from: originURL)
        let headerB = sanitizedB.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(headerB.contains("secret_a"))
        XCTAssertFalse(headerB.contains("leaked=1"))
        XCTAssertTrue(headerB.contains("sid=target_b"))

        // HTTPS -> HTTP 协议降级重定向：Secure Cookie 必须被剥离
        var downgrade = URLRequest(url: URL(string: "http://\(hostA)/plain")!)
        downgrade.setValue("sid=secret_a", forHTTPHeaderField: "Cookie")
        let sanitizedDowngrade = JsHostBridge.sanitizedRedirectRequest(downgrade, from: originURL)
        XCTAssertNil(sanitizedDowngrade.value(forHTTPHeaderField: "Cookie"))
    }

    // MARK: - 10-5(3)：CookieSync isSecure / 过期时间 / path 过滤

    func testCookieSyncEnforcesSecureExpiryAndPathMatching() {
        let rootDomain = "cookie-sec-test.invalid"
        defer {
            if let all = HTTPCookieStorage.shared.cookies {
                for c in all where c.domain.lowercased().contains(rootDomain) {
                    HTTPCookieStorage.shared.deleteCookie(c)
                }
            }
        }

        let future = Date().addingTimeInterval(3600)
        let past = Date().addingTimeInterval(-3600)

        let secureCookie = HTTPCookie(properties: [
            .name: "sec_tok", .value: "s1", .domain: ".\(rootDomain)", .path: "/", .secure: "TRUE", .expires: future
        ])!
        let expiredCookie = HTTPCookie(properties: [
            .name: "exp_tok", .value: "e1", .domain: ".\(rootDomain)", .path: "/", .expires: past
        ])!
        let pathCookie = HTTPCookie(properties: [
            .name: "vip_tok", .value: "v1", .domain: ".\(rootDomain)", .path: "/vip", .expires: future
        ])!
        let publicCookie = HTTPCookie(properties: [
            .name: "pub_tok", .value: "p1", .domain: ".\(rootDomain)", .path: "/", .expires: future
        ])!

        HTTPCookieStorage.shared.setCookie(secureCookie)
        HTTPCookieStorage.shared.setCookie(expiredCookie)
        HTTPCookieStorage.shared.setCookie(pathCookie)
        HTTPCookieStorage.shared.setCookie(publicCookie)

        // 明文 HTTP /vip/track：不得带出 Secure 与过期 Cookie，允许 pub_tok 与匹配路径的 vip_tok
        let httpVipNames = Set(CookieSync.cookies(for: URL(string: "http://sub.\(rootDomain)/vip/track")!).map(\.name))
        XCTAssertFalse(httpVipNames.contains("sec_tok"), "M-P0-8：明文 HTTP 绝不可带出 Secure Cookie")
        XCTAssertFalse(httpVipNames.contains("exp_tok"), "M-P0-8：已过期 Cookie 必须被过滤")
        XCTAssertTrue(httpVipNames.contains("pub_tok"))
        XCTAssertTrue(httpVipNames.contains("vip_tok"))

        // HTTPS /vip2/track：路径 /vip 不得误匹配 /vip2，但允许 Secure Cookie
        let httpsOtherNames = Set(CookieSync.cookies(for: URL(string: "https://sub.\(rootDomain)/vip2/track")!).map(\.name))
        XCTAssertTrue(httpsOtherNames.contains("sec_tok"))
        XCTAssertTrue(httpsOtherNames.contains("pub_tok"))
        XCTAssertFalse(httpsOtherNames.contains("vip_tok"), "M-P0-8：/vip 路径 Cookie 不得匹配 /vip2")
        XCTAssertFalse(httpsOtherNames.contains("exp_tok"))
    }

    // MARK: - 10-5(4)：BuiltinParserStore 脚本与元数据成对回滚

    func testBuiltinParserStorePairedRollbackRestoresScriptAndMetaIntegrity() throws {
        let parserID = "test-paired-rollback-\(UUID().uuidString.prefix(8))"
        addTeardownBlock {
            try? BuiltinParserStore.remove(parserID: parserID)
        }

        let scriptV1 = "registerBuiltinParser({ id: '\(parserID)', name: 'V1', version: '1.0.0', targets: { hosts: ['a.invalid'], sourceIDs: [] }, resolveAudio: function () { return { url: 'https://a.invalid/v1.m4a' }; } });"
        let scriptV2 = "registerBuiltinParser({ id: '\(parserID)', name: 'V2', version: '2.0.0', targets: { hosts: ['a.invalid'], sourceIDs: [] }, resolveAudio: function () { return { url: 'https://a.invalid/v2.m4a' }; } });"

        func makePreview(version: String, name: String, script: String) -> BuiltinParserPreview {
            let data = Data(script.utf8)
            let meta = BuiltinParserMeta(
                id: parserID,
                name: name,
                version: version,
                author: "tests",
                summary: "",
                targets: BuiltinParserTargets(hosts: ["a.invalid"], sourceIDs: []),
                supportsPlayback: true,
                supportsDownload: true,
                requiresCookie: false,
                qualities: ["high"],
                config: [],
                methods: ["resolveAudio"]
            )
            return BuiltinParserPreview(
                meta: meta,
                fileName: "parser.js",
                sha256: BuiltinParserStore.sha256Hex(data),
                sizeBytes: data.count,
                scriptText: script,
                isUpdate: false,
                installedVersion: nil
            )
        }

        let installedV1 = try BuiltinParserStore.install(preview: makePreview(version: "1.0.0", name: "V1", script: scriptV1))
        XCTAssertEqual(installedV1.meta.version, "1.0.0")
        XCTAssertFalse(BuiltinParserStore.backupExists(parserID: parserID))

        let installedV2 = try BuiltinParserStore.install(preview: makePreview(version: "2.0.0", name: "V2", script: scriptV2))
        XCTAssertEqual(installedV2.meta.version, "2.0.0")
        XCTAssertTrue(BuiltinParserStore.backupExists(parserID: parserID))

        // 成对回滚：parser.js 与 meta.json（含 sha256 与版本号）必须同时恢复至 V1
        try BuiltinParserStore.rollbackScript(parserID: parserID)
        XCTAssertFalse(BuiltinParserStore.backupExists(parserID: parserID))

        let restored = BuiltinParserStore.loadParser(in: BuiltinParserStore.directory(for: parserID))
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.meta.version, "1.0.0")
        XCTAssertEqual(restored?.meta.name, "V1")
        let restoredText = restored.flatMap { BuiltinParserStore.scriptText(for: $0, verifyIntegrity: true) }
        XCTAssertEqual(restoredText, scriptV1, "成对回滚后 scriptText(verifyIntegrity: true) 必须通过 SHA-256 校验并还原为 V1")
    }

    // MARK: - 10-5(5)：SourceImportFlow 覆盖升级保留用户属性、packageID 安全清洗与 HTTPS 校验

    @MainActor
    func testSourceImportFlowOverwriteUpgradePreservesUserAttributesAndValidatesURL() throws {
        // 1) 远程导入链接仅允许 https
        XCTAssertNil(SourceImportFlow.validateRemoteURL("http://example.com/sources.zip"))
        XCTAssertNil(SourceImportFlow.validateRemoteURL("file:///etc/passwd"))
        XCTAssertNotNil(SourceImportFlow.validateRemoteURL("https://example.com/sources.zip"))

        // 2) 覆盖安装已有书源：原地更新 PluginRecord，保留分组、置顶、顺序、启用态、登录态与配置
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PluginRecord.self, configurations: config)
        let context = ModelContext(container)

        let existing = PluginRecord(
            id: "src_upgrade_1",
            packageID: "old_pkg_v1",
            name: "旧名称",
            version: "1.0.0",
            author: "old_author",
            siteURL: "https://old.invalid",
            summary: "旧简介",
            groupID: "group_favorites",
            order: 7,
            isPinned: true,
            isEnabled: false,
            searchable: true,
            discoverable: false,
            requiresLogin: true,
            loginURL: "https://old.invalid/login",
            loggedIn: true,
            settingsJSON: "{\"custom\":\"kept\"}"
        )
        context.insert(existing)
        try context.save()

        let upgradedMeta = ParsedSourceMeta(
            index: 0,
            id: "src_upgrade_1",
            name: "新名称",
            url: "https://new.invalid",
            summary: "新简介",
            group: "听书",
            searchable: true,
            discoverable: true,
            multipleEpisodePages: false,
            enabledByDefault: true,
            loginURL: "https://new.invalid/login",
            hasSearchVerification: false,
            searchVerificationDesktop: false,
            searchDelaySeconds: 0,
            methods: ["search"],
            config: []
        )
        let preview = PluginImportPreview(
            packageID: "../Evil Pkg/v2",
            name: "UpgradePkg",
            version: "2.0.0",
            author: "new_author",
            description: "desc",
            sources: [upgradedMeta],
            domains: ["new.invalid"],
            extractedFiles: [:]
        )

        let result = SourceImportFlow.upsertPluginRecords(metas: [upgradedMeta], preview: preview, into: context)
        XCTAssertEqual(result.installedCount, 1)
        XCTAssertEqual(result.orphanPackageIDs, ["old_pkg_v1"])

        let all = try context.fetch(FetchDescriptor<PluginRecord>())
        XCTAssertEqual(all.count, 1, "覆盖升级必须原地更新，不得插入重复记录")
        let updated = try XCTUnwrap(all.first)
        XCTAssertEqual(updated.name, "新名称")
        XCTAssertEqual(updated.version, "2.0.0")
        XCTAssertEqual(updated.packageID, PluginRuntime.sanitizePackageID("../Evil Pkg/v2"))
        XCTAssertFalse(updated.packageID.contains(".."))
        XCTAssertFalse(updated.packageID.contains("/"))

        // 用户自定义属性必须全部保留
        XCTAssertEqual(updated.groupID, "group_favorites")
        XCTAssertEqual(updated.order, 7)
        XCTAssertTrue(updated.isPinned)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertTrue(updated.loggedIn)
        XCTAssertEqual(updated.settingsJSON, "{\"custom\":\"kept\"}")
    }

    /// H2 + M4 回归：拦截私网/回环 SSRF 地址，且严格拒绝损坏本地头或非空 CRC=0 的 ZIP
    func testPrivateNetworkSSRFAndStrictZIPValidation() {
        XCTAssertTrue(JsHostBridge.isPrivateOrLocalURL("http://127.0.0.1:8080/admin"))
        XCTAssertTrue(JsHostBridge.isPrivateOrLocalURL("http://localhost/test"))
        XCTAssertTrue(JsHostBridge.isPrivateOrLocalURL("http://192.168.1.1/router"))
        XCTAssertTrue(JsHostBridge.isPrivateOrLocalURL("http://169.254.169.254/latest/meta-data"))
        XCTAssertTrue(JsHostBridge.isPrivateOrLocalURL("http://10.0.0.5/internal"))
        XCTAssertTrue(JsHostBridge.isPrivateOrLocalURL("http://[::1]/secret"))
        XCTAssertFalse(JsHostBridge.isPrivateOrLocalURL("https://www.ximalaya.com/sound/1"))
        XCTAssertFalse(JsHostBridge.isPrivateOrLocalURL("http://audiobook.example.com/a.mp3"))

        var badCRC = makeStoredZip(entries: [(name: "a.js", data: Data("var x = 1;".utf8))])
        if let cdRange = badCRC.range(of: Data([0x50, 0x4B, 0x01, 0x02])) {
            let crcStart = cdRange.lowerBound + 16
            badCRC.replaceSubrange(crcStart..<(crcStart + 4), with: Data([0, 0, 0, 0]))
        }
        XCTAssertThrowsError(try ZIPArchiveReader.extractAll(from: badCRC))
    }
}
