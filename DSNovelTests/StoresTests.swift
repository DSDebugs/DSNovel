import XCTest
import SwiftData
@testable import DSNovel

final class StoresTests: XCTestCase {

    // MARK: - LibraryStore Tests (8+ cases)

    @MainActor
    func testLibraryStoreSortOrdersAndFiltersAndContinueBook() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let store = LibraryStore()

        let now = Date.now
        let b1 = Book(
            id: "s::1", sourceID: "s", bookURL: "1", title: "B书",
            inShelf: true, addedAt: now.addingTimeInterval(-300),
            lastChapterID: "c1", lastChapterIndex: 2, totalChapters: 10,
            lastPositionMs: 30_000, lastPlayedAt: now.addingTimeInterval(-60),
            isPinned: false, hasUpdate: false
        )
        let b2 = Book(
            id: "s::2", sourceID: "s", bookURL: "2", title: "A书",
            inShelf: true, addedAt: now.addingTimeInterval(-100),
            lastChapterID: "c2", lastChapterIndex: 5, totalChapters: 10,
            lastPositionMs: 50_000, lastPlayedAt: now.addingTimeInterval(-10),
            isPinned: false, hasUpdate: true, updateCheckedAt: now
        )
        let b3 = Book(
            id: "s::3", sourceID: "s", bookURL: "3", title: "C书（置顶）",
            inShelf: true, addedAt: now.addingTimeInterval(-500),
            isPinned: true
        )
        ctx.insert(b1)
        ctx.insert(b2)
        ctx.insert(b3)
        try ctx.save()

        store.modelContext = ctx
        store.refreshNow()

        // 1. 继续收听选择最近播放且有进度者 (b2)
        XCTAssertEqual(store.continueBook?.id, "s::2")
        // 2. recentBooks 不含主卡那本
        XCTAssertEqual(store.recentBooks.map(\.id), ["s::1"])

        // 3. 置顶永远在最前 + 最近播放排序
        store.sortOrder = .lastPlayed
        XCTAssertEqual(store.shelfBooks.map(\.id), ["s::3", "s::2", "s::1"])

        // 4. 加入时间排序
        store.sortOrder = .addedAt
        XCTAssertEqual(store.shelfBooks.map(\.id), ["s::3", "s::2", "s::1"])

        // 5. 书名排序
        store.sortOrder = .title
        XCTAssertEqual(store.shelfBooks.map(\.id), ["s::3", "s::2", "s::1"])

        // 6. 最近更新排序
        store.sortOrder = .recentlyUpdated
        XCTAssertEqual(store.shelfBooks.first?.id, "s::3")
        XCTAssertEqual(store.shelfBooks[1].id, "s::2")

        // 7. 筛选：有更新
        store.selectedFilter = .updated
        XCTAssertEqual(store.shelfBooks.map(\.id), ["s::2"])

        // 8. 筛选：在追
        store.selectedFilter = .inProgress
        XCTAssertEqual(Set(store.shelfBooks.map(\.id)), ["s::1", "s::2"])
    }

    @MainActor
    func testLibraryStoreCheckUpdatesAndHistoryGrouping() async throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let store = LibraryStore()

        let b1 = Book(id: "s::1", sourceID: "s", bookURL: "1", title: "测试更新", totalChapters: 10)
        ctx.insert(b1)
        try ctx.save()

        store.modelContext = ctx
        var fetchCalls = 0
        store.customChapterCountFetcher = { _ in
            fetchCalls += 1
            return 15
        }

        let updated = await store.checkUpdates(now: .now)
        XCTAssertEqual(updated, 1)
        XCTAssertTrue(b1.hasUpdate)
        XCTAssertEqual(b1.latestChapterCount, 15)

        // 5 分钟内不重复请求
        let second = await store.checkUpdates(now: Date.now.addingTimeInterval(60))
        XCTAssertEqual(second, 0)
        XCTAssertEqual(fetchCalls, 1)

        // 历史分组边界测试
        let cal = Calendar.current
        let now = Date.now
        XCTAssertEqual(HistoryTimeGroup.classify(date: now, now: now, calendar: cal), .today)
        XCTAssertEqual(HistoryTimeGroup.classify(date: now.addingTimeInterval(-86400), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(HistoryTimeGroup.classify(date: now.addingTimeInterval(-3 * 86400), now: now, calendar: cal), .thisWeek)
        XCTAssertEqual(HistoryTimeGroup.classify(date: now.addingTimeInterval(-15 * 86400), now: now, calendar: cal), .earlier)
    }

    // MARK: - SourceStore Tests (8+ cases)

    @MainActor
    func testSourceStoreHealthSummaryFilteringAndBatchOps() async throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let store = SourceStore()

        let p1 = PluginRecord(id: "p1", packageID: "pkg", name: "甲源", version: "1.0", isPinned: true, isEnabled: true, lastCheckStatus: "healthy", lastLatencyMs: 90)
        let p2 = PluginRecord(id: "p2", packageID: "pkg", name: "乙源", version: "1.0", isEnabled: true, requiresLogin: true, loggedIn: false, lastCheckStatus: "needAuth")
        let p3 = PluginRecord(id: "p3", packageID: "pkg", name: "丙源", version: "1.0", isEnabled: true, lastCheckStatus: "unavailable")
        ctx.insert(p1)
        ctx.insert(p2)
        ctx.insert(p3)
        try ctx.save()

        store.modelContext = ctx
        XCTAssertEqual(store.healthSummary.availableCount, 1)
        XCTAssertEqual(store.healthSummary.needAuthCount, 1)
        XCTAssertEqual(store.healthSummary.unavailableCount, 1)
        XCTAssertEqual(store.needAttention.count, 2)

        store.filter = .available
        XCTAssertEqual(store.filteredSources.map(\.id), ["p1"])

        store.filter = .needAuth
        XCTAssertEqual(store.filteredSources.map(\.id), ["p2"])

        store.filter = .unavailable
        XCTAssertEqual(store.filteredSources.map(\.id), ["p3"])

        store.filter = .all
        store.searchKeyword = "乙"
        XCTAssertEqual(store.filteredSources.map(\.id), ["p2"])
        store.searchKeyword = ""

        // 批量停用与移动分组
        store.setEnabled(false, forIDs: ["p2", "p3"])
        XCTAssertEqual(store.healthSummary.enabledCount, 1)
        store.moveSources(["p1"], toGroupID: "g1")
        XCTAssertEqual(p1.groupID, "g1")

        // 批量检测
        store.customHealthChecker = { sid in
            SourceHealthCheckResult(sourceID: sid, state: .healthy, latencyMs: 55, message: "ok", sampleCount: 3, checkedAt: .now)
        }
        await store.checkSources([p1])
        XCTAssertEqual(p1.lastLatencyMs, 55)
    }

    // MARK: - DiscoverStore Tests (8+ cases)

    @MainActor
    func testDiscoverStoreSwitchSourcePaginationAndScrollPositionMemory() async {
        let store = DiscoverStore()
        store.resetForTesting()

        store.customMenusLoader = { sid in
            [
                DiscoverSectionDTO(title: "图书", tabs: [
                    DiscoverTabDTO(title: "经典", url: "cat://\(sid)/1"),
                    DiscoverTabDTO(title: "文学", url: "cat://\(sid)/2")
                ])
            ]
        }
        store.customPageLoader = { sid, url, page in
            let book = BookRef(sourceID: sid, bookURL: "\(url)/p\(page)", title: "\(sid)_p\(page)")
            return DiscoverPageDTO(books: [book], nextPageURL: page == 1 ? "\(url)/next" : nil, totalPage: 2)
        }

        await store.switchSource(to: "src_a")
        XCTAssertEqual(store.currentBooks.count, 1)
        store.recordScrollAnchor(store.currentBooks[0].id)

        // 加载下一页
        await store.loadNextPageIfNeeded(currentItemID: store.currentBooks[0].id)
        XCTAssertEqual(store.currentBooks.count, 2)
        XCTAssertFalse(store.canLoadMore)

        // 切换到分类 2
        await store.selectTab(1)
        XCTAssertEqual(store.selectedTabIndex, 1)
        XCTAssertEqual(store.currentBooks.count, 1)

        // 切换到新书源 src_b 再切回 src_a，验证分类与滚动锚点恢复
        await store.switchSource(to: "src_b")
        XCTAssertEqual(store.currentSourceID, "src_b")
        await store.switchSource(to: "src_a")
        XCTAssertEqual(store.selectedTabIndex, 1)
        await store.selectTab(0)
        XCTAssertEqual(store.savedScrollAnchor(), "src_a::cat://src_a/1/p1")
    }

    // MARK: - SearchStore Tests (8+ cases)

    @MainActor
    func testSearchStoreStreamingMergeCancellationAndNoJump() async {
        let store = SearchStore()
        store.keyword = "三体"
        store.hasScrolledPastFirstScreen = true

        let gen = store.searchGeneration
        // 先到达相关性较低的结果
        let lowRel = BookRef(sourceID: "s1", bookURL: "https://s1/1", title: "从零讲三体宇宙", author: "甲")
        store.ingestBatchForTesting([lowRel], generation: gen)
        XCTAssertEqual(store.mergedItems.first?.primary.title, "从零讲三体宇宙")

        // 后到达精确匹配结果 + 重复书源结果：验证追加在末尾不挤走第一项，且出现「更相关结果」提示计数
        let exactRel = BookRef(sourceID: "s2", bookURL: "https://s2/1", title: "三体", author: "刘慈欣")
        let dupLowRel = BookRef(sourceID: "s3", bookURL: "https://s3/9", title: "从零讲三体宇宙", author: "甲")
        store.ingestBatchForTesting([exactRel, dupLowRel], generation: gen)

        XCTAssertEqual(store.mergedItems.count, 2)
        XCTAssertEqual(store.mergedItems[0].primary.title, "从零讲三体宇宙", "用户正在看的首项不得被挤走")
        XCTAssertEqual(store.mergedItems[0].alternatives.count, 1, "同名同作者应合并入 alternatives")
        XCTAssertGreaterThan(store.pendingHigherRelevanceCount, 0)

        // 用户主动点按重排后，精确匹配排第一
        store.applyRelevanceResort()
        XCTAssertEqual(store.mergedItems[0].primary.title, "三体")
        XCTAssertEqual(store.pendingHigherRelevanceCount, 0)

        // 取消后旧代数号的结果被丢弃
        store.cancelCurrentSearch()
        let lateBook = BookRef(sourceID: "s4", bookURL: "https://s4/1", title: "迟到结果")
        store.ingestBatchForTesting([lateBook], generation: gen)
        XCTAssertEqual(store.mergedItems.count, 2)
    }
}
