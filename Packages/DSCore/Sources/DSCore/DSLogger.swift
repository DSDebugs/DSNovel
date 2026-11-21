import Foundation
import os

/// 日志分类
public enum DSLogCategory: String, Sendable, CaseIterable {
    case app
    case storage
    case plugin
    case playback
    case downloads
    case network
    case ui
}

/// 诊断日志条目
public struct DSDiagnosticEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let category: DSLogCategory
    public let level: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DSLogCategory,
        level: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
    }
}

/// 统一结构化日志与脱敏诊断导出器（os.Logger + 环形缓冲，严禁泄露 Cookie/Token）
public actor DSDiagnosticLogStore {
    private static let maxRawSanitizeBytes = 16 * 1024
    private static let maxOutputCharacters = 1024

    private static let loggers: [DSLogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: DSLogCategory.allCases.map {
            ($0, Logger(subsystem: "com.dsnovel.v3", category: $0.rawValue))
        }
    )

    private let maxEntries: Int
    private var entries: [DSDiagnosticEntry] = []

    public init(maxEntries: Int = 500) {
        self.maxEntries = max(50, maxEntries)
    }

    public func record(category: DSLogCategory, level: String = "INFO", message: String) {
        let normalizedLevel = level.uppercased()
        let sanitized = Self.sanitize(message)
        let logger = Self.loggers[category] ?? Logger(subsystem: "com.dsnovel.v3", category: category.rawValue)
        switch normalizedLevel {
        case "ERROR": logger.error("\(sanitized, privacy: .public)")
        case "WARN": logger.warning("\(sanitized, privacy: .public)")
        default: logger.info("\(sanitized, privacy: .public)")
        }
        entries.append(DSDiagnosticEntry(category: category, level: normalizedLevel, message: sanitized))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func snapshot(limit: Int = 200) -> [DSDiagnosticEntry] {
        Array(entries.suffix(max(0, limit)))
    }

    public func clear() {
        entries.removeAll()
    }

    public func exportSanitizedReport(appVersion: String) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "=== DSNovel v3 脱敏诊断报告 ===",
            "版本: \(appVersion)",
            "导出时间: \(formatter.string(from: Date()))",
            "条目数: \(entries.count)",
            ""
        ]
        for entry in entries {
            lines.append("[\(formatter.string(from: entry.timestamp))] [\(entry.level)] [\(entry.category.rawValue)] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }

    private static let sanitizeRegexes: [NSRegularExpression] = [
        "(?i)(cookie|authorization|set-cookie)\\s*[:=]\\s*[^\\r\\n]+",
        "(?i)\"(token|secret|password|passwd|sign|xm_sign|sid|sessionid|api_key|apikey|authorization|cookie)\"\\s*:\\s*\"(?:\\\\.|[^\"\\\\\\r\\n])+\"?",
        "(?i)(bearer)\\s+[A-Za-z0-9._~+/=-]+",
        "(?i)(token|secret|password|passwd|1&_token|x-xmly-token|xm_sign|sign|sid|sessionid|api_key|apikey)\\s*[:=]\\s*[^\\s&;,\"']+"
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// 脱敏过滤器（AUD-07：先按 16KB 上限全量脱敏（支持转义引号与未闭合尾部引号），最后截断至 1024 字符）
    public static func sanitize(_ raw: String) -> String {
        var text: String
        if raw.utf8.count > maxRawSanitizeBytes {
            var bytes = 0
            var end = raw.startIndex
            while end < raw.endIndex {
                let next = raw.index(after: end)
                let step = raw[end..<next].utf8.count
                if bytes + step > maxRawSanitizeBytes { break }
                bytes += step
                end = next
            }
            text = String(raw[..<end])
        } else {
            text = raw
        }
        for regex in sanitizeRegexes {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1=[REDACTED]")
        }
        if text.count > maxOutputCharacters {
            return String(text.prefix(maxOutputCharacters)) + "…"
        }
        return text
    }
}
