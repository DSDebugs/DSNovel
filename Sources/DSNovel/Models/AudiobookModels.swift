import Foundation
import SwiftUI

// MARK: - 书源标识（严格反映真实内容来源）
enum CoreSourceID: String, CaseIterable, Codable, Identifiable, Sendable {
    case ximalaya = "ximalaya"

    var id: String { rawValue }

    var coverTopTag: String { "喜马拉雅" }
    var displayName: String { "喜马拉雅" }
    var loginCardSubtitle: String { "登录官方喜马拉雅账号以同步个人收藏与已购专辑" }

    var brandColor: Color { Color(red: 0.98, green: 0.46, blue: 0.14) }
    var tagBackgroundColor: Color { Color(red: 0.95, green: 0.42, blue: 0.12) }
    var iconName: String { "waveform" }
    var loginURL: URL { URL(string: "https://passport.ximalaya.com/page/m/login")! }
    var cookieDomain: String { "ximalaya.com" }
}

// MARK: - 书城统一 12 大精选分类（双排六列网格直达）
struct UnifiedCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let shortTitle: String
    let icon: String
    let xmlyCategory: String
    let xmlySubcategory: String
    let keyword: String

    static let all: [UnifiedCategory] = [
        UnifiedCategory(id: "hot", title: "精选热榜", shortTitle: "热播榜", icon: "flame.fill", xmlyCategory: "youshengshu", xmlySubcategory: "", keyword: "凡人修仙传"),
        UnifiedCategory(id: "free_best", title: "免费精品", shortTitle: "免费榜", icon: "crown.fill", xmlyCategory: "youshengshu", xmlySubcategory: "xianxia", keyword: "剑来"),
        UnifiedCategory(id: "urban", title: "都市爽文", shortTitle: "都市", icon: "building.2.fill", xmlyCategory: "youshengshu", xmlySubcategory: "dushi", keyword: "都市"),
        UnifiedCategory(id: "fantasy", title: "玄幻修仙", shortTitle: "玄幻", icon: "sparkles", xmlyCategory: "youshengshu", xmlySubcategory: "xuanhuan", keyword: "遮天"),
        UnifiedCategory(id: "mystery", title: "悬疑推理", shortTitle: "悬疑", icon: "moon.stars.fill", xmlyCategory: "youshengshu", xmlySubcategory: "xuanyi", keyword: "盗墓笔记"),
        UnifiedCategory(id: "history", title: "历史风云", shortTitle: "历史", icon: "shield.lefthalf.filled", xmlyCategory: "youshengshu", xmlySubcategory: "lishi", keyword: "明朝那些事儿"),
        UnifiedCategory(id: "scifi", title: "科幻星际", shortTitle: "科幻", icon: "globe.asia.australia.fill", xmlyCategory: "youshengshu", xmlySubcategory: "kehuan", keyword: "三体"),
        UnifiedCategory(id: "romance", title: "言情古风", shortTitle: "古风", icon: "heart.fill", xmlyCategory: "youshengshu", xmlySubcategory: "yanqing", keyword: "庆余年"),
        UnifiedCategory(id: "wuxia", title: "武侠江湖", shortTitle: "武侠", icon: "wind", xmlyCategory: "youshengshu", xmlySubcategory: "wuxia", keyword: "雪中悍刀行"),
        UnifiedCategory(id: "pingshu", title: "相声评书", shortTitle: "相声", icon: "theatermasks.fill", xmlyCategory: "xiangsheng", xmlySubcategory: "", keyword: "郭德纲相声"),
        UnifiedCategory(id: "classic", title: "出版名著", shortTitle: "名著", icon: "book.closed.fill", xmlyCategory: "youshengshu", xmlySubcategory: "wenxue", keyword: "平凡的世界"),
        UnifiedCategory(id: "humanities", title: "百家人文", shortTitle: "人文", icon: "graduationcap.fill", xmlyCategory: "lishi", xmlySubcategory: "", keyword: "百家讲坛")
    ]
}

// MARK: - 统一书籍模型（含容错解码，M-14/L-06）
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
        source: CoreSourceID = .ximalaya,
        albumId: String,
        title: String,
        author: String,
        coverURL: String,
        intro: String,
        categoryName: String = "有声小说",
        statusText: String = "",
        totalTracks: Int = 0,
        isCompletelyFree: Bool = true
    ) {
        self.id = id ?? "\(source.rawValue)_\(albumId)"
        self.source = source
        self.albumId = albumId
        self.title = Self.cleanBookTitle(title)
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.coverURL = Self.normalizeHttps(coverURL)
        self.intro = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        self.categoryName = categoryName
        self.statusText = statusText.isEmpty ? (isCompletelyFree ? "免费公开" : "需登录/会员") : statusText
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
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 作品匹配辅助 (H-05)
enum WorkMatcher {
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: #"[（(\[【].*?[）)\]】]|[\s《》:：\-_]"#, with: "", options: .regularExpression)
            .lowercased()
    }

    static func isSameWork(_ a: BookItem, _ b: BookItem) -> Bool {
        let na = normalize(a.title)
        let nb = normalize(b.title)
        guard !na.isEmpty, na == nb else { return false }
        if !a.author.isEmpty, !b.author.isEmpty, a.author != b.author {
            return false
        }
        if a.totalTracks > 0, b.totalTracks > 0 {
            let diff = Double(abs(a.totalTracks - b.totalTracks))
            return diff / Double(max(a.totalTracks, b.totalTracks)) <= 0.1
        }
        return true
    }
}

// MARK: - 章节列表包装（含完整性标记，H-04）
struct EpisodeListResult: Sendable {
    let episodes: [EpisodeItem]
    let isComplete: Bool
    let failedPages: [Int]
}

// MARK: - 统一章节模型 (M-14, L-07)
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
        guard durationSeconds > 0 else { return "" }
        let h = durationSeconds / 3600
        let m = (durationSeconds % 3600) / 60
        let s = durationSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private static let extRegex = try! NSRegularExpression(pattern: #"\.(mp3|m4a|aac|wav|flac)$"#, options: [.caseInsensitive])
    private static let promoRegex = try! NSRegularExpression(pattern: #"【[^】]*(?:订阅|关注|福利|公众号|微信|加群|上架|赞助)[^】]*】"#)
    private static let pureDigitsRegex = try! NSRegularExpression(pattern: #"^\d+$"#)
    private static let leadingDigitsRegex = try! NSRegularExpression(pattern: #"^(\d{1,4})[\s._\-—:：]+(.+)$"#)
    private static let existingSerialRegex = try! NSRegularExpression(pattern: #"(第\s*\d+\s*[集章回卷节]|^(序章?|楔子|番外|尾声|简介))"#)

    static func formatEpisodeTitle(_ raw: String, index: Int, bookTitle: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsRange = { (str: String) in NSRange(str.startIndex..<str.endIndex, in: str) }

        s = extRegex.stringByReplacingMatches(in: s, range: nsRange(s), withTemplate: "")
        s = promoRegex.stringByReplacingMatches(in: s, range: nsRange(s), withTemplate: "")

        if !bookTitle.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: bookTitle)
            s = s.replacingOccurrences(of: "^《?\(escaped)》?[\\s_\\-—:：|·]*", with: "", options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.isEmpty {
            return "第\(index)集"
        }
        if pureDigitsRegex.firstMatch(in: s, range: nsRange(s)) != nil {
            let num = Int(s) ?? index
            return "第\(num)集"
        }
        if let match = leadingDigitsRegex.firstMatch(in: s, range: nsRange(s)),
           let numRange = Range(match.range(at: 1), in: s),
           let restRange = Range(match.range(at: 2), in: s),
           let n = Int(s[numRange]) {
            let rest = String(s[restRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if existingSerialRegex.firstMatch(in: rest, range: nsRange(rest)) == nil {
                return "第\(n)集 \(rest)"
            }
            return rest
        }
        if existingSerialRegex.firstMatch(in: s, range: nsRange(s)) == nil {
            return "第\(index)集 \(s)"
        }
        return s
    }
}

// MARK: - 书架藏书与最近收听记录条目（H-10 含 schemaVersion）
struct BookshelfEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { book.id }
    var book: BookItem
    var lastEpisodeIndex: Int
    var lastEpisodeTitle: String
    var lastPlaybackTime: Double
    var updatedAt: Date

    private static let recordDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var formattedProgressTime: String {
        guard lastPlaybackTime > 1 else { return "00:00" }
        let total = Int(lastPlaybackTime)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    var formattedDateRecord: String {
        Self.recordDateFormatter.string(from: updatedAt)
    }
}

struct LibraryArchive: Codable, Sendable {
    var schemaVersion: Int = 2
    var entries: [BookshelfEntry]
}
