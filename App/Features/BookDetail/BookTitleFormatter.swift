import Foundation

/// 书名与演播信息规范化格式化器（清理多余广告括号、冗余前缀与空白）
enum BookTitleFormatter {
    private static let noiseRegexes: [NSRegularExpression] = [
        #"【[^】]*(免费|全集|有声|精品|多人|广播剧)[^】]*】"#,
        #"\[[^\]]*(免费|全集|有声)[^\]]*\]"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func cleanTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for regex in noiseRegexes {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    static func narratorDisplay(author: String, narrator: String) -> String {
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty && !a.isEmpty { return "\(a) · \(n) 播讲" }
        if !n.isEmpty { return "\(n) 播讲" }
        return a
    }
}
