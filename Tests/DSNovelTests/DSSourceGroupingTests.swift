import DSCore
import DSStorage
import Foundation
import Testing
@testable import DSNovel

@Suite("DSSourceGrouping 书源分组增删改、单源换组与精炼简介测试")
struct DSSourceGroupingTests {
    private func makeSource(id: String, name: String, group: String = "默认分组", order: Int = 0) -> SourceMetaDTO {
        SourceMetaDTO(
            id: id,
            name: name,
            version: "5.6.9",
            summary: "推荐指数:5星 ⭐⭐⭐⭐⭐\n这是一段冗长的旧版描述",
            methods: ["search", "discover"],
            isEnabled: true,
            isPinned: false,
            groupName: group,
            sortOrder: order
        )
    }

    @Test("SourceOrganizeModel 支持新建空分组、重命名与安全删除回退默认分组")
    @MainActor
    func groupCreateRenameDeleteLifecycle() {
        let model = SourceOrganizeModel()
        let s1 = makeSource(id: "s1", name: "喜马拉雅", group: "主力听书", order: 0)
        let s2 = makeSource(id: "s2", name: "博看有声", group: "精品有声", order: 1)
        model.load(from: [s1, s2], customGroups: [])

        #expect(model.groupNames == ["主力听书", "精品有声", "默认分组"])
        #expect(model.createGroup("睡前常听"))
        #expect(model.groupNames.contains("睡前常听"))
        #expect(model.count(inGroup: "睡前常听") == 0)

        // 单个书源直接换组
        model.assignSource(id: "s2", toGroup: "睡前常听")
        #expect(model.count(inGroup: "睡前常听") == 1)
        #expect(model.count(inGroup: "精品有声") == 0)

        // 重命名分组同步更新组内书源
        #expect(model.renameGroup(from: "睡前常听", to: "助眠精选"))
        #expect(model.groupNames.contains("助眠精选"))
        #expect(!model.groupNames.contains("睡前常听"))
        #expect(model.allSources.first(where: { $0.id == "s2" })?.groupName == "助眠精选")

        // 删除分组：书源不丢失，安全归回默认分组
        #expect(model.deleteGroup("助眠精选"))
        #expect(!model.groupNames.contains("助眠精选"))
        #expect(model.allSources.first(where: { $0.id == "s2" })?.groupName == "默认分组")

        // 系统默认分组不可删除与重命名
        #expect(!model.deleteGroup("默认分组"))
        #expect(!model.renameGroup(from: "默认分组", to: "其他"))
    }

    @Test("SourceListHelper.conciseSummary 精简内置与第三方书源简介")
    func conciseSummaryFiltering() {
        let xm = makeSource(id: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", name: "喜马拉雅")
        #expect(SourceListHelper.conciseSummary(for: xm) == "全品类主力源 · 免费直听，登录畅听 VIP")

        let custom = makeSource(id: "custom-1", name: "自定义源")
        #expect(SourceListHelper.conciseSummary(for: custom) == "这是一段冗长的旧版描述")
    }
}
