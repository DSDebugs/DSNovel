import DSCore
import DSPluginKit
import Foundation
import Testing
@testable import DSNovel

@Suite("DSBookDetail 主播名去重、占位词过滤与书名格式化测试")
struct DSBookDetailFormatterTests {
    @Test("narratorDisplay 自动对作者与主播重复或包含关系去重，并过滤佚名等占位词")
    func narratorDeduplicationAndPlaceholderSanitization() {
        #expect(BookTitleFormatter.narratorDisplay(author: "趣阅有声", narrator: "趣阅有声") == "趣阅有声 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: " 趣阅有声 ", narrator: "趣阅有声") == "趣阅有声 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "头陀渊", narrator: "头陀渊讲故事") == "头陀渊讲故事 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "老宝玉播讲", narrator: "老宝玉") == "老宝玉播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "当年明月", narrator: "王更新") == "当年明月 · 王更新 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "", narrator: "紫襟演播") == "紫襟演播")
        #expect(BookTitleFormatter.narratorDisplay(author: "乌贼", narrator: "") == "乌贼")

        #expect(BookTitleFormatter.narratorDisplay(author: "南山旧藏", narrator: "佚名") == "南山旧藏")
        #expect(BookTitleFormatter.narratorDisplay(author: "佚名", narrator: "未知") == "")
        #expect(BookTitleFormatter.narratorDisplay(author: "佚名", narrator: "紫襟") == "紫襟 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "南山旧藏", narrator: "我是佚名") == "南山旧藏 · 我是佚名 播讲")
    }

    @Test("DiscoverBookDisplayHelper 与 SourceContractAdapter 过滤占位词并正确回退")
    func discoverHelperAndAdapterSanitization() {
        let dirtyBook = BookSummaryDTO(
            id: "s1::1",
            sourceID: "s1",
            sourceName: "云图有声",
            bookURL: "1001",
            title: "屠龙之辈",
            author: "南山旧藏",
            narrator: "佚名"
        )
        #expect(DiscoverBookDisplayHelper.narratorText(for: dirtyBook) == "南山旧藏")

        let allUnknownBook = BookSummaryDTO(
            id: "s1::2",
            sourceID: "s1",
            sourceName: "云图有声",
            bookURL: "1002",
            title: "神秘事件",
            author: "佚名",
            narrator: "未知"
        )
        #expect(DiscoverBookDisplayHelper.narratorText(for: allUnknownBook).isEmpty)

        let listJSON = """
        {"books":[{"title":"屠龙之辈","bookUrl":"1001","author":"南山旧藏","artist":"佚名"}]}
        """
        let decoded = SourceContractAdapter.decodeBooks(listJSON, sourceID: "s1", sourceName: "云图有声")
        #expect(decoded.count == 1)
        #expect(decoded[0].author == "南山旧藏")
        #expect(decoded[0].narrator.isEmpty)
        #expect(DiscoverBookDisplayHelper.narratorText(for: decoded[0]) == "南山旧藏")

        let detailJSON = """
        {"title":"屠龙之辈","author":"南山旧藏","artist":"佚名","chapters":[]}
        """
        let detail = SourceContractAdapter.decodeBookDetail(detailJSON, fallback: dirtyBook)
        #expect(detail.summary.author == "南山旧藏")
        #expect(detail.summary.narrator.isEmpty)
        #expect(BookTitleFormatter.narratorDisplay(author: detail.summary.author, narrator: detail.summary.narrator) == "南山旧藏")
    }
}
