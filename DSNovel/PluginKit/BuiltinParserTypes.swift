import Foundation

// MARK: - 内置解析：类型定义
//
// 「内置解析」是书源之上的**旁路层**：它不注册书源、不参与搜索/发现/健康检查，
// 只在「书源自身拿不到音频地址（VIP/付费章节）」时被调用，用于解析可播放/可下载的音频直链。
// 绑定关系：host 匹配优先、sourceID 兜底（见 BuiltinParserRuntime.parser(forSourceID:sourceURL:)）。

/// 解析器声明的目标书源（脚本里 `targets: { hosts: [...], sourceIDs: [...] }`）
struct BuiltinParserTargets: Codable, Hashable, Sendable {
    var hosts: [String]
    var sourceIDs: [String]

    static let empty = BuiltinParserTargets(hosts: [], sourceIDs: [])

    init(hosts: [String] = [], sourceIDs: [String] = []) {
        self.hosts = hosts.map { $0.lowercased() }
        self.sourceIDs = sourceIDs
    }

    /// 是否命中指定书源（host 优先 + sourceID 兜底）
    func matches(sourceID: String, sourceURL: String) -> Bool {
        if !sourceIDs.isEmpty, sourceIDs.contains(sourceID) {
            return true
        }
        guard !hosts.isEmpty else { return false }
        guard let host = URL(string: sourceURL)?.host?.lowercased(), !host.isEmpty else {
            return false
        }
        return hosts.contains { pattern in
            let p = pattern.lowercased()
            if p.isEmpty { return false }
            if p == host { return true }
            return host.hasSuffix("." + p) || host.hasSuffix(p)
        }
    }
}

/// 解析器可暴露给 UI 的配置项（值统一存 UserDefaults：parser_pref_<parserID>.<key>）
struct BuiltinParserConfigItem: Codable, Hashable, Sendable {
    var key: String
    var title: String
    var defaultValue: String
    /// "enum" / "bool" / "number" / "text"
    var kind: String
    /// kind == "enum" 时的候选项
    var options: [String]

    init(key: String, title: String, defaultValue: String, kind: String = "text", options: [String] = []) {
        self.key = key
        self.title = title
        self.defaultValue = defaultValue
        self.kind = kind
        self.options = options
    }
}

/// 脚本 `__metaParser()` 返回的解析器元数据
struct BuiltinParserMeta: Hashable, Sendable {
    var id: String
    var name: String
    var version: String
    var author: String
    var summary: String
    var targets: BuiltinParserTargets
    var supportsPlayback: Bool
    var supportsDownload: Bool
    var requiresCookie: Bool
    var config: [BuiltinParserConfigItem]
    var methods: Set<String>

    var displayVersion: String { version.isEmpty ? "未知版本" : version }
}

/// 已安装的解析器（磁盘上的一个目录 + meta.json + parser.js）
struct InstalledBuiltinParser: Identifiable, Hashable, Sendable {
    var meta: BuiltinParserMeta
    var fileName: String
    var sha256: String
    var sizeBytes: Int
    var importedAt: Date
    var directory: URL

    var id: String { meta.id }
}

/// 导入前的预览（干跑校验通过后才产出）
struct BuiltinParserPreview: Identifiable, Sendable {
    var id: String { meta.id }
    var meta: BuiltinParserMeta
    var fileName: String
    var sha256: String
    var sizeBytes: Int
    /// 已用 `decodeScriptText` 解码并干跑验证过的脚本正文
    var scriptText: String
    var isUpdate: Bool
    var installedVersion: String?
}

/// `checkStatus()` 的结果
struct BuiltinParserStatus: Hashable, Sendable {
    var ok: Bool
    var message: String
    var latencyMs: Int
    var nickname: String
    var vipExpireAt: String

    static let unknown = BuiltinParserStatus(ok: false, message: "尚未检测", latencyMs: 0, nickname: "", vipExpireAt: "")
}

/// 解析器调用策略（宿主级设置，默认 fallback）
enum BuiltinParserStrategy: String, CaseIterable, Sendable {
    /// 官方书源接口优先，仅在 VIP/受限错误时回退到内置解析（默认）
    case fallback
    /// 一律优先走内置解析，失败再回落官方接口
    case always
    /// 关闭（保留脚本，仅调试用）
    case never

    var title: String {
        switch self {
        case .fallback: return "官方接口优先（推荐）"
        case .always: return "内置解析优先"
        case .never: return "关闭"
        }
    }
}

/// 内置解析相关错误
enum BuiltinParserError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case noMatchingParser(sourceID: String)
    case scriptInvalid(String)
    case invokeFailed(String)
    case timeout
    /// 脚本主动抛出的语义化失败（reason 码：no_cookie / not_vip / paid_api_failed / free_api_failed / rate_limited / expired_link / bad_track）
    case rejected(String, String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "尚未导入内置解析脚本"
        case .noMatchingParser:
            return "当前书源没有匹配的内置解析脚本"
        case .scriptInvalid(let why):
            return "解析脚本不可用：\(why)"
        case .invokeFailed(let why):
            return "解析脚本执行失败：\(why)"
        case .timeout:
            return "内置解析超时"
        case .rejected(let reason, let msg):
            let base: String
            switch reason {
            case "no_cookie": base = "未取到可用 Cookie"
            case "not_vip": base = "该账号无权访问此 VIP 内容"
            case "paid_api_failed": base = "付费直链接口解析失败"
            case "free_api_failed": base = "免费直链接口解析失败"
            case "rate_limited": base = "请求过于频繁，请稍后再试"
            case "expired_link": base = "直链已过期"
            case "bad_track": base = "无法识别章节 ID"
            default: base = "解析失败"
            }
            return msg.isEmpty ? base : "\(base)（\(msg)）"
        case .rateLimited:
            return "内置解析请求过于频繁，请稍后再试"
        }
    }

    /// 供 UI 判定是否属于「频率限制」类错误
    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        if case .rejected(let reason, _) = self, reason == "rate_limited" { return true }
        return false
    }
}

// MARK: - 内置解析文案（全 App 唯一提示出口，集中在此处便于统一口径）

enum BuiltinParserStrings {
    /// 未安装解析脚本时，VIP 章节报错的文案
    static let vipNeedsParser = "该章节为 VIP 内容，需要内置解析"
    /// 按钮标题（未安装）
    static let jumpToImport = "去导入内置解析"
    /// 按钮标题（已安装但解析失败）
    static let jumpToInspect = "去查内置解析"
    /// 解析器分区标题
    static let sectionTitle = "内置解析"
    /// 空态的中性状态值（不是提示语，仅客观状态）
    static let notInstalledValue = "未安装"
}
