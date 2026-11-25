import Foundation
import Testing
@testable import DSNovel

@Suite("DSBookDetail 主播名去重与书名格式化测试")
struct DSBookDetailFormatterTests {
    @Test("narratorDisplay 自动对作者与主播重复或包含关系去重")
    func narratorDeduplication() {
        #expect(BookTitleFormatter.narratorDisplay(author: "趣阅有声", narrator: "趣阅有声") == "趣阅有声 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: " 趣阅有声 ", narrator: "趣阅有声") == "趣阅有声 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "头陀渊", narrator: "头陀渊讲故事") == "头陀渊讲故事 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "老宝玉播讲", narrator: "老宝玉") == "老宝玉播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "当年明月", narrator: "王更新") == "当年明月 · 王更新 播讲")
        #expect(BookTitleFormatter.narratorDisplay(author: "", narrator: "紫襟演播") == "紫襟演播")
        #expect(BookTitleFormatter.narratorDisplay(author: "乌贼", narrator: "") == "乌贼")
    }
}
