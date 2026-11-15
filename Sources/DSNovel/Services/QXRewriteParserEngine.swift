import Foundation
import JavaScriptCore
import Observation
import os

// MARK: - Quantumult X 重写动作类型（完整覆盖 [rewrite_local] 标准语法）
enum QXRewriteAction: String, CaseIterable, Codable, Hashable, Sendable {
    case requestHeader = "request-header"
    case responseHeader = "response-header"
    case responseBody = "response-body"
    case scriptRequestHeader = "script-request-header"
    case scriptResponseBody = "script-response-body"
    case reject = "reject"
    case reject200 = "reject-200"
    case rejectDict = "reject-dict"
    case rejectArray = "reject-array"
    case echoResponse = "echo-response"

    var displayLabel: String {
        switch self {
        case .requestHeader: return "修改请求头"
        case .responseHeader: return "修改响应头"
        case .responseBody: return "替换响应体"
        case .scriptRequestHeader: return "JS请求头脚本"
        case .scriptResponseBody: return "JS响应体脚本"
        case .reject, .reject200, .rejectDict, .rejectArray: return "拦截响应"
        case .echoResponse: return "自定义Mock响应"
        }
    }
}

// MARK: - 解析后的 Quantumult X 重写规则模型
struct QXRewriteRule: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var urlPattern: String
    var action: QXRewriteAction
    var argument1: String // 正则查找串 / 脚本路径 / echo Content-Type
    var argument2: String // 正则替换串 / echo 内容
    var scriptBody: String // 当为 script-* 且已拉取或内联 JS 代码时存储
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        urlPattern: String,
        action: QXRewriteAction,
        argument1: String = "",
        argument2: String = "",
        scriptBody: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.urlPattern = urlPattern
        self.action = action
        self.argument1 = argument1
        self.argument2 = argument2
        self.scriptBody = scriptBody
        self.isEnabled = isEnabled
    }
}

// MARK: - 请求预处理结果（支持本地拦截 / Mock 直接返回）
enum QXRequestPreprocessResult: Sendable {
    case proceed(URLRequest)
    case localResponse(Data, HTTPURLResponse)
}

/// 合规 Quantumult X `[rewrite_local]` 模块解析与执行器
/// 仅负责解析标准重写规则并在应用内执行请求/响应格式化与调试，不含任何绕过付费、破解解密或伪装逻辑。
@Observable
@MainActor
final class QXRewriteParserEngine {
    static let shared = QXRewriteParserEngine()

    var isEnabled: Bool = false {
        didSet { saveState() }
    }
    var rules: [QXRewriteRule] = [] {
        didSet { saveState() }
    }
    var hitCount: Int = 0
    var lastNotifyText: String? = nil

    private var qxPrefs: [String: String] = [:] {
        didSet { UserDefaults.standard.set(qxPrefs, forKey: "dsnovel_qx_prefs_v13") }
    }

    private let logger = Logger(subsystem: "com.dsnovel.app", category: "QXRewriteParser")
    private let stateKey = "dsnovel_qx_rewrite_rules_v13"

    private init() {
        loadState()
    }

    // MARK: - 解析 Quantumult X `[rewrite_local]` 配置文本
    nonisolated static func parseRewriteLocalRules(_ rawText: String) -> [QXRewriteRule] {
        let lines = rawText.components(separatedBy: .newlines)
        var parsed: [QXRewriteRule] = []
        var inRewriteSection = false
        var sawSectionHeader = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                sawSectionHeader = true
                let sectionName = line.lowercased()
                inRewriteSection = (sectionName == "[rewrite_local]" || sectionName == "[rewrite_remote]")
                continue
            }
            // 若文本中带有其他 [section]（如 [mitm]、[filter_local]），跳过非 rewrite 段落
            if sawSectionHeader && !inRewriteSection {
                continue
            }

            if let rule = parseSingleRewriteLine(line) {
                parsed.append(rule)
            }
        }
        return parsed
    }

    nonisolated static func parseSingleRewriteLine(_ line: String) -> QXRewriteRule? {
        guard let urlRange = line.range(of: " url ", options: .caseInsensitive) else {
            return nil
        }
        let pattern = String(line[..<urlRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let remainder = String(line[urlRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !remainder.isEmpty else { return nil }

        let tokens = splitRespectingQuotes(remainder)
        guard let actionRaw = tokens.first?.lowercased(),
              let action = QXRewriteAction(rawValue: actionRaw) else {
            return nil
        }

        let arg1 = tokens.count > 1 ? tokens[1] : ""
        let arg2 = tokens.count > 2 ? tokens[2] : ""

        return QXRewriteRule(
            urlPattern: pattern,
            action: action,
            argument1: arg1,
            argument2: arg2,
            isEnabled: true
        )
    }

    nonisolated private static func splitRespectingQuotes(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var quoteChar: Character = "\""

        for ch in text {
            if inQuotes {
                if ch == quoteChar {
                    inQuotes = false
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                inQuotes = true
                quoteChar = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    // MARK: - 批量导入并自动拉取关联的 HTTPS 脚本内容
    func importRules(from text: String) async -> Int {
        var newRules = Self.parseRewriteLocalRules(text)
        guard !newRules.isEmpty else { return 0 }

        for i in newRules.indices {
            if (newRules[i].action == .scriptResponseBody || newRules[i].action == .scriptRequestHeader),
               let scriptURL = URL(string: newRules[i].argument1),
               scriptURL.scheme?.lowercased() == "https" {
                if let (data, resp) = try? await URLSession.shared.data(from: scriptURL),
                   let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let js = String(data: data, encoding: .utf8) {
                    newRules[i].scriptBody = js
                }
            }
        }

        self.rules.append(contentsOf: newRules)
        return newRules.count
    }

    func toggleRule(id: String) {
        if let idx = rules.firstIndex(where: { $0.id == id }) {
            rules[idx].isEnabled.toggle()
        }
    }

    func removeRule(id: String) {
        rules.removeAll { $0.id == id }
    }

    func clearAllRules() {
        rules.removeAll()
    }

    // MARK: - 请求阶段重写 (`reject*`, `echo-response`, `request-header`, `script-request-header`)
    func preprocessRequest(_ originalRequest: URLRequest) -> QXRequestPreprocessResult {
        guard isEnabled, let url = originalRequest.url else {
            return .proceed(originalRequest)
        }
        let urlString = url.absoluteString
        let matched = matchingRules(for: urlString)
        guard !matched.isEmpty else {
            return .proceed(originalRequest)
        }

        var request = originalRequest

        for rule in matched {
            switch rule.action {
            case .reject, .reject200:
                hitCount += 1
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
                return .localResponse(Data(), resp)
            case .rejectDict:
                hitCount += 1
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return .localResponse(Data("{}".utf8), resp)
            case .rejectArray:
                hitCount += 1
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return .localResponse(Data("[]".utf8), resp)
            case .echoResponse:
                hitCount += 1
                let cType = rule.argument1.isEmpty ? "application/json" : rule.argument1
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": cType])!
                return .localResponse(Data(rule.argument2.utf8), resp)
            case .requestHeader:
                if !rule.argument1.isEmpty {
                    hitCount += 1
                    applyHeaderRegex(find: rule.argument1, replace: rule.argument2, to: &request)
                }
            case .scriptRequestHeader:
                if !rule.scriptBody.isEmpty {
                    hitCount += 1
                    applyScriptRequestHeader(script: rule.scriptBody, to: &request)
                }
            case .responseHeader, .responseBody, .scriptResponseBody:
                break
            }
        }

        return .proceed(request)
    }

    // MARK: - 响应阶段重写 (`response-header`, `response-body`, `script-response-body`)
    func processResponse(request: URLRequest, response: HTTPURLResponse, data: Data) -> (Data, HTTPURLResponse) {
        guard isEnabled, let urlString = request.url?.absoluteString else {
            return (data, response)
        }
        let matched = matchingRules(for: urlString)
        guard !matched.isEmpty else {
            return (data, response)
        }

        var currentData = data
        var currentResponse = response

        for rule in matched {
            switch rule.action {
            case .responseHeader:
                if !rule.argument1.isEmpty, let url = request.url {
                    hitCount += 1
                    var headers: [String: String] = [:]
                    for (k, v) in currentResponse.allHeaderFields {
                        headers[String(describing: k)] = String(describing: v)
                    }
                    headers[rule.argument1] = rule.argument2
                    if let updatedResp = HTTPURLResponse(url: url, statusCode: currentResponse.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) {
                        currentResponse = updatedResp
                    }
                }
            case .responseBody:
                if !rule.argument1.isEmpty, let text = String(data: currentData, encoding: .utf8) {
                    hitCount += 1
                    let replaced = text.replacingOccurrences(of: rule.argument1, with: rule.argument2, options: .regularExpression)
                    currentData = Data(replaced.utf8)
                }
            case .scriptResponseBody:
                if !rule.scriptBody.isEmpty {
                    hitCount += 1
                    currentData = applyScriptResponseBody(script: rule.scriptBody, request: request, response: currentResponse, data: currentData)
                }
            default:
                break
            }
        }

        return (currentData, currentResponse)
    }

    private func matchingRules(for urlString: String) -> [QXRewriteRule] {
        rules.filter { rule in
            guard rule.isEnabled else { return false }
            return urlString.range(of: rule.urlPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func applyHeaderRegex(find: String, replace: String, to request: inout URLRequest) {
        var headers = request.allHTTPHeaderFields ?? [:]
        if headers.keys.contains(find) || replace.contains(":") == false {
            headers[find] = replace
            request.allHTTPHeaderFields = headers
        }
    }

    // MARK: - JavaScriptCore 脚本执行环境 ($request, $response, $done, $prefs, $notify)
    private func applyScriptRequestHeader(script: String, to request: inout URLRequest) {
        guard let context = JSContext() else { return }
        var updatedHeaders: [String: String]? = nil

        injectQXGlobals(into: context) { doneDict in
            if let hdrs = doneDict["headers"] as? [String: Any] {
                var clean: [String: String] = [:]
                for (k, v) in hdrs { clean[k] = String(describing: v) }
                updatedHeaders = clean
            }
        }

        let reqObj: [String: Any] = [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "headers": request.allHTTPHeaderFields ?? [:]
        ]
        context.setObject(reqObj, forKeyedSubscript: "$request" as NSString)
        context.evaluateScript(script)

        if let updatedHeaders {
            request.allHTTPHeaderFields = updatedHeaders
        }
    }

    private func applyScriptResponseBody(script: String, request: URLRequest, response: HTTPURLResponse, data: Data) -> Data {
        guard let bodyStr = String(data: data, encoding: .utf8),
              let context = JSContext() else {
            return data
        }
        var updatedData = data

        injectQXGlobals(into: context) { doneDict in
            if let newBody = doneDict["body"] as? String {
                updatedData = Data(newBody.utf8)
            }
        }

        let reqObj: [String: Any] = [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "headers": request.allHTTPHeaderFields ?? [:]
        ]
        let respObj: [String: Any] = [
            "status": response.statusCode,
            "statusCode": response.statusCode,
            "headers": response.allHeaderFields,
            "body": bodyStr
        ]
        context.setObject(reqObj, forKeyedSubscript: "$request" as NSString)
        context.setObject(respObj, forKeyedSubscript: "$response" as NSString)
        context.evaluateScript(script)

        return updatedData
    }

    private func injectQXGlobals(into context: JSContext, onDone: @escaping ([String: Any]) -> Void) {
        context.exceptionHandler = { [weak self] _, ex in
            if let msg = ex?.toString() {
                self?.logger.error("QX JS exception: \(msg)")
            }
        }

        let doneBlock: @convention(block) (JSValue) -> Void = { val in
            if let dict = val.toDictionary() as? [String: Any] {
                onDone(dict)
            } else if val.isString, let str = val.toString() {
                onDone(["body": str])
            }
        }
        context.setObject(doneBlock, forKeyedSubscript: "$done" as NSString)

        let notifyBlock: @convention(block) (String, String, String) -> Void = { [weak self] t, s, m in
            Task { @MainActor in
                self?.lastNotifyText = "\(t) \(s): \(m)"
            }
        }
        context.setObject(notifyBlock, forKeyedSubscript: "$notify" as NSString)

        let currentPrefs = qxPrefs
        var pendingPrefs: [String: String] = [:]
        let getPref: @convention(block) (String) -> String? = { k in
            pendingPrefs[k] ?? currentPrefs[k]
        }
        let setPref: @convention(block) (String, String) -> Bool = { v, k in
            pendingPrefs[k] = v
            return true
        }
        context.setObject(getPref, forKeyedSubscript: "__qx_get" as NSString)
        context.setObject(setPref, forKeyedSubscript: "__qx_set" as NSString)
        context.evaluateScript("""
        var $prefs = {
            valueForKey: function(k) { return __qx_get(String(k)); },
            setValueForKey: function(v, k) { return __qx_set(String(v), String(k)); }
        };
        """)
    }

    // MARK: - 持久化
    private struct SavedState: Codable {
        var isEnabled: Bool
        var rules: [QXRewriteRule]
    }

    private func saveState() {
        let state = SavedState(isEnabled: isEnabled, rules: rules)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    private func loadState() {
        if let prefs = UserDefaults.standard.dictionary(forKey: "dsnovel_qx_prefs_v13") as? [String: String] {
            self.qxPrefs = prefs
        }
        if let data = UserDefaults.standard.data(forKey: stateKey),
           let state = try? JSONDecoder().decode(SavedState.self, from: data) {
            self.isEnabled = state.isEnabled
            self.rules = state.rules
        }
    }
}
