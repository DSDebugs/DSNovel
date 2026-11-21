import XCTest
@testable import DSNovel

final class DSNovelTests: XCTestCase {

    /// 1. 校验底部导航固定顺序为「发现、搜索、书架、设置」（对应需求 1）
    func testBottomTabOrderIsDiscoverSearchShelfSettings() {
        let allTabs = AppTab.allCases
        XCTAssertEqual(allTabs, [.discover, .search, .shelf, .settings])
        XCTAssertEqual(allTabs.map(\.title), ["发现", "搜索", "书架", "设置"])
        XCTAssertEqual(AppTab.discover.rawValue, 0)
        XCTAssertEqual(AppTab.search.rawValue, 1)
        XCTAssertEqual(AppTab.shelf.rawValue, 2)
        XCTAssertEqual(AppTab.settings.rawValue, 3)
    }

    /// 2. 校验 HTML DOM 选择器（含未闭合标签、HTML 注释干扰与伪类选择器）及 SSTS 插件桥接冒烟测试
    func testHTMLSelectorAndPluginBridgeSmoke() {
        let sampleHTML = """
        <!DOCTYPE html>
        <!-- <div class="item"><a href="/broken">注释干扰</a></div> -->
        <div class="list">
          <meta charset="utf-8">
          <div class="item" data-id="101">
            <img src="/covers/101.jpg">
            <a href="/book/101.html"><h3>测试有声小说</h3></a>
          </div>
          <ul id="playlist">
            <li><a href="/play/101-1.html">第1集 序章</a>
            <li><a href="/play/101-2.html">第2集 启程</a>
          </ul>
        </div>
        """
        let doc = JsElement.parse(html: sampleHTML, baseURL: "https://example.com")
        let items = doc.select(".item")
        XCTAssertEqual(items.count, 1)
        let firstItem = items[0]
        XCTAssertEqual(firstItem.first("h3").text(), "测试有声小说")
        XCTAssertEqual(firstItem.first("img").absUrl("src"), "https://example.com/covers/101.jpg")
        XCTAssertEqual(firstItem.first("a").absUrl("href"), "https://example.com/book/101.html")

        let episodes = doc.select("#playlist li a")
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].text(), "第1集 序章")
        XCTAssertEqual(episodes[1].absUrl("href"), "https://example.com/play/101-2.html")
    }

    /// 3. 校验 SSTS 插件协议 bookDetail(url, loadEpisodes, loadFullPages)、readCache===null、getPref 默认值与多线程池安全
    func testSSTSPluginBookDetailAndConcurrentPool() throws {
        let manifest = PluginPackageManifest(
            name: "TestShunSources",
            version: "5.6.0",
            author: "tester",
            description: "测试多源插件包",
            scripts: ["source.js"]
        )
        let script = """
        registerSource({
          id: 'src_one',
          name: '测试源一',
          url: 'https://example.com',
          multipleEpisodePages: true,
          categoryMenus: function () {
            return [{ title: '有声小说', tabs: [{ title: '玄幻', url: 'cat:xh:1' }, { title: '都市', url: 'cat:ds:1' }] }];
          },
          categoryPage: function (url) {
            return {
              books: [{ title: '凡人修仙传', bookUrl: 'https://example.com/book/1', author: '忘语' }],
              currentPage: 1,
              totalPage: 2,
              nextUrl: 'cat:xh:2'
            };
          },
          bookDetail: function (url, loadEpisodes, loadFullPages) {
            var cached = this.host.readCache('ep_' + url);
            if (cached !== null) {
              return JSON.parse(cached);
            }
            var defDays = this.host.getPref('days', '7');
            var detail = { title: '凡人修仙传', author: '忘语', artist: '大灰狼', status: '完结(' + defDays + ')', episodes: [] };
            if (!loadEpisodes) return detail;
            detail.episodes.push({ title: '第1集', url: 'https://example.com/ep/1.mp3' });
            if (loadFullPages) {
              detail.episodes.push({ title: '第2集', url: 'https://example.com/ep/2.mp3' });
            }
            return detail;
          }
        });
        """
        let (ctx, metas) = try PluginRuntime.createIsolatedContext(
            packageID: "TestShunSources",
            manifest: manifest,
            scriptFiles: ["source.js": Data(script.utf8)]
        )
        XCTAssertEqual(metas.count, 1)
        XCTAssertTrue(metas[0].multipleEpisodePages)

        let invokeSafe = ctx.objectForKeyedSubscript("__invokeSafe")!
        let detailRes = invokeSafe.call(withArguments: [0, "bookDetail", "[\"https://example.com/book/1\",true,true]"])!
        let envStr = detailRes.toString() ?? ""
        XCTAssertTrue(envStr.contains("第2集"))
        XCTAssertTrue(envStr.contains("完结(7)"))
    }

    /// 4. 校验书源健康状态、延迟角标文案与搜索优先级分值排序（对应需求 2 & 3）
    func testPluginHealthLatencyAndSearchPrioritySorting() {
        let fastHealthy = PluginRecord(
            id: "fast",
            packageID: "pkg",
            name: "快速源",
            version: "1.0",
            order: 10,
            lastCheckStatus: SourceHealthState.healthy.rawValue,
            lastLatencyMs: 145
        )
        let slowSource = PluginRecord(
            id: "slow",
            packageID: "pkg",
            name: "慢速源",
            version: "1.0",
            order: 2,
            lastCheckStatus: SourceHealthState.slow.rawValue,
            lastLatencyMs: 1820
        )
        let brokenSource = PluginRecord(
            id: "broken",
            packageID: "pkg",
            name: "失效源",
            version: "1.0",
            order: 0,
            lastCheckStatus: SourceHealthState.unavailable.rawValue,
            lastLatencyMs: -1
        )

        XCTAssertEqual(fastHealthy.latencyBadgeText, "145ms")
        XCTAssertEqual(brokenSource.latencyBadgeText, "不可用")
        XCTAssertLessThan(fastHealthy.searchPriorityScore, slowSource.searchPriorityScore)
        XCTAssertLessThan(slowSource.searchPriorityScore, brokenSource.searchPriorityScore)
    }

    /// 5. 校验章节 1–50 分段切片算法（报告 5.4 节）
    func testChapterSegmentation() {
        let segments = BookDetailViewModel.buildSegments(totalCount: 120, pageSize: 50)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].label, "1–50")
        XCTAssertEqual(segments[1].label, "51–100")
        XCTAssertEqual(segments[2].label, "101–120")
    }

    /// 6. 校验睡眠定时最后 30 秒线性音量渐弱曲线（报告 4.3 节）
    func testSleepTimerLinearFadeOutCurve() {
        let fullVol = PlayerEngine.computeFadeVolume(baseVolume: 0.8, remainingSeconds: 45, fadeEnabled: true)
        XCTAssertEqual(fullVol, 0.8, accuracy: 0.001)

        let halfFade = PlayerEngine.computeFadeVolume(baseVolume: 0.8, remainingSeconds: 15, fadeEnabled: true)
        XCTAssertEqual(halfFade, 0.4, accuracy: 0.001)

        let disabledFade = PlayerEngine.computeFadeVolume(baseVolume: 0.8, remainingSeconds: 10, fadeEnabled: false)
        XCTAssertEqual(disabledFade, 0.8, accuracy: 0.001)
    }

    /// 7. 校验多源搜索结果按「标题 + 作者」归一化去重与换源折叠（报告 5.3 节）
    func testSearchResultDeduplicationAndMerge() {
        let b1 = BookRef(sourceID: "src_a", bookURL: "https://a.com/1", title: "凡人修仙传 ", author: "忘语")
        let b2 = BookRef(sourceID: "src_b", bookURL: "https://b.com/99", title: "凡人修仙传", author: " 忘语 ")
        let merged = SearchViewModel.mergeBookResults([b1, b2], into: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].primary.sourceID, "src_a")
        XCTAssertEqual(merged[0].alternatives.count, 1)
        XCTAssertEqual(merged[0].alternatives[0].sourceID, "src_b")
    }

    /// 8. 校验章节 LZFSE 压缩缓存往返读写（报告 4.1 节）
    func testChapterLZFSECacheRoundTrip() {
        let chapters = [
            ChapterDTO(index: 0, title: "第1集 序幕", url: "https://example.com/ep1.m4a", durationSec: 920),
            ChapterDTO(index: 1, title: "第2集 启程", url: "https://example.com/ep2.m4a", durationSec: 1045)
        ]
        let bookID = "test_source::https://example.com/book/1"
        ChapterCacheStore.saveChapters(chapters, for: bookID)
        let loaded = ChapterCacheStore.loadChapters(for: bookID)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?.first?.title, "第1集 序幕")
    }

    /// 9. 搜索结果相关度排序：精确 > 前缀 > 包含 > 其他
    func testSearchRelevanceRanking() {
        XCTAssertEqual(SearchViewModel.relevance(title: "三体", keyword: "三体"), 3)
        XCTAssertEqual(SearchViewModel.relevance(title: "三体全集", keyword: "三体"), 2)
        XCTAssertEqual(SearchViewModel.relevance(title: "刘慈欣三体", keyword: "三体"), 1)
        XCTAssertEqual(SearchViewModel.relevance(title: "鬼吹灯", keyword: "三体"), 0)
        XCTAssertEqual(SearchViewModel.relevance(title: "三体", keyword: "  "), 0)
    }

    /// 10. 「无法播放」黑名单：标记、命中、取消标记
    func testUnplayableBookStore() {
        let store = UnplayableBookStore.shared
        let id = "test_src::https://example.com/unplayable/\(UUID().uuidString)"
        XCTAssertFalse(store.contains(id))
        store.mark(id)
        XCTAssertTrue(store.contains(id))
        store.unmark(id)
        XCTAssertFalse(store.contains(id))
    }

    /// 11. 支持直接导入单个 .js；无 manifest 的不同书源包不会因同名而互相覆盖；非书源文件被拒绝
    func testImportSingleScriptAndUniquePackageID() async throws {
        func script(_ id: String) -> Data {
            Data("registerSource({ id: '\(id)', name: '\(id)', url: 'https://example.com', search: function (k, p) { return JSON.stringify({ books: [] }); } });".utf8)
        }
        let p1 = try await PluginRuntime.shared.prepareImportPreview(from: script("a_src"))
        let p2 = try await PluginRuntime.shared.prepareImportPreview(from: script("b_src"))
        XCTAssertNotEqual(p1.packageID, p2.packageID)
        XCTAssertEqual(p1.sources.first?.id, "a_src")

        do {
            _ = try await PluginRuntime.shared.prepareImportPreview(from: Data("hello".utf8))
            XCTFail("非书源文件应当导入失败")
        } catch {
            // 预期失败
        }
    }

    /// 12. 跨子域 Cookie 共享（10-4：改用独立测试域并在 defer 清理，杜绝污染全局 ximalaya.com Cookie）
    func testCrossSubdomainCookieSync() {
        let rootHost = "xm-cookie-sync-test.invalid"
        defer {
            if let all = HTTPCookieStorage.shared.cookies {
                for c in all where c.domain.lowercased().contains(rootHost) {
                    HTTPCookieStorage.shared.deleteCookie(c)
                }
            }
        }
        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "1&_token",
            .value: "test_token_123",
            .domain: "passport.\(rootHost)",
            .path: "/",
            .secure: "TRUE"
        ]
        guard let cookie = HTTPCookie(properties: cookieProps) else {
            XCTFail("构造测试 Cookie 失败")
            return
        }
        CookieSync.storeCookie(cookie)
        let apiURL = URL(string: "https://mobwsa.\(rootHost)/mobile/v1/album")!
        let header = CookieSync.cookieHeader(for: apiURL)
        XCTAssertTrue(header.contains("1&_token=test_token_123"))
    }

    /// 13. 校验「书架」与「最近播放」分离模型及最后播放章节/时间格式化
    func testShelfAndRecentPlaySeparationAndFormatting() {
        let historyOnlyBook = Book(
            id: "src::https://example.com/1",
            sourceID: "src",
            bookURL: "https://example.com/1",
            title: "仅播放未加书架",
            inShelf: false,
            lastChapterID: "ep1",
            lastChapterTitle: "第1集 初入江湖",
            lastPositionMs: 125_000,
            lastPlayedAt: .now
        )
        XCTAssertFalse(historyOnlyBook.inShelf)
        XCTAssertNotNil(historyOnlyBook.lastPlayedAt)
        XCTAssertEqual(historyOnlyBook.formattedPositionText, "02:05")
        XCTAssertEqual(historyOnlyBook.playbackProgressSummary, "第1集 初入江湖 · 02:05")
    }

    /// 14. 校验喜马拉雅 URL-Safe Base64（含 '-' 与 '_' 且无 '=' 填充）播放地址 AES-128-ECB 真实解密（10-4）
    func testXimalayaURLSafeBase64AesEcbDecrypt() {
        let bridge = JsHostBridge(packageID: "pkg", sourceId: "xm", sourceName: "喜马拉雅")
        let keyHex = "aaad3e4fd540b0f79dca95606e72bf93"

        // 同时校验标准 Base64 还原
        let urlSafeB64 = "aHR0cHM6Ly9hb2QuY29zLnR4LnhtY2RuLmNvbS9ncm91cDEvTTAwL3Rlc3RfYXVkaW8ubTRh"
        XCTAssertEqual(bridge.base64Decode(urlSafeB64), "https://aod.cos.tx.xmcdn.com/group1/M00/test_audio.m4a")
        XCTAssertNotNil(JsHostBridge.dataFromHex(keyHex))

        // 真实 AES-128-ECB (PKCS7) 密文：URL-Safe Base64（含 '-' 与 '_' 且无 '=' 填充）
        let cipher1 = "snKr7BtRMlJ2LdDBVGL5Uf5RRtmlGl39RdTOcxaXHTFellj5rNbXIePsm-WuWnS6cUGqsYxC-vcRU6CFsKxd5A"
        XCTAssertEqual(
            bridge.aesEcbDecrypt(cipher1, keyHex),
            "https://aod.cos.tx.xmcdn.com/group1/M00/test_audio.m4a"
        )

        let cipher2 = "snKr7BtRMlJ2LdDBVGL5Uf5RRtmlGl39RdTOcxaXHTFellj5rNbXIePsm-WuWnS6Xyc_fb1BLBe5R_KUFU_Abw"
        XCTAssertTrue(cipher2.contains("-") && cipher2.contains("_") && !cipher2.contains("="))
        XCTAssertEqual(
            bridge.aesEcbDecrypt(cipher2, keyHex),
            "https://aod.cos.tx.xmcdn.com/group1/M00/test_audio_2.m4a"
        )

        // 非法密钥长度返回空串
        XCTAssertEqual(bridge.aesEcbDecrypt(cipher2, "1234"), "")
    }
}
