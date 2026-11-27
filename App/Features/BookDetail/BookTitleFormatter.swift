import DSCore
import Foundation

/// 书名与演播信息规范化格式化器（保留 v3.0 既有公开静态接口并补全 v2.8 拆分与前缀剥离能力）
enum BookTitleFormatter {
    private static let noiseRegexes: [NSRegularExpression] = [
        #"【[^】]*(免费|全集|有声|精品|多人|广播剧)[^】]*】"#,
        #"\[[^\]]*(免费|全集|有声)[^\]]*\]"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let separators: Set<Character> = ["|", "｜", "丨"]

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
        let a = DSMetadataSanitizer.cleanPersonName(author)
        let n = DSMetadataSanitizer.cleanPersonName(narrator)
        func suffix(_ name: String) -> String {
            (name.hasSuffix("播讲") || name.hasSuffix("演播")) ? name : "\(name) 播讲"
        }
        if !n.isEmpty && !a.isEmpty {
            let lowA = a.lowercased(), lowN = n.lowercased()
            if lowA == lowN || lowN.contains(lowA) {
                return suffix(n)
            }
            if lowA.contains(lowN) {
                return suffix(a)
            }
            return "\(a) · \(suffix(n))"
        }
        if !n.isEmpty { return suffix(n) }
        return a
    }

    /// 将带竖线分隔符的书名拆为主标题与副标签
    static func split(_ raw: String) -> (main: String, tags: [String]) {
        let parts = raw
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1, let first = parts.first else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        return (first, Array(parts.dropFirst()))
    }

    /// 去掉章节标题里重复的书名前缀
    static func stripBookPrefix(from chapterTitle: String, bookMainTitle: String) -> String {
        let prefix = bookMainTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, chapterTitle.hasPrefix(prefix) else { return chapterTitle }
        let rest = chapterTitle
            .dropFirst(prefix.count)
            .drop(while: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "·" || $0 == ":" || $0 == "：" })
        return rest.isEmpty ? chapterTitle : String(rest)
    }

    static func stripBookPrefix(from chapterTitle: String, bookTitle: String) -> String {
        stripBookPrefix(from: chapterTitle, bookMainTitle: split(cleanTitle(bookTitle)).main)
    }
}
