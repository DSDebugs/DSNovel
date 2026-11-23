import DSCore
import DSDesignSystem
import XCTest
@testable import DSNovel

final class DSUnifiedSearchAndHotBooksTests: XCTestCase {
    @MainActor
    func testNormalizeHotBookTitleStripsNoiseAndBrackets() {
        XCTAssertEqual(
            SearchViewModel.normalizeHotBookTitle("【免费】雪中悍刀行 | 多人有声剧"),
            "雪中悍刀行"
        )
        XCTAssertEqual(
            SearchViewModel.normalizeHotBookTitle("雪中悍刀行（完整版）"),
            "雪中悍刀行"
        )
        XCTAssertEqual(
            SearchViewModel.normalizeHotBookTitle("凡人修仙传 第一季"),
            "凡人修仙传"
        )
    }

    @MainActor
    func testMergeAggregatedHotBooksPrioritizesMultiSourceConsensusAndInterleaves() {
        func makeBook(id: String, sourceID: String, sourceName: String, title: String) -> BookSummaryDTO {
            BookSummaryDTO(
                id: id,
                sourceID: sourceID,
                sourceName: sourceName,
                bookURL: "https://example.com/\(id)",
                title: title,
                author: "作者",
                narrator: "演播",
                coverURL: "https://example.com/\(id).jpg",
                intro: "",
                latestChapter: "",
                statusText: "",
                totalChapters: 100
            )
        }

        let perSource: [String: [BookSummaryDTO]] = [
            "s1": [
                makeBook(id: "1a", sourceID: "s1", sourceName: "喜马拉雅", title: "A独有书"),
                makeBook(id: "1b", sourceID: "s1", sourceName: "喜马拉雅", title: "【免费】共热爆款"),
                makeBook(id: "1c", sourceID: "s1", sourceName: "喜马拉雅", title: "A第二书")
            ],
            "s2": [
                makeBook(id: "2a", sourceID: "s2", sourceName: "听友听书", title: "B独有书"),
                makeBook(id: "2b", sourceID: "s2", sourceName: "听友听书", title: "共热爆款（完整版）")
            ],
            "s3": [
                makeBook(id: "3a", sourceID: "s3", sourceName: "博看有声", title: "C独有书")
            ]
        ]

        let merged = SearchViewModel.mergeAggregatedHotBooks(
            from: perSource,
            sourceOrder: ["s1", "s2", "s3"],
            limit: 15
        )

        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(SearchViewModel.normalizeHotBookTitle(merged[0].title), "共热爆款")
        XCTAssertEqual(merged[1].sourceID, "s1")
        XCTAssertEqual(merged[2].sourceID, "s2")
        XCTAssertEqual(merged[3].sourceID, "s3")
        XCTAssertEqual(merged[4].title, "A第二书")
    }

    @MainActor
    func testExtractSuggestionKeywordsPrioritizesHistoryAndDeduplicates() {
        let book = BookSummaryDTO(
            id: "b1",
            sourceID: "s1",
            sourceName: "喜马拉雅",
            bookURL: "https://example.com/b1",
            title: "凡人修仙传 | 多人有声剧",
            author: "忘语",
            narrator: "大灰狼",
            coverURL: "",
            intro: "",
            latestChapter: "",
            statusText: "",
            totalChapters: 1000
        )

        let items = SearchViewModel.extractSuggestionKeywords(
            from: [book],
            localHistory: ["凡人修仙传", "三体"],
            localBooks: [],
            term: "凡人",
            limit: 8
        )

        XCTAssertEqual(items.first?.text, "凡人修仙传")
        XCTAssertEqual(items.first?.isFromHistory, true)
        XCTAssertEqual(items.count, 1)
    }

    @MainActor
    func testRouterRoutesNarratorAndOpenSearchToHomeTab() {
        let router = AppRouter()
        router.selectedTab = .library
        router.searchByNarrator("头陀渊")
        XCTAssertEqual(router.selectedTab, .discover)
        XCTAssertEqual(router.consumePendingNarratorSearch(), "头陀渊")
        XCTAssertNil(router.consumePendingNarratorSearch())

        router.selectedTab = .me
        router.openSearch()
        XCTAssertEqual(router.selectedTab, .discover)
        XCTAssertTrue(router.consumePendingOpenSearch())
        XCTAssertFalse(router.consumePendingOpenSearch())
    }
}
