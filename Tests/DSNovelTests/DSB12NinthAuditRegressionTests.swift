import DSCore
import DSPluginKit
import Foundation
import XCTest

/// 第九轮 4 项精修（b12）定向回归测试套件（总单测数达 303 项）
final class DSB12NinthAuditRegressionTests: XCTestCase {
    // B12-01: decodeCategories 优先展开真实内置书源的 tabs 字段并保留真实分类 URL
    func testB12_01_DecodeCategoriesUnwrapsShunTabsPayload() {
        let json = """
        [
          {
            "title": "热播榜单",
            "tabs": [
              {"title": "热门播放", "url": "tingyou:rank:hot#1"},
              {"title": "最新上架", "url": "tingyou:rank:latest#1"}
            ]
          }
        ]
        """
        let cats = SourceContractAdapter.decodeCategories(json, sourceID: "tingyou")
        XCTAssertEqual(cats.count, 2)
        XCTAssertEqual(cats[0].title, "热播榜单·热门播放")
        XCTAssertEqual(cats[0].url, "tingyou:rank:hot#1")
        XCTAssertEqual(cats[1].url, "tingyou:rank:latest#1")
    }

    // B12-02: decodeDiscoverPage 准确提取 nextUrl 与 hasMore
    func testB12_02_DecodeDiscoverPageExtractsNextURLAndTotalPage() {
        let json = """
        {
          "books": [{"title": "凡人修仙传", "url": "https://e.com/b1"}],
          "currentPage": 1,
          "totalPage": 5,
          "nextUrl": "tingyou:rank:hot#2"
        }
        """
        let page = SourceContractAdapter.decodeDiscoverPage(
            json,
            sourceID: "tingyou",
            sourceName: "听友听书",
            requestedURL: "tingyou:rank:hot#1",
            requestedPage: 1
        )
        XCTAssertEqual(page.books.count, 1)
        XCTAssertEqual(page.nextURL, "tingyou:rank:hot#2")
        XCTAssertTrue(page.hasMore)
    }

    // B12-02: 未显式返回 nextUrl 但 currentPage < totalPage 时自动递增 #page 尾标
    func testB12_02_DecodeDiscoverPageSynthesizesNextHashPageWhenOmitted() {
        let json = """
        {
          "books": [{"title": "斗破苍穹", "url": "https://e.com/b2"}],
          "currentPage": 1,
          "totalPage": 3
        }
        """
        let page = SourceContractAdapter.decodeDiscoverPage(
            json,
            sourceID: "xmly",
            sourceName: "喜马拉雅",
            requestedURL: "xm-cat:youshengshu:xuanhuan#1",
            requestedPage: 1
        )
        XCTAssertEqual(page.nextURL, "xm-cat:youshengshu:xuanhuan#2")
        XCTAssertTrue(page.hasMore)
    }

    // B12-02: 最后一页（nextUrl 为 null 且 currentPage == totalPage）hasMore 为 false
    func testB12_02_DecodeDiscoverPageStopsAtLastPage() {
        let json = """
        {
          "books": [{"title": "尾页书", "url": "https://e.com/last"}],
          "currentPage": 3,
          "totalPage": 3,
          "nextUrl": null
        }
        """
        let page = SourceContractAdapter.decodeDiscoverPage(
            json,
            sourceID: "tingyou",
            sourceName: "听友听书",
            requestedURL: "tingyou:rank:hot#3",
            requestedPage: 3
        )
        XCTAssertNil(page.nextURL)
        XCTAssertFalse(page.hasMore)
    }

    // B12-01: 兼容旧版扁平数组分类结构不回归
    func testB12_01_DecodeCategoriesStillSupportsFlatArray() {
        let json = #"[{"title":"玄幻","url":"https://e.com/xh"}]"#
        let cats = SourceContractAdapter.decodeCategories(json, sourceID: "s1")
        XCTAssertEqual(cats.count, 1)
        XCTAssertEqual(cats.first?.url, "https://e.com/xh")
    }
}
