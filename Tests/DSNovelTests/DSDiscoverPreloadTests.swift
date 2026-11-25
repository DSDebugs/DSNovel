@testable import DSNovel
import DSCore
import Foundation
import Testing

@Suite("发现页空分类过滤与 TTL 兜底回归测试")
struct DSDiscoverPreloadTests {
    @Test("24 小时内已确认空分类被过滤，过期后自动恢复，全空时兜底保留原分类")
    func emptyCategoryFilterRespectsTTLAndFallback() {
        let cats = [
            DiscoverCategoryDTO(id: "c1", title: "玄幻", url: "https://example.com/1"),
            DiscoverCategoryDTO(id: "c2", title: "空类", url: "https://example.com/2"),
            DiscoverCategoryDTO(id: "c3", title: "过期空类", url: "https://example.com/3")
        ]
        let now: TimeInterval = 1_700_000_000
        let emptyMap: [String: TimeInterval] = [
            "c2": now - 3600,                    // 1 小时前判空 -> 过滤
            "c3": now - (25 * 60 * 60)           // 25 小时前判空 -> 过期恢复
        ]
        let filtered = DiscoverCategoryEmptyFilter.filter(raw: cats, emptyMap: emptyMap, now: now)
        #expect(filtered.map(\.id) == ["c1", "c3"])

        // 兜底测试：若全部类别都在 24 小时空名单中，绝不返回空数组导致分类栏消失
        let allEmpty: [String: TimeInterval] = [
            "c1": now - 100,
            "c2": now - 100,
            "c3": now - 100
        ]
        let fallback = DiscoverCategoryEmptyFilter.filter(raw: cats, emptyMap: allEmpty, now: now)
        #expect(fallback.count == 3)
    }
}
