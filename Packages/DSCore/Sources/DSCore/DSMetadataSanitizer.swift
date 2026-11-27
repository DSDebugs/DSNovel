import Foundation

/// 书籍元数据（作者 / 演播人）占位词清洗工具，统一过滤“佚名”“未知”等无意义占位值
public enum DSMetadataSanitizer {
    private static let placeholderTokens: Set<String> = [
        "佚名",
        "未知",
        "未知主播",
        "未知作者",
        "未知演播",
        "暂无",
        "无",
        "-",
        "--",
        "---",
        "null",
        "nil",
        "none",
        "n/a",
        "na",
        "unknown",
        "anonymous",
        "undefined"
    ]

    /// 去除首尾空白并过滤占位词；若为无效占位词则返回空字符串
    public static func cleanPersonName(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if placeholderTokens.contains(trimmed.lowercased()) {
            return ""
        }
        return trimmed
    }

    /// 从多个候选字符串中返回第一个非占位词的合法名称，均无效时返回 nil
    public static func firstValidPersonName(_ candidates: String?...) -> String? {
        for candidate in candidates {
            let cleaned = cleanPersonName(candidate)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    /// 优先返回有效演播人，无效或为空时回退到有效作者
    public static func displayNarratorOrAuthor(author: String?, narrator: String?) -> String {
        let n = cleanPersonName(narrator)
        if !n.isEmpty { return n }
        return cleanPersonName(author)
    }
}
