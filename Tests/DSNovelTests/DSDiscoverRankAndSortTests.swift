import DSCore
import DSPluginKit
import Foundation
import Testing
@testable import DSNovel

@Suite("DSDiscover 三级榜单分类树与轻量排序测试")
struct DSDiscoverRankAndSortTests {
    @Test("SourceContractAdapter.decodeCategories 支持三层嵌套排行榜菜单且兼容两层菜单")
    func decodeThreeLevelAndTwoLevelCategories() {
        let json = """
        [
          {
            "title": "排行榜",
            "groups": [
              {
                "title": "全站",
                "tabs": [
                  {"title": "热播", "url": "xm-rank:1:100006#1"},
                  {"title": "完结", "url": "xm-rank:1:100271#1"}
                ]
              },
              {
                "title": "小说",
                "tabs": [
                  {"title": "热播", "url": "xm-rank:2:100168#1"}
                ]
              }
            ]
          },
          {
            "title": "有声书",
            "tabs": [
              {"title": "全部", "url": "xm-cat:youshengshu:#1"},
              {"title": "玄幻", "url": "xm-cat:youshengshu:xuanhuan#1"}
            ]
          }
        ]
        """
        let cats = SourceContractAdapter.decodeCategories(json, sourceID: "xmly")
        #expect(cats.count == 5)
        #expect(cats[0].groupTitle == "排行榜")
        #expect(cats[0].subGroupTitle == "全站")
        #expect(cats[0].url == "xm-rank:1:100006#1")
        #expect(cats[3].groupTitle == "有声书")
        #expect(cats[3].subGroupTitle.isEmpty)

        let sections = DiscoverCategoryGrouping.buildSections(from: cats)
        #expect(sections.count == 2)
        #expect(sections[0].title == "排行榜")
        #expect(sections[0].tabs.count == 2)
        #expect(sections[0].tabs[0].shortTitle == "全站")
        #expect(sections[0].tabs[0].subTabs.count == 2)
        #expect(sections[0].tabs[0].subTabs[0].shortTitle == "热播")
        #expect(sections[0].tabs[0].subTabs[1].shortTitle == "完结")

        #expect(sections[1].title == "有声书")
        #expect(sections[1].tabs.count == 2)
        #expect(sections[1].tabs[0].subTabs.isEmpty)
        #expect(sections[1].tabs[1].shortTitle == "玄幻")
    }

    @Test("DiscoverSortHelper 仅对普通分类协议生效并保留页码与题材")
    func sortHelperURLRewriting() {
        #expect(DiscoverSortHelper.supportsSort(url: "xm-cat:youshengshu:xuanhuan#1"))
        #expect(!DiscoverSortHelper.supportsSort(url: "xm-rank:1:100006#1"))
        #expect(!DiscoverSortHelper.supportsSort(url: "https://example.com/list"))

        let hot = DiscoverSortHelper.applyingSort(.hot, to: "xm-cat:youshengshu:xuanhuan#1")
        #expect(hot == "xm-cat:youshengshu:xuanhuan:1#1")

        let latest = DiscoverSortHelper.applyingSort(.latest, to: hot)
        #expect(latest == "xm-cat:youshengshu:xuanhuan:2#1")

        let comp = DiscoverSortHelper.applyingSort(.comprehensive, to: "xm-cat:lishi:#3")
        #expect(comp == "xm-cat:lishi::0#3")

        let rankUntouched = DiscoverSortHelper.applyingSort(.latest, to: "xm-rank:1:100006#1")
        #expect(rankUntouched == "xm-rank:1:100006#1")

        #expect(DiscoverSortHelper.supportsSort(url: "tingyou:cat:category=1#1"))
        #expect(!DiscoverSortHelper.supportsSort(url: "tingyou:rank:hot#1"))
        let tyHot = DiscoverSortHelper.applyingSort(.hot, to: "tingyou:cat:category=1#1")
        #expect(tyHot == "tingyou:cat:category=1&sort=popular#1")
        let tyUpdated = DiscoverSortHelper.applyingSort(.latest, to: tyHot)
        #expect(tyUpdated == "tingyou:cat:category=1&sort=updated#1")
        let tyRankUntouched = DiscoverSortHelper.applyingSort(.latest, to: "tingyou:rank:hot#1")
        #expect(tyRankUntouched == "tingyou:rank:hot#1")
    }

    @Test("BundledSourceSeeder.seedVersionTag 与内置书源包 v5.6.10 同步以触发覆盖升级")
    func bundledSeederVersionMatchesLatestArchive() {
        #expect(BundledSourceSeeder.seedVersionTag == "v5.6.10-v3")
    }
}
