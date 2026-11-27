import DSCore
import Foundation
import Testing
@testable import DSNovel

@Suite("书籍详情跳转全屏播放器与同书详情路由去重测试")
struct DSBookDetailPlayerNavigationTests {
    @Test("presentPlayer 幂等唤起全屏，且从播放器查看同书详情时按 book.id 去重不重复压栈")
    @MainActor
    func presentPlayerAndDeduplicateSameBookDetailPush() {
        let router = AppRouter(initialTab: .discover)

        let listSummary = BookSummaryDTO(
            id: "yuntu::1001",
            sourceID: "yuntu",
            sourceName: "云图有声",
            bookURL: "1001",
            title: "屠龙之辈",
            author: "南山旧藏",
            intro: "简略摘要",
            totalChapters: 0
        )
        let fullSummary = BookSummaryDTO(
            id: "yuntu::1001",
            sourceID: "yuntu",
            sourceName: "云图有声",
            bookURL: "1001",
            title: "屠龙之辈",
            author: "南山旧藏",
            intro: "完整简介内容……",
            totalChapters: 54
        )

        router.push(.bookDetail(listSummary), now: 100)
        #expect(router.discoverPath.count == 1)

        router.presentPlayer()
        #expect(router.isPlayerPresented)
        router.presentPlayer()
        #expect(router.isPlayerPresented)

        // 从全屏播放器点击查看同本书详情：即使 totalChapters/intro 不同，也应按 id 去重不重复压栈
        router.push(.bookDetail(fullSummary), now: 101)
        #expect(!router.isPlayerPresented)
        #expect(router.discoverPath.count == 1)

        // 跳转到另一本书详情则正常压栈
        let otherBook = BookSummaryDTO(
            id: "yuntu::2002",
            sourceID: "yuntu",
            sourceName: "云图有声",
            bookURL: "2002",
            title: "另一本书"
        )
        router.push(.bookDetail(otherBook), now: 102)
        #expect(router.discoverPath.count == 2)
    }
}
