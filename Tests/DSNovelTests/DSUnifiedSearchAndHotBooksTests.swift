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
    func testHotBooksPreferredSourceAndSourceManagementPriorityUpTo30() {
        let sources = [
            SourceMetaDTO(id: "tsw", name: "听书网", version: "1", summary: "", methods: ["search"], isEnabled: true, isPinned: false, groupName: "主力书源", sortOrder: 2),
            SourceMetaDTO(id: "xmly", name: "喜马拉雅", version: "1", summary: "", methods: ["search"], isEnabled: true, isPinned: false, groupName: "主力书源", sortOrder: 3),
            SourceMetaDTO(id: "ty", name: "听友听书", version: "1", summary: "", methods: ["search"], isEnabled: true, isPinned: true, groupName: "精品有声", sortOrder: 5)
        ]

        let prioritized = SearchViewModel.prioritizedSources(sources, activeDiscoverSourceID: "xmly")
        XCTAssertEqual(prioritized.map(\.id), ["xmly", "ty", "tsw"])

        func makeBooks(sourceID: String, sourceName: String, count: Int) -> [BookSummaryDTO] {
            (1...count).map { idx in
                BookSummaryDTO(
                    id: "\(sourceID)-\(idx)",
                    sourceID: sourceID,
                    sourceName: sourceName,
                    bookURL: "https://example.com/\(sourceID)/\(idx)",
                    title: "\(sourceName)热书\(idx)",
                    author: "作者",
                    narrator: "演播",
                    coverURL: "https://example.com/\(sourceID)/\(idx).jpg"
                )
            }
        }

        let perSource: [String: [BookSummaryDTO]] = [
            "xmly": makeBooks(sourceID: "xmly", sourceName: "喜马拉雅", count: 15),
            "ty": makeBooks(sourceID: "ty", sourceName: "听友听书", count: 15),
            "tsw": makeBooks(sourceID: "tsw", sourceName: "听书网", count: 15)
        ]

        let merged = SearchViewModel.mergeAggregatedHotBooks(
            from: perSource,
            sourceOrder: prioritized.map(\.id),
            preferredSourceID: "xmly",
            limit: SearchViewModel.defaultHotBooksLimit
        )

        XCTAssertEqual(merged.count, 30)
        XCTAssertEqual(merged[0].sourceID, "xmly")
        XCTAssertEqual(merged[1].sourceID, "xmly")
        XCTAssertEqual(merged[2].sourceID, "xmly")
    }

    @MainActor
    func testScopeChipsHideUndefinedGroupsAndFormatCurrentSourceLabel() {
        let vm = SearchViewModel()
        vm.activeDiscoverSourceName = "喜马拉雅"
        vm.searchableSources = [
            SourceMetaDTO(id: "xmly", name: "喜马拉雅", version: "1", summary: "", methods: ["search"], isEnabled: true, isPinned: false, groupName: "主力书源", sortOrder: 0),
            SourceMetaDTO(id: "bk", name: "博看有声", version: "1", summary: "", methods: ["search"], isEnabled: true, isPinned: false, groupName: "精品有声", sortOrder: 1)
        ]

        // 未定义自定义分组时，仅展示「全部书源」与「当前书源：喜马拉雅」
        XCTAssertEqual(vm.scopeChips.map(\.title), ["全部书源", "当前书源：喜马拉雅"])

        // 仅当书源管理中自定义了分组且存在对应启用源时才追加
        vm.customSourceGroups = ["睡前常听", "精品有声"]
        XCTAssertEqual(vm.scopeChips.map(\.title), ["全部书源", "当前书源：喜马拉雅", "精品有声"])
    }

    @MainActor
    func testExtractSuggestionKeywordsPrioritizesHistoryAndPrefixMatches() {
        let books = [
            BookSummaryDTO(
                id: "b1",
                sourceID: "s1",
                sourceName: "喜马拉雅",
                bookURL: "https://example.com/b1",
                title: "大奉凡人传",
                author: "作者",
                narrator: "演播A"
            ),
            BookSummaryDTO(
                id: "b2",
                sourceID: "s1",
                sourceName: "喜马拉雅",
                bookURL: "https://example.com/b2",
                title: "凡人修仙传 | 多人有声剧",
                author: "忘语",
                narrator: "大灰狼"
            )
        ]

        let items = SearchViewModel.extractSuggestionKeywords(
            from: books,
            localHistory: ["老凡人笔记", "凡人修仙传", "三体"],
            localBooks: [],
            term: "凡人",
            limit: 8
        )

        XCTAssertEqual(items.first?.text, "凡人修仙传")
        XCTAssertEqual(items.first?.isFromHistory, true)
        XCTAssertEqual(items.dropFirst().first?.text, "老凡人笔记")
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
