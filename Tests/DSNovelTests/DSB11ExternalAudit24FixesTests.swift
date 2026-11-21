import DSCore
import DSPluginKit
import DSStorage
import Foundation
import XCTest

/// 外部审计 24 项去合规保解析全量精修（b11）定向回归测试套件
final class DSB11ExternalAudit24FixesTests: XCTestCase {
    // P0-1: SourceContractAdapter 双向兼容 Shun v5.6 与 v3 契约
    func testP0_1_SourceContractAdapterResolvesLegacyAndV3Methods() {
        let shunMethods = ["search", "categoryMenus", "categoryPage", "bookDetail", "audio"]
        XCTAssertEqual(SourceContractAdapter.resolveMethodName(requested: "discoverCategories", available: shunMethods), "categoryMenus")
        XCTAssertEqual(SourceContractAdapter.resolveMethodName(requested: "discover", available: shunMethods), "categoryPage")
        XCTAssertEqual(SourceContractAdapter.resolveMethodName(requested: "detail", available: shunMethods), "bookDetail")
        XCTAssertEqual(SourceContractAdapter.qualityArgument(for: .high), "M4A_128")
        XCTAssertEqual(SourceContractAdapter.qualityArgument(for: .saver), "M4A_24")
    }

    // P0-1: decodeBooks 兼容 { books: [...], totalPage } 包装结构与 artist/status 字段
    func testP0_1_DecodeBooksHandlesWrappedShunPayload() {
        let json = """
        {"books":[{"name":"雪中悍刀行","bookUrl":"https://e.com/b1","artist":"烽火戏诸侯","status":"完结"}],"totalPage":3}
        """
        let list = SourceContractAdapter.decodeBooks(json, sourceID: "xmly", sourceName: "喜马拉雅")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.title, "雪中悍刀行")
        XCTAssertEqual(list.first?.author, "烽火戏诸侯")
        XCTAssertEqual(list.first?.latestChapter, "完结")
    }

    // P0-1: decodeBookDetail 兼容 episodes 字段
    func testP0_1_DecodeBookDetailHandlesEpisodesArray() {
        let fallback = BookSummaryDTO(id: "xmly::1", sourceID: "xmly", bookURL: "https://e.com/b1", title: "测试书")
        let json = """
        {"title":"测试书","episodes":[{"title":"第1集","url":"https://e.com/e1","duration":120,"isVip":true}]}
        """
        let detail = SourceContractAdapter.decodeBookDetail(json, fallback: fallback)
        XCTAssertEqual(detail.chapters.count, 1)
        XCTAssertEqual(detail.chapters.first?.durationMs, 120_000)
        XCTAssertEqual(detail.chapters.first?.isVIP, true)
    }

    // P0-1: 方法缺失哨兵转为显式错误
    func testP0_1_MissingMethodSentinelThrowsExplicitError() {
        XCTAssertThrowsError(try SourceContractAdapter.checkMissingMethodSentinel(#"{"__dsMissingMethod":"discover"}"#))
    }

    // P0-4: 状态机允许 queued -> completed 以支持后台暂存认领
    func testP0_4_DownloadStateAllowsQueuedToCompleted() {
        XCTAssertTrue(DownloadState.queued.canTransition(to: .completed))
    }

    // P0-5*: 禁止非内置导入静默覆盖内置书源保留 ID
    func testP0_5_ProtectBundledSourceIDFromExternalOverwrite() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let bundled = SourceMetaDTO(id: "bundled-xmly", name: "喜马拉雅")
        try await engine.upsertSource(meta: bundled, scriptBody: "/* bundled */", isBundled: true)

        let attacker = SourceMetaDTO(id: "bundled-xmly", name: "伪造源")
        do {
            try await engine.upsertSource(meta: attacker, scriptBody: "/* evil */", isBundled: false)
            XCTFail("应拒绝非内置书源覆盖内置书源 ID")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("冲突"))
        }
    }

    // P1-2*: SSRFGuard 识别八进制/整数/IPv4-mapped IPv6/保留段变体
    func testP1_2_SSRFGuardBlocksNormalizedIPv4AndIPv6Variants() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("127.1"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("0177.0.0.1"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("2130706433"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("::ffff:7f00:1"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("0:0:0:0:0:0:0:1"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("100.64.0.1"))
        // 198.18.0.0/15 放行以兼容 iOS Fake-IP 代理
        XCTAssertFalse(SSRFGuard.isBlockedHost("198.18.0.1"))
        XCTAssertFalse(SSRFGuard.isBlockedHost("198.19.255.254"))
        XCTAssertFalse(SSRFGuard.isBlockedHost("m.ximalaya.com"))
    }

    // P1-8: pruneOldChapterProgress 按书分组裁剪且保留 isFinished 标记
    func testP1_8_PruneOldChapterProgressGroupsPerBookAndKeepsFinished() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let b1 = BookSummaryDTO(id: "b1", sourceID: "s", bookURL: "u1", title: "书一")
        let b2 = BookSummaryDTO(id: "b2", sourceID: "s", bookURL: "u2", title: "书二")
        for i in 0..<5 {
            await engine.saveProgress(
                book: b1,
                chapter: ChapterDTO(id: "b1-\(i)", index: i, title: "章\(i)", url: "u\(i)"),
                positionMs: 1000, durationMs: 60_000, isFinished: (i == 0), overrideFinished: false
            )
            await engine.saveProgress(
                book: b2,
                chapter: ChapterDTO(id: "b2-\(i)", index: i, title: "章\(i)", url: "v\(i)"),
                positionMs: 1000, durationMs: 60_000, isFinished: false, overrideFinished: false
            )
        }
        let deleted = try await engine.pruneOldChapterProgress(keepLatestPerBook: 3)
        XCTAssertEqual(deleted, 3) // b1 保留最新3条+最早isFinished(删1条)，b2 删2条
        let finishedKept = await engine.loadChapterProgress(bookID: "b1", chapterID: "b1-0")
        XCTAssertEqual(finishedKept?.isFinished, true)
    }

    // P1-9: SkipConfigDTO 反序列化钳制非法负数与超大值，且旧备份不回退较新进度
    func testP1_9_SkipConfigDecodeClampsAndNewerProgressWins() async throws {
        let badJSON = Data(#"{"introSeconds":-50,"outroSeconds":9999}"#.utf8)
        let decoded = try JSONDecoder().decode(SkipConfigDTO.self, from: badJSON)
        XCTAssertEqual(decoded.introSeconds, 0)
        XCTAssertEqual(decoded.outroSeconds, 600)

        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        let now = Date()
        let newerPayload = LibraryBackupPayload(appVersion: "3.0.0", books: [
            LibraryBackupPayload.BackupBook(
                id: "m1", sourceID: "s", sourceName: "S", bookURL: "u", title: "书",
                author: "", narrator: "", coverURL: "", inShelf: true, isPinned: false,
                shelfGroupName: "", lastPlayedAt: now, lastChapterIndex: 10,
                lastChapterTitle: "第11章", lastPositionMs: 30_000, skipConfig: SkipConfigDTO()
            )
        ])
        _ = try await engine.importLibraryBackup(newerPayload)

        let olderPayload = LibraryBackupPayload(appVersion: "3.0.0", books: [
            LibraryBackupPayload.BackupBook(
                id: "m1", sourceID: "s", sourceName: "S", bookURL: "u", title: "书",
                author: "", narrator: "", coverURL: "", inShelf: true, isPinned: false,
                shelfGroupName: "", lastPlayedAt: now.addingTimeInterval(-3600), lastChapterIndex: 2,
                lastChapterTitle: "第3章", lastPositionMs: 5_000, skipConfig: SkipConfigDTO()
            )
        ])
        _ = try await engine.importLibraryBackup(olderPayload)
        let last = await engine.fetchBookLastPlayback(bookID: "m1")
        XCTAssertEqual(last?.chapterIndex, 10)
        XCTAssertEqual(last?.positionMs, 30_000)
    }

    // P1-15: 升级内置源时自动清理已移除旧内置源
    func testP1_15_PruneRemovedBundledSourcesKeepsActiveAndExternal() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)
        try await engine.upsertSource(meta: SourceMetaDTO(id: "old-b", name: "旧内置"), scriptBody: "", isBundled: true)
        try await engine.upsertSource(meta: SourceMetaDTO(id: "new-b", name: "新内置"), scriptBody: "", isBundled: true)
        try await engine.upsertSource(meta: SourceMetaDTO(id: "ext-1", name: "用户源"), scriptBody: "", isBundled: false)

        let removed = try await engine.pruneRemovedBundledSources(keepingIDs: ["new-b"])
        XCTAssertEqual(removed, 1)
        let remaining = try await engine.fetchAllSources().map(\.meta.id)
        XCTAssertEqual(Set(remaining), Set(["new-b", "ext-1"]))
    }

    // P1-16: 日志脱敏覆盖多值 Cookie、JSON token 与 bearer
    func testP1_16_DiagnosticSanitizeRedactsFullCookieAndJSONTokens() {
        let raw = #"Cookie: a=1; b=secret2; c=3\n{"token":"abc123","xm_sign":"xyz"} Authorization: Bearer tok_999"#
        let clean = DSDiagnosticLogStore.sanitize(raw)
        XCTAssertFalse(clean.contains("secret2"))
        XCTAssertFalse(clean.contains("abc123"))
        XCTAssertFalse(clean.contains("xyz"))
        XCTAssertFalse(clean.contains("tok_999"))
    }

    // P1-17: htmlDecode 单遍扫描不二次解码 &amp;lt;，支持大写 &#X41; 并过滤 &#0;
    func testP1_17_HtmlDecodeSinglePassPreventsDoubleDecode() {
        XCTAssertEqual(DSCrypto.htmlDecode("&amp;lt;div&amp;gt;"), "&lt;div&gt;")
        XCTAssertEqual(DSCrypto.htmlDecode("&#X41;&#66;&#0;"), "AB")
    }
}
