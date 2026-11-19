import XCTest
import SwiftData
@testable import DSNovel

final class ComprehensiveTaskCardTests: XCTestCase {
    func testT1_01_SpacingTokensMatch4ptGrid() {
        XCTAssertEqual(Spacing.s1, 4)
        XCTAssertEqual(Spacing.s2, 8)
        XCTAssertEqual(Spacing.s3, 12)
        XCTAssertEqual(Spacing.s4, 16)
        XCTAssertEqual(Spacing.s5, 20)
        XCTAssertEqual(Spacing.s6, 24)
        XCTAssertEqual(Spacing.s7, 32)
        XCTAssertEqual(Spacing.s8, 48)
    }

    func testT1_01_RadiusTokensMatchSpec() {
        XCTAssertEqual(Radius.cover(forSide: 96), 8)
        XCTAssertEqual(Radius.cover(forSide: 100), 12)
        XCTAssertEqual(Radius.cover(forSide: 128), 12)
        XCTAssertEqual(Radius.heroCard, 24)
        XCTAssertEqual(Radius.card, 16)
        XCTAssertEqual(Radius.input, 14)
    }

    func testT1_04_CoverPlaceholder6WarmPalettesAndFirstChar() {
        XCTAssertEqual(CoverPlaceholder.palettes.count, 6)
        XCTAssertEqual(CoverPlaceholder.firstCharacter(for: "  诡秘之主 "), "诡")
        XCTAssertEqual(CoverPlaceholder.firstCharacter(for: ""), "书")
        for title in ["道德经", "茶花女", "全唐诗", "人间失格", "水浒传", "孙子兵法"] {
            let idx = CoverPlaceholder.paletteIndex(for: title)
            XCTAssertTrue((0..<6).contains(idx))
        }
    }

    func testT1_05_BookCardModelAccessibilitySummary() {
        let m1 = BookCardModel(id: "1", title: "诡秘之主", author: "爱潜水的乌贼", lastChapterIndex: 12)
        XCTAssertEqual(m1.accessibilitySummary, "诡秘之主，爱潜水的乌贼，已听到第 12 章")
        let m2 = BookCardModel(id: "2", title: "道德经", author: "", lastChapterIndex: 0)
        XCTAssertEqual(m2.accessibilitySummary, "道德经，未知作者")
    }

    func testT1_06_ChipItemEquality() {
        let a = DSChipItem(id: "all", title: "全部", count: 5)
        let b = DSChipItem(id: "all", title: "全部", count: 5)
        XCTAssertEqual(a, b)
    }

    func testT1_07_StateKindTitlesAndButtonsMatchSection2_5() {
        XCTAssertEqual(DSStateKind.empty.title, "该分类暂无内容")
        XCTAssertEqual(DSStateKind.empty.primaryButtonTitle, "切换书源")
        XCTAssertEqual(DSStateKind.empty.secondaryButtonTitle, "刷新")
        XCTAssertEqual(DSStateKind.error().title, "加载失败")
        XCTAssertEqual(DSStateKind.error().primaryButtonTitle, "重试")
        XCTAssertEqual(DSStateKind.error().secondaryButtonTitle, "切换书源")
        XCTAssertEqual(DSStateKind.needLogin(sourceName: "喜马拉雅").title, "「喜马拉雅」需要登录")
        XCTAssertEqual(DSStateKind.needVerify.title, "需要完成安全验证")
        XCTAssertEqual(DSStateKind.vipChapter.title, "此章节需要会员或内置解析")
        XCTAssertEqual(DSStateKind.offline.title, "当前没有网络")
        XCTAssertEqual(DSStateKind.noSource.primaryButtonTitle, "导入书源")
    }

    func testT1_07_UserFacingErrorMappingsAllBranches() {
        XCTAssertEqual(UserFacingError.from(PluginError.timeout), .error(detail: "请求超时 (timeout)"))
        XCTAssertEqual(UserFacingError.from(PluginError.network("offline network")), .offline)
        XCTAssertEqual(UserFacingError.from(PluginError.parseFailed("bad json")), .error(detail: "bad json"))
        XCTAssertEqual(UserFacingError.from(PluginError.builtinParserMissing(sourceID: "s1")), .vipChapter)
        XCTAssertEqual(UserFacingError.from(PluginError.builtinParserFailed(sourceID: "s1", reason: "err")), .vipChapter)
        XCTAssertEqual(UserFacingError.from(URLError(.timedOut)), .error(detail: "连接超时 (URLError.timedOut)"))
    }

    @MainActor
    func testT1_08_BannerCenterDeduplicationWithin3Seconds() {
        let center = BannerCenter.shared
        center.resetForTesting()
        center.show("已复制", kind: .info, now: 10.0, scheduleAutoDismiss: false)
        let firstID = center.currentBanner?.id
        center.show("已复制", kind: .info, now: 11.5, scheduleAutoDismiss: false)
        XCTAssertEqual(center.currentBanner?.id, firstID, "3 秒内同内容横幅应去重")
        center.show("已复制", kind: .info, now: 13.5, scheduleAutoDismiss: false)
        XCTAssertNotEqual(center.currentBanner?.id, firstID, "超过 3 秒后允许再次展示")
        center.resetForTesting()
    }

    func testT1_09_DSEqualizerRespectsReduceMotionAndPause() {
        XCTAssertTrue(DSEqualizer.shouldAnimate(isPlaying: true, reduceMotion: false))
        XCTAssertFalse(DSEqualizer.shouldAnimate(isPlaying: false, reduceMotion: false))
        XCTAssertFalse(DSEqualizer.shouldAnimate(isPlaying: true, reduceMotion: true))
    }

    func testT1_09_DSSourceHealthKindIconsAndColors() {
        XCTAssertEqual(DSSourceHealthKind.healthy.iconName, "checkmark.circle.fill")
        XCTAssertEqual(DSSourceHealthKind.slow.iconName, "tortoise.fill")
        XCTAssertEqual(DSSourceHealthKind.needAuth.iconName, "person.badge.key")
        XCTAssertEqual(DSSourceHealthKind.unavailable.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(DSSourceHealthKind.untested.iconName, "circle.dashed")
    }

    @MainActor
    func testT2_02_ScrollToTopCenterIncrementsPerTab() {
        let center = ScrollToTopCenter()
        XCTAssertEqual(center.count(for: .library), 0)
        center.requestScrollToTop(in: .library)
        center.requestScrollToTop(in: .library)
        XCTAssertEqual(center.count(for: .library), 2)
        XCTAssertEqual(center.count(for: .discover), 0)
    }

    func testT2_01_TargetTabResolutionForAllRoutes() {
        let ref = BookRef(sourceID: "s", bookURL: "u", title: "t")
        XCTAssertEqual(AppRouter.targetTab(for: .book(ref), currentTab: .discover), .discover)
        XCTAssertEqual(AppRouter.targetTab(for: .history, currentTab: .discover), .library)
        XCTAssertEqual(AppRouter.targetTab(for: .downloads, currentTab: .library), .me)
        XCTAssertEqual(AppRouter.targetTab(for: .sourceList, currentTab: .library), .me)
        XCTAssertEqual(AppRouter.targetTab(for: .sourceDetail(id: "s1", focus: .builtinParser), currentTab: .search), .me)
        XCTAssertEqual(AppRouter.targetTab(for: .sourceImport, currentTab: .discover), .me)
    }

    func testT3_01_BookSnapshotSortPerformance500Items() {
        let items: [BookSnapshot] = (0..<500).map { i in
            BookSnapshot(
                id: "s::\(i)",
                sourceID: "s",
                bookURL: "u/\(i)",
                title: "书籍 \(500 - i)",
                author: "作者",
                cover: "",
                intro: "",
                inShelf: true,
                addedAt: Date(timeIntervalSince1970: Double(i * 60)),
                categoryID: nil,
                lastChapterID: "c1",
                lastChapterTitle: "第 1 章",
                lastChapterIndex: 1,
                totalChapters: 100,
                lastPositionMs: 1000,
                lastPlayedAt: Date(timeIntervalSince1970: Double(i * 120)),
                isPinned: i % 50 == 0,
                hasUpdate: i % 10 == 0,
                latestChapterCount: 100,
                updateCheckedAt: nil
            )
        }
        let sorted = LibraryStore.sortSnapshots(items, by: .lastPlayed)
        XCTAssertEqual(sorted.count, 500)
        XCTAssertTrue(sorted.first?.isPinned == true)
    }

    func testT3_03_BookEpisodeAndTimeProgressUsesZhangTerminology() {
        let b = Book(
            id: "s::1",
            sourceID: "s",
            bookURL: "1",
            title: "测试术语",
            lastChapterIndex: 12,
            totalChapters: 100,
            lastPositionMs: 65_000
        )
        XCTAssertEqual(b.episodeAndTimeProgressText, "第 12/100 章 · 01:05")
        XCTAssertFalse(b.episodeAndTimeProgressText.contains("集"))
    }

    func testT3_03_BookRefDiscoverSubtitleUsesZhangTerminology() {
        let ref = BookRef(sourceID: "s", bookURL: "1", title: "测试", chapterCount: 88)
        XCTAssertEqual(ref.discoverSubtitle, "共 88 章")
    }

    @MainActor
    func testT3_04_DownloadSummary1000StepRandomizedConsistency() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let manager = DownloadManager(transport: FakeDownloadTransport())
        manager.modelContext = ctx

        var rng: UInt64 = 0x123456789ABCDEF0
        func nextRand() -> UInt64 {
            rng = rng &* 6364136223846793005 &+ 1
            return rng
        }

        let bookIDs = ["b1", "b2", "b3", "b4", "b5"]
        var existing: [String: DownloadItem] = [:]

        for step in 0..<1000 {
            let bid = bookIDs[Int(nextRand() % UInt64(bookIDs.count))]
            let cid = "ch_\(nextRand() % 20)"
            let id = "\(bid)::\(cid)"
            let op = nextRand() % 3
            if op == 0 {
                if existing[id] == nil {
                    let item = DownloadItem(
                        id: id,
                        bookID: bid,
                        bookTitle: "书_\(bid)",
                        chapterID: cid,
                        chapterTitle: cid,
                        sourceID: "s",
                        kind: "manual",
                        state: "queued",
                        bytes: 0
                    )
                    ctx.insert(item)
                    existing[id] = item
                }
            } else if op == 1 {
                if let item = existing[id] {
                    item.state = "completed"
                    item.bytes = Int64((step + 1) * 1024)
                }
            } else {
                if let item = existing.removeValue(forKey: id) {
                    ctx.delete(item)
                }
            }
        }
        try ctx.save()
        manager.rebuildSummariesFromContext()

        for bid in bookIDs {
            let expectedItems = existing.values.filter { $0.bookID == bid && $0.kind == "manual" }
            let expectedCompleted = expectedItems.filter { $0.state == "completed" }
            let expectedBytes = expectedCompleted.reduce(Int64(0)) { $0 + $1.bytes }
            let summary = manager.summariesByBookID[bid]
            XCTAssertEqual(summary?.totalCount ?? 0, expectedItems.count)
            XCTAssertEqual(summary?.completedCount ?? 0, expectedCompleted.count)
            XCTAssertEqual(summary?.totalBytes ?? 0, expectedBytes)
        }
    }

    @MainActor
    func testT4_6c_AuthCoordinatorPubSubAndAutoReload() {
        let coord = AuthCoordinator.shared
        var notifiedSourceID: String?
        let token = coord.subscribe { sid in
            notifiedSourceID = sid
        }
        defer { coord.unsubscribe(token) }

        coord.presentLogin(forSourceID: "test_auth_src")
        XCTAssertNotNil(coord.activeAuthRequest)
        coord.notifyLoginCompleted(sourceID: "test_auth_src")
        XCTAssertNil(coord.activeAuthRequest)
        XCTAssertEqual(notifiedSourceID, "test_auth_src")
    }

    func testT4_3_CleanHTMLStripsTagsAndEntities() {
        let raw = "<p>第一段&nbsp;内容</p><br/><div>第二段&quot;引用&quot;</div>"
        let cleaned = BookDetailModel.cleanHTML(raw)
        XCTAssertFalse(cleaned.contains("<p>"))
        XCTAssertTrue(cleaned.contains("第一段 内容"))
        XCTAssertTrue(cleaned.contains("第二段\"引用\""))
    }

    func testT4_5_NextChapterAvailabilityStates() {
        let player = PlayerEngine.shared
        let book = BookRef(sourceID: "s", bookURL: "b", title: "测试")
        let ch1 = ChapterDTO(index: 0, title: "第 1 章", url: "u1")
        let ch2 = ChapterDTO(index: 1, title: "第 2 章", url: "u2")
        player.prepare(book: book, chapters: [ch1, ch2], chapter: ch1, positionMs: 0)
        XCTAssertEqual(player.nextChapterAvailability, .availableOnline(ch2))
        player.prepare(book: book, chapters: [ch1, ch2], chapter: ch2, positionMs: 0)
        XCTAssertEqual(player.nextChapterAvailability, .none)
    }

    func testT4_5_SleepTimerOptionsLabelsUseZhang() {
        XCTAssertEqual(SleepTimerOption.off.label, "定时关闭")
        XCTAssertEqual(SleepTimerOption.minutes(30).label, "30 分钟")
        XCTAssertEqual(SleepTimerOption.endOfChapter.label, "本章结束")
        XCTAssertEqual(SleepTimerOption.chaptersRemaining(2).label, "2 章后")
        XCTAssertEqual(SleepTimerOption.chaptersRemaining(5).label, "5 章后")
    }

    func testT3_06_DownloadTaskDescriptorCodableRoundTrip() throws {
        let desc = DownloadTaskDescriptor(
            itemID: "b1::c1",
            bookID: "b1",
            chapterID: "c1",
            resolvedBy: BuiltinParserRuntime.resolverTag
        )
        let data = try JSONEncoder().encode(desc)
        let decoded = try JSONDecoder().decode(DownloadTaskDescriptor.self, from: data)
        XCTAssertEqual(decoded, desc)
    }

    func testT3_01_SearchScopeSelectionTitles() {
        XCTAssertEqual(SearchScopeSelection.all.title, "全部书源")
        XCTAssertEqual(SearchScopeSelection.currentDiscover.title, "当前发现书源")
        XCTAssertEqual(SearchScopeSelection.group("小说").title, "小说")
        XCTAssertEqual(SearchScopeSelection.custom(["a", "b"]).title, "自定义(2)")
    }

    func testT3_01_SourceListFilterTitles() {
        XCTAssertEqual(SourceListFilter.all.title, "全部")
        XCTAssertEqual(SourceListFilter.available.title, "可用")
        XCTAssertEqual(SourceListFilter.needAuth.title, "需登录")
        XCTAssertEqual(SourceListFilter.unavailable.title, "异常")
    }

    func testT3_01_LibraryFilterTitles() {
        XCTAssertEqual(LibraryFilter.all.title, "全部")
        XCTAssertEqual(LibraryFilter.inProgress.title, "在追")
        XCTAssertEqual(LibraryFilter.downloaded.title, "已下载")
        XCTAssertEqual(LibraryFilter.updated.title, "有更新")
    }

    func testT2_02_ShellTabTitlesAndIcons() {
        XCTAssertEqual(ShellTab.library.title, "书籍")
        XCTAssertEqual(ShellTab.allCases, [.discover, .search, .library, .me])
        XCTAssertEqual(ShellTab.discover.title, "发现")
        XCTAssertEqual(ShellTab.me.title, "我的")
        XCTAssertEqual(ShellTab.search.title, "搜索")
        XCTAssertEqual(ShellTab.library.icon, "books.vertical")
        XCTAssertEqual(ShellTab.discover.icon, "safari")
        XCTAssertEqual(ShellTab.me.icon, "person.crop.circle")
    }

    func testT4_6c_DownloadsDataHelperPartitioning() {
        let i1 = DownloadItem(id: "1", bookID: "b1", bookTitle: "B1", chapterID: "c1", chapterTitle: "C1", sourceID: "s", state: "downloading")
        let i2 = DownloadItem(id: "2", bookID: "b1", bookTitle: "B1", chapterID: "c2", chapterTitle: "C2", sourceID: "s", state: "failed")
        let i3 = DownloadItem(id: "3", bookID: "b1", bookTitle: "B1", chapterID: "c3", chapterTitle: "C3", sourceID: "s", state: "completed")
        let part = DownloadsDataHelper.partitionItems([i1, i2, i3])
        XCTAssertEqual(part.active.count, 1)
        XCTAssertEqual(part.failed.count, 1)
        XCTAssertEqual(DownloadsDataHelper.itemsForBook("b1", from: [i1, i2, i3]).count, 1)
    }
}
