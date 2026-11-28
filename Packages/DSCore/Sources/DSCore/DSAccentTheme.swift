import Foundation

/// 内置全局主题配色（共 6 款，针对浅色暖纸底、深色暗炭底与夜间降亮遮罩专门调校）
public enum DSAccentTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case terracotta
    case neteaseRed
    case teal
    case skyBlue
    case amber
    case violet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .terracotta: return "赤陶橙"
        case .neteaseRed: return "网易红"
        case .teal: return "松石青"
        case .skyBlue: return "晴空蓝"
        case .amber: return "琥珀金"
        case .violet: return "藤萝紫"
        }
    }
}

/// 应用冷启动默认打开的首页标签
public enum DSLaunchTab: String, Codable, Sendable, CaseIterable, Identifiable {
    case library
    case discover

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .library: return "书架"
        case .discover: return "首页"
        }
    }
}
