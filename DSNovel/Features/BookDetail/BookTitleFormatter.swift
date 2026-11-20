import Foundation

/// 书名 / 章节标题的展示层格式化（仅影响显示，不改动数据）。
enum BookTitleFormatter {
    private static let separators: Set<Character> = ["|", "｜", "丨"]

    /// 将「凡人修仙传 | 杨洋主演影视原著 | 姜广涛配音」拆为主标题与副标签。
    /// 没有分隔符时 main 即原标题、tags 为空。
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

    /// 去掉章节标题里重复的书名前缀：「凡人修仙传 第1集 二愣子」→「第1集 二愣子」。
    /// 剥离后为空、或标题并不以书名开头时，原样返回。
    static func stripBookPrefix(from chapterTitle: String, bookMainTitle: String) -> String {
        let prefix = bookMainTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, chapterTitle.hasPrefix(prefix) else { return chapterTitle }
        let rest = chapterTitle
            .dropFirst(prefix.count)
            .drop(while: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "·" || $0 == ":" || $0 == "：" })
        return rest.isEmpty ? chapterTitle : String(rest)
    }

    static func stripBookPrefix(from chapterTitle: String, bookTitle: String) -> String {
        stripBookPrefix(from: chapterTitle, bookMainTitle: split(bookTitle).main)
    }
}
