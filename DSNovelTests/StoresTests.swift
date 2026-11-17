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
        XCTAssertEqual(store.recentBooks.map(\.id), [], "已在书架的书不应重复出现在最近在听中")

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

    // MARK: - FIX-06 书源互斥五态口径与登录过期测试

    @MainActor
    func testFix06_SourceStoreMutuallyExclusiveClassificationAndAuthLifecycle() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let store = SourceStore()

        // 1. healthy + requiresLogin + unlogged -> needAuth
        let s1 = PluginRecord(id: "s1", packageID: "pkg", name: "带登录未登", version: "1.0", isEnabled: true, requiresLogin: true, loggedIn: false, lastCheckStatus: "healthy")
        // 2. healthy + requiresLogin + loggedIn -> available
        let s2 = PluginRecord(id: "s2", packageID: "pkg", name: "带登录已登", version: "1.0", isEnabled: true, requiresLogin: true, loggedIn: true, lastCheckStatus: "healthy")
        // 3. unavailable + requiresLogin -> unavailable (异常优先于需登录)
        let s3 = PluginRecord(id: "s3", packageID: "pkg", name: "异常优先", version: "1.0", isEnabled: true, requiresLogin: true, loggedIn: false, lastCheckStatus: "unavailable")
        // 4. disabled -> disabled
        let s4 = PluginRecord(id: "s4", packageID: "pkg", name: "已停用源", version: "1.0", isEnabled: false, requiresLogin: true, loggedIn: false, lastCheckStatus: "unavailable")
        // 5. untested + no login -> untested
        let s5 = PluginRecord(id: "s5", packageID: "pkg", name: "未检测源", version: "1.0", isEnabled: true, requiresLogin: false, loggedIn: false, lastCheckStatus: "untested")
        // 6. untested + requiresLogin -> needAuth
        let s6 = PluginRecord(id: "s6", packageID: "pkg", name: "未检带登录", version: "1.0", isEnabled: true, requiresLogin: true, loggedIn: false, lastCheckStatus: "untested")

        for s in [s1, s2, s3, s4, s5, s6] { ctx.insert(s) }
        try ctx.save()
        store.modelContext = ctx

        let sum = store.healthSummary
        XCTAssertEqual(sum.totalCount, 6)
        XCTAssertEqual(sum.availableCount, 1)
        XCTAssertEqual(sum.needAuthCount, 2)
        XCTAssertEqual(sum.unavailableCount, 1)
        XCTAssertEqual(sum.untestedCount, 1)
        XCTAssertEqual(sum.stoppedCount, 1)
        XCTAssertEqual(sum.availableCount + sum.needAuthCount + sum.unavailableCount + sum.untestedCount + sum.stoppedCount, sum.totalCount)

        // 登录成功 -> 移入可用
        store.markLoggedIn(sourceID: "s1")
        XCTAssertEqual(store.healthSummary.availableCount, 2)
        XCTAssertEqual(store.healthSummary.needAuthCount, 1)

        // 登录过期 -> 回到需登录
        store.markAuthExpired(sourceID: "s1")
        XCTAssertEqual(store.healthSummary.availableCount, 1)
        XCTAssertEqual(store.healthSummary.needAuthCount, 2)

        // 筛选后行数 == Chip 计数
        store.filter = .needAuth
        XCTAssertEqual(store.filteredSources.count, store.healthSummary.needAuthCount)
        store.filter = .disabled
        XCTAssertEqual(store.filteredSources.count, store.healthSummary.stoppedCount)
    }

    // MARK: - FIX-05 SearchStore 状态机与 reset() 测试

    @MainActor
    func testFix05_SearchStorePhaseAndReset() {
        let store = SearchStore()
        store.keyword = "诡秘之主"
        let gen = store.searchGeneration
        store.ingestBatchForTesting([BookRef(sourceID: "s1", bookURL: "u1", title: "诡秘之主")], generation: gen)
        XCTAssertEqual(store.mergedItems.count, 1)

        store.reset()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.keyword, "")
        XCTAssertTrue(store.mergedItems.isEmpty)
        XCTAssertEqual(store.totalSourcesCount, 0)

        // reset 后旧代数结果不污染
        store.ingestBatchForTesting([BookRef(sourceID: "s1", bookURL: "u2", title: "旧结果")], generation: gen)
        XCTAssertTrue(store.mergedItems.isEmpty)
    }

    @MainActor
    func testDiscoverStoreTwoCharBadgeAndScopedSearch() async {
        XCTAssertEqual(DiscoverStore.twoCharBadge(for: "喜马拉雅"), "喜马")
        XCTAssertEqual(DiscoverStore.twoCharBadge(for: " 博看有声 "), "博看")
        XCTAssertEqual(DiscoverStore.twoCharBadge(for: ""), "源")

        let store = DiscoverStore()
        store.resetForTesting()
        store.currentSourceID = "src_xm"
        store.customSourceSearchLoader = { sid, kw in
            [BookRef(sourceID: sid, bookURL: "u/1", title: "\(kw) 结果")]
        }
        store.submitSourceSearch(keyword: "凡人修仙传")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.isSearchActive)
        XCTAssertEqual(store.searchResults.count, 1)
        XCTAssertEqual(store.searchResults.first?.sourceID, "src_xm")

        store.clearSourceSearch()
        XCTAssertFalse(store.isSearchActive)
        XCTAssertTrue(store.searchResults.isEmpty)
        XCTAssertEqual(store.searchKeyword, "")
    }

    @MainActor
    func testSourceStoreGroupingMoveAndReorder() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let store = SourceStore()

        let g1 = PluginGroup(id: "g1", name: "常用有声", order: 0)
        let g2 = PluginGroup(id: "g2", name: "备用书源", order: 1)
        let p1 = PluginRecord(id: "p1", packageID: "pkg", name: "喜马拉雅", version: "1.0", groupID: "g1", order: 0)
        let p2 = PluginRecord(id: "p2", packageID: "pkg", name: "番茄畅听", version: "1.0", groupID: "g1", order: 1)
        let p3 = PluginRecord(id: "p3", packageID: "pkg", name: "听书网", version: "1.0", groupID: nil, order: 0)
        ctx.insert(g1)
        ctx.insert(g2)
        ctx.insert(p1)
        ctx.insert(p2)
        ctx.insert(p3)
        try ctx.save()

        store.modelContext = ctx
        store.refreshNow()

        let sections = store.groupedSections(from: store.filteredSources, includeEmptyGroups: true)
        XCTAssertEqual(sections.map(\.title), ["常用有声", "备用书源", "未分组"])
        XCTAssertEqual(sections[0].sources.map(\.id), ["p1", "p2"])
        XCTAssertEqual(sections[1].sources.count, 0)
        XCTAssertEqual(sections[2].sources.map(\.id), ["p3"])

        store.moveSources(["p3"], toGroupID: "g2")
        let afterMove = store.groupedSections(from: store.filteredSources, includeEmptyGroups: false)
        XCTAssertEqual(afterMove.map(\.title), ["常用有声", "备用书源"])
        XCTAssertEqual(afterMove[1].sources.map(\.id), ["p3"])

        store.reorderSources(inGroupID: "g1", from: IndexSet(integer: 1), to: 0)
        let afterReorder = store.groupedSections(from: store.filteredSources, includeEmptyGroups: false)
        XCTAssertEqual(afterReorder[0].sources.map(\.id), ["p2", "p1"])
    }

    @MainActor
    func testSearchStoreLoadHotBooksIfNeeded() async {
        let searchStore = SearchStore()
        searchStore.customHotBooksLoader = { sourceID in
            [
                BookRef(sourceID: sourceID, bookURL: "https://e.com/b1", title: "大奉打更人", author: "头陀渊讲故事"),
                BookRef(sourceID: sourceID, bookURL: "https://e.com/b2", title: "蛊真人", author: "老宝玉_白玉京")
            ]
        }
        let s1 = PluginRecord(id: "xmly", packageID: "pkg", name: "喜马拉雅", version: "1.0", isEnabled: true, discoverable: true)
        await searchStore.loadHotBooksIfNeeded(sources: [s1], forceReload: true)
        XCTAssertEqual(searchStore.hotBooks.count, 2)
        XCTAssertEqual(searchStore.hotBooksSourceName, "喜马拉雅")
        XCTAssertEqual(searchStore.hotBooks[0].author, "头陀渊讲故事")
    }
}
