import Foundation
import SwiftUI

// MARK: - 底层双核书源标识（UI 层仅在封面上方角标与“我的-账号登录”中体现区分）
enum CoreSourceID: String, CaseIterable, Codable, Identifiable, Sendable {
    case fanqie = "fanqie"
    case ximalaya = "ximalaya"

    var id: String { rawValue }

    /// 书籍封面上方显示的来源标签文字
    var coverTopTag: String {
        switch self {
        case .fanqie: return "番茄畅听"
        case .ximalaya: return "喜马拉雅"
        }
    }

    var displayName: String {
        switch self {
        case .fanqie: return "番茄畅听"
        case .ximalaya: return "喜马拉雅"
        }
    }

    var loginCardSubtitle: String {
        switch self {
        case .fanqie: return "官方免费有声书源 · 登录后可同步番茄偏好"
        case .ximalaya: return "海量多人有声剧 · 登录后可畅听已购与VIP专辑"
        }
    }

    var brandColor: Color {
        switch self {
        case .fanqie: return Color(red: 0.96, green: 0.29, blue: 0.22)
        case .ximalaya: return Color(red: 0.98, green: 0.46, blue: 0.14)
        }
    }

    var tagBackgroundColor: Color {
        switch self {
        case .fanqie: return Color(red: 0.92, green: 0.24, blue: 0.20)
        case .ximalaya: return Color(red: 0.95, green: 0.42, blue: 0.12)
        }
    }

    var iconName: String {
        switch self {
        case .fanqie: return "flame.fill"
        case .ximalaya: return "waveform"
        }
    }

    var loginURL: URL {
        switch self {
        case .fanqie: return URL(string: "https://fanqienovel.com/")!
        case .ximalaya: return URL(string: "https://passport.ximalaya.com/page/m/login")!
        }
    }

    var cookieDomain: String {
        switch self {
        case .fanqie: return "fanqienovel.com"
        case .ximalaya: return "ximalaya.com"
        }
    }
}

// MARK: - 书城统一分类频道（双源后台无感融合，无需用户手动切源）
struct UnifiedCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let icon: String
    let fanqieKeyword: String
    let yuntuTypeId: Int
    let xmlyCategory: String
    let xmlySubcategory: String
    let searchFallbackKeyword: String

    static let all: [UnifiedCategory] = [
        UnifiedCategory(id: "hot", title: "精选热榜", icon: "flame.fill", fanqieKeyword: "凡人修仙传", yuntuTypeId: 125, xmlyCategory: "youshengshu", xmlySubcategory: "", searchFallbackKeyword: "凡人修仙传"),
        UnifiedCategory(id: "free_best", title: "完本高分", icon: "crown.fill", fanqieKeyword: "剑来", yuntuTypeId: 137, xmlyCategory: "youshengshu", xmlySubcategory: "xianxia", searchFallbackKeyword: "剑来"),
        UnifiedCategory(id: "urban", title: "都市爽文", icon: "building.2.fill", fanqieKeyword: "都市", yuntuTypeId: 143, xmlyCategory: "youshengshu", xmlySubcategory: "dushi", searchFallbackKeyword: "都市"),
        UnifiedCategory(id: "fantasy", title: "玄幻修仙", icon: "sparkles", fanqieKeyword: "修仙", yuntuTypeId: 335, xmlyCategory: "youshengshu", xmlySubcategory: "xuanhuan", searchFallbackKeyword: "遮天"),
        UnifiedCategory(id: "mystery", title: "悬疑盗墓", icon: "moon.stars.fill", fanqieKeyword: "盗墓", yuntuTypeId: 142, xmlyCategory: "youshengshu", xmlySubcategory: "xuanyi", searchFallbackKeyword: "盗墓笔记"),
        UnifiedCategory(id: "history", title: "历史风云", icon: "shield.lefthalf.filled", fanqieKeyword: "历史", yuntuTypeId: 165, xmlyCategory: "youshengshu", xmlySubcategory: "lishi", searchFallbackKeyword: "明朝那些事儿"),
        UnifiedCategory(id: "scifi", title: "科幻星际", icon: "globe.asia.australia.fill", fanqieKeyword: "科幻", yuntuTypeId: 139, xmlyCategory: "youshengshu", xmlySubcategory: "kehuan", searchFallbackKeyword: "三体"),
        UnifiedCategory(id: "romance", title: "言情古风", icon: "heart.fill", fanqieKeyword: "古风", yuntuTypeId: 138, xmlyCategory: "youshengshu", xmlySubcategory: "yanqing", searchFallbackKeyword: "庆余年"),
        UnifiedCategory(id: "wuxia", title: "武侠江湖", icon: "wind", fanqieKeyword: "武侠", yuntuTypeId: 335, xmlyCategory: "youshengshu", xmlySubcategory: "wuxia", searchFallbackKeyword: "雪中悍刀行"),
        UnifiedCategory(id: "pingshu", title: "相声评书", icon: "theatermasks.fill", fanqieKeyword: "评书", yuntuTypeId: 168, xmlyCategory: "xiangsheng", xmlySubcategory: "", searchFallbackKeyword: "郭德纲相声"),
        UnifiedCategory(id: "classic", title: "出版名著", icon: "book.closed.fill", fanqieKeyword: "名著", yuntuTypeId: 131, xmlyCategory: "youshengshu", xmlySubcategory: "wenxue", searchFallbackKeyword: "平凡的世界"),
        UnifiedCategory(id: "humanities", title: "百家人文", icon: "graduationcap.fill", fanqieKeyword: "文化", yuntuTypeId: 164, xmlyCategory: "lishi", xmlySubcategory: "", searchFallbackKeyword: "百家讲坛")
    ]
}

// MARK: - 统一书籍模型
struct BookItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var source: CoreSourceID
    var albumId: String
    var title: String
    var author: String
    var coverURL: String
    var intro: String
    var categoryName: String
    var statusText: String
    var totalTracks: Int
    var isCompletelyFree: Bool

    init(
        id: String? = nil,
        source: CoreSourceID,
        albumId: String,
        title: String,
        author: String,
        coverURL: String,
        intro: String,
        categoryName: String = "有声小说",
        statusText: String = "全本畅听",
        totalTracks: Int = 0,
        isCompletelyFree: Bool = true
    ) {
        self.id = id ?? "\(source.rawValue)_\(albumId)"
        self.source = source
        self.albumId = albumId
        self.title = Self.cleanBookTitle(title)
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "金牌演播" : author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.coverURL = Self.normalizeHttps(coverURL)
        self.intro = intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "精品有声剧，支持全量章节秒级加载与跨源无缝续听。" : intro.trimmingCharacters(in: .whitespacesAndNewlines)
        self.categoryName = categoryName
        self.statusText = statusText
        self.totalTracks = totalTracks
        self.isCompletelyFree = isCompletelyFree
    }

    static func normalizeHttps(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        if trimmed.lowercased().hasPrefix("http://") {
            return "https://" + trimmed.dropFirst(7)
        }
        return trimmed
    }

    static func cleanBookTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: """)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 统一章节模型（含规整化标题）
struct EpisodeItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var trackId: String
    var index: Int
    var rawTitle: String
    var displayTitle: String
    var durationSeconds: Int
    var isFree: Bool
    var directStreamURL: String?

    init(
        id: String? = nil,
        trackId: String,
        index: Int,
        rawTitle: String,
        bookTitle: String = "",
        durationSeconds: Int = 0,
        isFree: Bool = true,
        directStreamURL: String? = nil
    ) {
        self.id = id ?? "\(trackId)_\(index)"
        self.trackId = trackId
        self.index = index
        self.rawTitle = rawTitle
        self.displayTitle = Self.formatEpisodeTitle(rawTitle, index: index, bookTitle: bookTitle)
        self.durationSeconds = durationSeconds
        self.isFree = isFree
        self.directStreamURL = directStreamURL
    }

    var formattedDuration: String {
        guard durationSeconds > 0 else { return "高清人声" }
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    static func formatEpisodeTitle(_ raw: String, index: Int, bookTitle: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\\.(mp3|m4a|aac|wav|flac)$", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "【[^】]*(?:订阅|关注|福利|公众号|微信|加群|上架|赞助)[^】]*】", with: "", options: .regularExpression)

        if !bookTitle.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: bookTitle)
            s = s.replacingOccurrences(of: "^《?\(escaped)》?[\\s_\\-—:：|·]*", with: "", options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.isEmpty {
            return "第\(index)集"
        }
        if s.range(of: "^\\d+$", options: .regularExpression) != nil {
            let num = Int(s) ?? index
            return "第\(num)集"
        }
        if let match = s.range(of: "^(\\d{1,4})[\\s._\\-—:：]+(.+)$", options: .regularExpression) {
            let full = String(s[match])
            let parts = full.split(maxSplits: 1, whereSeparator: { !$0.isNumber })
            if let firstNum = parts.first, let n = Int(firstNum) {
                let rest = s.dropFirst(firstNum.count).trimmingCharacters(in: CharacterSet(charactersIn: " ._\-—:："))
                if !rest.hasPrefix("第") {
                    return "第\(n)集 \(rest)"
                }
            }
        }
        if !s.contains("第") && !s.contains("集") && !s.contains("章") && !s.contains("回") && !s.contains("卷") && !s.contains("序") && !s.contains("楔子") && !s.contains("番外") {
            return "第\(index)集 \(s)"
        }
        return s
    }
}

// MARK: - 书架与历史进度条目
struct BookshelfEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { book.id }
    var book: BookItem
    var isFavorite: Bool
    var lastEpisodeIndex: Int
    var lastEpisodeTitle: String
    var lastPlaybackTime: Double
    var updatedAt: Date

    var formattedProgressTime: String {
        guard lastPlaybackTime > 1 else { return "刚刚开始" }
        let m = Int(lastPlaybackTime) / 60
        let s = Int(lastPlaybackTime) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 音频书签模型
struct AudioBookmark: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var bookId: String
    var bookTitle: String
    var episodeIndex: Int
    var episodeTitle: String
    var timestamp: Double
    var note: String
    var createdAt: Date

    var formattedTimestamp: String {
        let mins = Int(timestamp) / 60
        let secs = Int(timestamp) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
