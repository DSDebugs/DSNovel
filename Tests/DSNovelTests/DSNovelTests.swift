import XCTest
@testable import DSNovel

final class DSNovelTests: XCTestCase {
    func testEpisodeTitleFormatting() {
        XCTAssertEqual(EpisodeItem.formatEpisodeTitle("007", index: 7, bookTitle: ""), "第7集")
        XCTAssertEqual(EpisodeItem.formatEpisodeTitle("12 夜袭", index: 12, bookTitle: ""), "第12集 夜袭")
        XCTAssertEqual(EpisodeItem.formatEpisodeTitle("《凡人修仙传》第3章 入门", index: 3, bookTitle: "凡人修仙传"), "第3章 入门")
        XCTAssertEqual(EpisodeItem.formatEpisodeTitle("集合", index: 3, bookTitle: ""), "第3集 集合")
    }

    func testDeduplicatePreservesDifferentNarrators() {
        let b1 = BookItem(albumId: "1", title: "剑来", author: "主播A", coverURL: "", intro: "")
        let b2 = BookItem(albumId: "2", title: "剑来", author: "主播B", coverURL: "", intro: "")
        let out = DualSourceEngine.deduplicateBooks([b1, b2])
        XCTAssertEqual(out.count, 2)
    }

    func testWorkMatcher() {
        let b1 = BookItem(albumId: "1", title: "凡人修仙传（有声剧）", author: "张三", coverURL: "", intro: "", totalTracks: 1000)
        let b2 = BookItem(albumId: "2", title: "凡人修仙传", author: "张三", coverURL: "", intro: "", totalTracks: 1020)
        let b3 = BookItem(albumId: "3", title: "凡人修仙传", author: "李四", coverURL: "", intro: "", totalTracks: 1000)
        XCTAssertTrue(WorkMatcher.isSameWork(b1, b2))
        XCTAssertFalse(WorkMatcher.isSameWork(b1, b3))
    }

    func testHostMatching() {
        XCTAssertTrue(DualSourceEngine.isOfficialXimalayaHost("mobile.ximalaya.com"))
        XCTAssertFalse(DualSourceEngine.isOfficialXimalayaHost("evil.example"))
    }

    func testQXRewriteLocalParser() {
        let conf = """
        # comment line
        [rewrite_local]
        ^https://example\\.com/api/feed url response-body "old" "new"
        ^https://example\\.com/api/hdr url request-header X-Custom-Tag demo
        ^https://example\\.com/ad url reject-dict
        ^https://example\\.com/mock url echo-response application/json "{\\"ok\\":true}"
        ^https://example\\.com/js url script-response-body https://example.com/rewrite.js
        [mitm]
        hostname = example.com
        """
        let rules = QXRewriteParserEngine.parseRewriteLocalRules(conf)
        XCTAssertEqual(rules.count, 5)
        XCTAssertEqual(rules[0].action, .responseBody)
        XCTAssertEqual(rules[0].argument1, "old")
        XCTAssertEqual(rules[0].argument2, "new")
        XCTAssertEqual(rules[1].action, .requestHeader)
        XCTAssertEqual(rules[2].action, .rejectDict)
        XCTAssertEqual(rules[3].action, .echoResponse)
        XCTAssertEqual(rules[4].action, .scriptResponseBody)
    }

    func testCompliantHTTPSValidation() {
        XCTAssertNotNil(CompliantDataUpdateModule.isValidHTTPSURL("https://example.com/catalog.json"))
        XCTAssertNil(CompliantDataUpdateModule.isValidHTTPSURL("http://example.com/catalog.json"))
        XCTAssertNil(CompliantDataUpdateModule.isValidHTTPSURL("not-a-url"))
    }
}
