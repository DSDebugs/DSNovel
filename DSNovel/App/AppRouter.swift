import SwiftUI
import Observation

// MARK: - 全局跳转路由
//
// 目前只有一个用途：VIP 章节报错时，从任意页面（书籍详情 / 播放器 / 发现 / 搜索）
// 跳到「设置 → 书源管理 → 该书源的 内置解析 分区」。这是全 App 唯一的内置解析提示出口。

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// 待处理的目标书源（由 BuiltinParserStrings 的提示按钮写入）
    private(set) var pendingParserSourceID: String?

    private init() {}

    /// 请求跳转到内置解析分区
    func openBuiltinParser(sourceID: String?) {
        pendingParserSourceID = sourceID ?? ""
    }

    /// 取出并清空待处理跳转（由 PluginManagerView 消费）
    func consumePendingParserFocus() -> String? {
        defer { pendingParserSourceID = nil }
        return pendingParserSourceID
    }
}
