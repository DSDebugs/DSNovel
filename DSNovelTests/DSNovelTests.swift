import XCTest
@testable import DSNovel

final class DSNovelTests: XCTestCase {

    /// 1. 校验 HTML DOM 选择器与 SSTS 插件桥接（registerSource / doc.select / .first / .absUrl）冒烟测试
    func testHTMLSelectorAndPluginBridgeSmoke() {
        let sampleHTML = """
        <div class="list">
          <div class="item" data-id="101">
            <img src="/covers/101.jpg" />
            <a href="/book/101.html"><h3>测试有声小说</h3></a>
          </div>
        </div>
        """
        let doc = JsElement.parse(html: sampleHTML, baseURL: "https://example.com")
        let items = doc.select(".item")
        XCTAssertEqual(items.count, 1)
        let firstItem = items[0]
        XCTAssertEqual(firstItem.first("h3").text(), "测试有声小说")
        XCTAssertEqual(firstItem.first("img").absUrl("src"), "https://example.com/covers/101.jpg")
        XCTAssertEqual(firstItem.first("a").absUrl("href"), "https://example.com/book/101.html")
    }

    /// 2. 校验章节 1–50 分段切片算法（报告 5.4 节）
    func testChapterSegmentation() {
        let segments = BookDetailViewModel.buildSegments(totalCount: 120, pageSize: 50)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].label, "1–50")
        XCTAssertEqual(segments[1].label, "51–100")
        XCTAssertEqual(segments[2].label, "101–120")
    }

    /// 3. 校验睡眠定时最后 30 秒线性音量渐弱曲线（报告 4.3 节）
    func testSleepTimerLinearFadeOutCurve() {
        let fullVol = PlayerEngine.computeFadeVolume(baseVolume: 0.8, remainingSeconds: 45, fadeEnabled: true)
        XCTAssertEqual(fullVol, 0.8, accuracy: 0.001)

        let halfFade = PlayerEngine.computeFadeVolume(baseVolume: 0.8, remainingSeconds: 15, fadeEnabled: true)
        XCTAssertEqual(halfFade, 0.4, accuracy: 0.001)

        let disabledFade = PlayerEngine.computeFadeVolume(baseVolume: 0.8, remainingSeconds: 10, fadeEnabled: false)
        XCTAssertEqual(disabledFade, 0.8, accuracy: 0.001)
    }

    /// 4. 校验多源搜索结果按「标题 + 作者」归一化去重与换源折叠（报告 5.3 节）
    func testSearchResultDeduplicationAndMerge() {
        let b1 = BookRef(sourceID: "src_a", bookURL: "https://a.com/1", title: "凡人修仙传 ", author: "忘语")
        let b2 = BookRef(sourceID: "src_b", bookURL: "https://b.com/99", title: "凡人修仙传", author: " 忘语 ")
        let merged = SearchViewModel.mergeBookResults([b1, b2], into: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].primary.sourceID, "src_a")
        XCTAssertEqual(merged[0].alternatives.count, 1)
        XCTAssertEqual(merged[0].alternatives[0].sourceID, "src_b")
    }

    /// 5. 校验章节 LZFSE 压缩缓存往返读写（报告 4.1 节）
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
}
