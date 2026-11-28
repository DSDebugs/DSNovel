import DSCore
import DSStorage
import Foundation
import Testing
@testable import DSNovel

@Suite("首页一二三级分类按书源持久化与恢复测试")
struct DSDiscoverCategoryPersistenceTests {
    @Test("多书源分别记住上次选中的分类，恢复时自动反推一二三级下标，下线分类安全回退")
    @MainActor
    func perSourceCategoryPersistenceAndHierarchyRestore() throws {
        let suite = "ds_discover_cat_persist_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettingsStore(defaults: defaults)
        let cats: [DiscoverCategoryDTO] = [
            DiscoverCategoryDTO(id: "rank:hot", title: "热播", url: "xm-rank:0:hot", groupTitle: "排行榜", subGroupTitle: "全站"),
            DiscoverCategoryDTO(id: "rank:xuanyi:hot", title: "热播", url: "xm-rank:45:hot", groupTitle: "排行榜", subGroupTitle: "悬疑"),
            DiscoverCategoryDTO(id: "rank:xuanyi:done", title: "完结", url: "xm-rank:45:done", groupTitle: "排行榜", subGroupTitle: "悬疑"),
            DiscoverCategoryDTO(id: "cat:novel", title: "小说", url: "xm-cat:novel", groupTitle: "分类")
        ]

        // 模拟用户在喜马拉雅选中了「排行榜 -> 悬疑 -> 完结」，在云图选中了另一分类
        settings.setLastDiscoverCategoryID("rank:xuanyi:done", forSourceID: "xmly")
        settings.setLastDiscoverCategoryID("yuntu:142", forSourceID: "yuntu")

        // 模拟重启 App 后重新读取 UserDefaults
        let reloaded = AppSettingsStore(defaults: defaults)
        #expect(reloaded.lastDiscoverCategoryID(forSourceID: "xmly") == "rank:xuanyi:done")
        #expect(reloaded.lastDiscoverCategoryID(forSourceID: "yuntu") == "yuntu:142")

        let vm = DiscoverViewModel()
        vm.selectedSourceID = "xmly"
        let restored = vm.resolveInitialCategory(from: cats, settings: reloaded)
        #expect(restored?.id == "rank:xuanyi:done")

        vm.selectedCategoryID = restored?.id ?? ""
        vm.categories = cats
        #expect(vm.selectedSectionIndex == 0)
        #expect(vm.selectedTabIndex == 1)
        #expect(vm.selectedSubTabIndex == 1)

        // 若上次记忆的分类已从书源下线，应安全回退至第一个分类
        reloaded.setLastDiscoverCategoryID("removed:cat", forSourceID: "xmly")
        let fallback = vm.resolveInitialCategory(from: cats, settings: reloaded)
        #expect(fallback?.id == "rank:hot")
    }
}
