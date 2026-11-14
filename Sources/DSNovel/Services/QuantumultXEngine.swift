import Foundation
import JavaScriptCore
import Observation
import CFNetwork

// MARK: - 软件内部代理路由模式
enum InAppProxyMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case direct = "直连模式"
    case globalProxy = "软件内全局代理"
    case splitBySource = "分书源单独代理"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .direct:
            return "所有请求直接连接，不经过代理服务器（仍可执行 Quantumult X 本地脚本重写）"
        case .globalProxy:
            return "仅对 DSNovel 软件内部全部流量生效，统一走所选主代理节点，不影响系统其他 App"
        case .splitBySource:
            return "喜马拉雅与番茄畅听分别独立绑定不同代理节点或直连，精准分流"
        }
    }
}

// MARK: - 代理协议类型（支持 HTTP / HTTPS / SOCKS5）
enum QXProxyProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case http = "HTTP"
    case https = "HTTPS"
    case socks5 = "SOCKS5"

    var id: String { rawValue }
}

// MARK: - 代理节点模型（兼容 Quantumult X [server_local] 格式）
struct QXProxyNode: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var tag: String
    var proto: QXProxyProtocol
    var host: String
    var port: Int
    var username: String
    var password: String
    var lastLatencyMs: Int?

    init(
        id: String = UUID().uuidString,
        tag: String,
        proto: QXProxyProtocol = .http,
        host: String,
        port: Int,
        username: String = "",
        password: String = "",
        lastLatencyMs: Int? = nil
    ) {
        self.id = id
        self.tag = tag
        self.proto = proto
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.lastLatencyMs = lastLatencyMs
    }

    var summaryText: String {
        "\(proto.rawValue) · \(host):\(port)"
    }

    /// 解析 Quantumult X `[server_local]` 行，例如：
    /// `http=127.0.0.1:8080, username=user, password=pass, tag=香港高速节点`
    /// `socks5=192.168.1.10:1080, tag=家宽SOCKS5`
    static func parseServerLocalLine(_ rawLine: String) -> QXProxyNode? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("[") else { return nil }

        let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = parts.first, let eqIdx = first.firstIndex(of: "=") else { return nil }

        let protoStr = first[..<eqIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let addrStr = first[first.index(after: eqIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)

        let proto: QXProxyProtocol
        if protoStr.contains("socks") {
            proto = .socks5
        } else if protoStr.contains("https") || protoStr.contains("tls") {
            proto = .https
        } else {
            proto = .http
        }

        let addrParts = addrStr.split(separator: ":")
        guard addrParts.count == 2,
              let port = Int(addrParts[1]) else { return nil }
        let host = String(addrParts[0])

        var tag = "\(proto.rawValue)_\(host):\(port)"
        var user = ""
        var pass = ""

        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard kv.count == 2 else { continue }
            let k = kv[0].lowercased()
            let v = kv[1]
            if k == "tag" { tag = v }
            else if k == "username" { user = v }
            else if k == "password" { pass = v }
        }

        return QXProxyNode(tag: tag, proto: proto, host: host, port: port, username: user, password: pass)
    }
}

// MARK: - 单书源路由策略（用于“分书源单独代理”）
enum QXSourceRoutePolicy: Codable, Hashable, Sendable {
    case direct
    case followGlobal
    case specificNode(nodeId: String)

    var displayLabel: String {
        switch self {
        case .direct: return "直连 (DIRECT)"
        case .followGlobal: return "跟随主代理节点"
        case .specificNode(let id): return "指定节点(\(id.prefix(4)))"
        }
    }
}

// MARK: - Quantumult X 重写与脚本动作类型
enum QXRewriteActionType: String, CaseIterable, Codable, Identifiable, Sendable {
    case scriptResponseBody = "script-response-body"
    case scriptRequestHeader = "script-request-header"
    case responseBodyRegex = "response-body"
    case requestHeaderRegex = "request-header"
    case reject = "reject"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .scriptResponseBody: return "JS响应体脚本 (script-response-body)"
        case .scriptRequestHeader: return "JS请求头脚本 (script-request-header)"
        case .responseBodyRegex: return "正则替换响应体 (response-body)"
        case .requestHeaderRegex: return "正则修改请求头 (request-header)"
        case .reject: return "拦截请求 (reject)"
        }
    }
}

// MARK: - Quantumult X 脚本与重写规则模型
struct QXScriptRule: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var targetSource: CoreSourceID? // nil 表示双源通用，非 nil 表示仅针对喜马拉雅或番茄畅听
    var urlPattern: String
    var actionType: QXRewriteActionType
    var jsCode: String
    var replacementArg1: String
    var replacementArg2: String
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        targetSource: CoreSourceID? = nil,
        urlPattern: String,
        actionType: QXRewriteActionType = .scriptResponseBody,
        jsCode: String = "",
        replacementArg1: String = "",
        replacementArg2: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.targetSource = targetSource
        self.urlPattern = urlPattern
        self.actionType = actionType
        self.jsCode = jsCode
        self.replacementArg1 = replacementArg1
        self.replacementArg2 = replacementArg2
        self.isEnabled = isEnabled
    }
}

// MARK: - 实时代理与脚本命中日志条目
struct QXTrafficLogEntry: Identifiable, Sendable {
    let id = UUID().uuidString
    let timestamp: Date
    let sourceName: String
    let urlString: String
    let routeSummary: String
    let matchedScriptName: String?
    let statusCode: Int
    let durationMs: Int
}

// MARK: - Quantumult X 内部代理与脚本核心引擎
@Observable
@MainActor
final class QuantumultXEngine {
    static let shared = QuantumultXEngine()

    var isProxyEnabled: Bool = false {
        didSet { saveConfiguration() }
    }
    var proxyMode: InAppProxyMode = .splitBySource {
        didSet { saveConfiguration() }
    }
    var isScriptEngineEnabled: Bool = true {
        didSet { saveConfiguration() }
    }

    var nodes: [QXProxyNode] = [] {
        didSet { saveConfiguration() }
    }
    var selectedGlobalNodeId: String = "" {
        didSet { saveConfiguration() }
    }

    // 分书源单独代理策略：喜马拉雅与番茄畅听可分别指定不同代理节点或直连
    var sourceNodeIdMap: [CoreSourceID: String] = [
        .ximalaya: "DIRECT",
        .fanqie: "DIRECT"
    ] {
        didSet { saveConfiguration() }
    }

    var scriptRules: [QXScriptRule] = [] {
        didSet { saveConfiguration() }
    }

    // Quantumult X `$prefs` 持久化键值存储
    var qxPrefsStore: [String: String] = [:] {
        didSet { UserDefaults.standard.set(qxPrefsStore, forKey: "dsnovel_qx_prefs_v8") }
    }

    var trafficLogs: [QXTrafficLogEntry] = []
    var lastNotificationMessage: String? = nil

    private var sessionCache: [String: URLSession] = [:]
    private let directSession: URLSession

    private let configKey = "dsnovel_qx_config_v8"

    private init() {
        let baseConfig = URLSessionConfiguration.default
        baseConfig.timeoutIntervalForRequest = 10
        baseConfig.timeoutIntervalForResource = 20
        baseConfig.httpAdditionalHeaders = [
            "Accept-Language": "zh-CN,zh;q=0.9",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]
        self.directSession = URLSession(configuration: baseConfig)
        loadConfiguration()
    }

    // MARK: - 获取指定书源当前生效的代理节点（nil 代表直连 DIRECT）
    func activeProxyNode(for source: CoreSourceID?) -> QXProxyNode? {
        guard isProxyEnabled else { return nil }
        switch proxyMode {
        case .direct:
            return nil
        case .globalProxy:
            return nodes.first(where: { $0.id == selectedGlobalNodeId }) ?? nodes.first
        case .splitBySource:
            guard let source else {
                return nodes.first(where: { $0.id == selectedGlobalNodeId })
            }
            let targetId = sourceNodeIdMap[source] ?? "DIRECT"
            if targetId == "DIRECT" { return nil }
            if targetId == "GLOBAL" {
                return nodes.first(where: { $0.id == selectedGlobalNodeId }) ?? nodes.first
            }
            return nodes.first(where: { $0.id == targetId })
        }
    }

    func routeDescription(for source: CoreSourceID) -> String {
        guard isProxyEnabled else { return "直连 (未开启代理)" }
        if let node = activeProxyNode(for: source) {
            return "\(node.tag) (\(node.proto.rawValue))"
        }
        return "直连 (DIRECT)"
    }

    // MARK: - 构建带应用内代理字典的 URLSession（仅作用于 App 内部请求）
    private func urlSession(for node: QXProxyNode?) -> URLSession {
        guard let node else { return directSession }
        let cacheKey = "\(node.proto.rawValue)_\(node.host)_\(node.port)_\(node.username)_\(node.password)"
        if let cached = sessionCache[cacheKey] {
            return cached
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 24

        var headers: [String: String] = [
            "Accept-Language": "zh-CN,zh;q=0.9",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]

        if !node.username.isEmpty {
            let cred = "\(node.username):\(node.password)"
            if let credData = cred.data(using: .utf8) {
                headers["Proxy-Authorization"] = "Basic \(credData.base64EncodedString())"
            }
        }
        config.httpAdditionalHeaders = headers

        var proxyDict: [AnyHashable: Any] = [:]
        switch node.proto {
        case .http, .https:
            proxyDict[kCFNetworkProxiesHTTPEnable as String] = 1
            proxyDict[kCFNetworkProxiesHTTPProxy as String] = node.host
            proxyDict[kCFNetworkProxiesHTTPPort as String] = node.port
            proxyDict["HTTPSEnable"] = 1
            proxyDict["HTTPSProxy"] = node.host
            proxyDict["HTTPSPort"] = node.port
        case .socks5:
            proxyDict["SOCKSEnable"] = 1
            proxyDict[kCFStreamPropertySOCKSProxyHost as String] = node.host
            proxyDict[kCFStreamPropertySOCKSProxyPort as String] = node.port
            proxyDict[kCFStreamPropertySOCKSVersion as String] = kCFStreamSocketSOCKSVersion5
            if !node.username.isEmpty {
                proxyDict[kCFStreamPropertySOCKSUser as String] = node.username
                proxyDict[kCFStreamPropertySOCKSPassword as String] = node.password
            }
        }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        sessionCache[cacheKey] = session
        return session
    }

    // MARK: - 统一执行网络请求（自动挂载分书源代理 + 执行 Quantumult X 请求/响应脚本）
    func performRequest(_ originalRequest: URLRequest, for source: CoreSourceID?) async throws -> (Data, HTTPURLResponse) {
        let startTime = Date()
        var request = originalRequest
        let urlString = request.url?.absoluteString ?? ""

        // 1. 匹配启用的 Quantumult X 规则
        let matchedRules = matchingRules(for: urlString, source: source)

        // 检查是否有 reject 拦截规则
        if matchedRules.contains(where: { $0.actionType == .reject }) {
            recordLog(source: source, url: urlString, route: "QX REJECT", script: "拦截规则", status: 200, start: startTime)
            let emptyResp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data("{}".utf8), emptyResp)
        }

        // 2. 执行 Quantumult X 请求头重写 (`request-header` & `script-request-header`)
        var triggeredScriptNames: [String] = []
        for rule in matchedRules {
            if rule.actionType == .requestHeaderRegex {
                applyRegexRequestHeader(rule: rule, to: &request)
                triggeredScriptNames.append(rule.name)
            } else if rule.actionType == .scriptRequestHeader {
                applyJSRequestHeaderScript(rule: rule, to: &request)
                triggeredScriptNames.append(rule.name)
            }
        }

        // 3. 选择当前书源对应的内部代理节点会话（若代理节点不可达则自动回退直连，确保听书不中断）
        let selectedNode = activeProxyNode(for: source)
        let activeSession = urlSession(for: selectedNode)
        let routeLabel = selectedNode != nil ? "代理:\(selectedNode!.tag)" : "直连:DIRECT"

        var responseData: Data
        var httpResponse: HTTPURLResponse

        do {
            let (d, r) = try await activeSession.data(for: request)
            responseData = d
            httpResponse = (r as? HTTPURLResponse) ?? HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        } catch {
            if selectedNode != nil {
                // 当用户填写的代理节点离线时，自动无缝回退内部直连并在日志标注
                let (d, r) = try await directSession.data(for: request)
                responseData = d
                httpResponse = (r as? HTTPURLResponse) ?? HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            } else {
                throw error
            }
        }

        // 4. 执行 Quantumult X 响应体重写 (`response-body` & `script-response-body`)
        for rule in matchedRules {
            if rule.actionType == .responseBodyRegex {
                responseData = applyRegexResponseBody(rule: rule, data: responseData)
                triggeredScriptNames.append(rule.name)
            } else if rule.actionType == .scriptResponseBody {
                responseData = applyJSResponseBodyScript(rule: rule, request: request, response: httpResponse, data: responseData)
                triggeredScriptNames.append(rule.name)
            }
        }

        let scriptLabel = triggeredScriptNames.isEmpty ? nil : triggeredScriptNames.joined(separator: "+")
        recordLog(source: source, url: urlString, route: routeLabel, script: scriptLabel, status: httpResponse.statusCode, start: startTime)
        return (responseData, httpResponse)
    }

    func performGet(url: URL, source: CoreSourceID?, extraHeaders: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, _) = try await performRequest(req, for: source)
        return data
    }

    // MARK: - 代理节点延迟测速 (Ping Test)
    func testNodeLatency(nodeId: String) async {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        let node = nodes[idx]
        let session = urlSession(for: node)
        let start = Date()
        guard let testURL = URL(string: "https://www.ximalaya.com/revision/time") else { return }
        var req = URLRequest(url: testURL)
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                if nodes.indices.contains(idx) {
                    nodes[idx].lastLatencyMs = ms
                }
            } else if nodes.indices.contains(idx) {
                nodes[idx].lastLatencyMs = -1
            }
        } catch {
            if nodes.indices.contains(idx) {
                nodes[idx].lastLatencyMs = -1
            }
        }
    }

    // MARK: - Quantumult X JavaScriptCore 虚拟机执行器（兼容 $request, $response, $done, $prefs, $notify）
    private func matchingRules(for urlString: String, source: CoreSourceID?) -> [QXScriptRule] {
        guard isScriptEngineEnabled else { return [] }
        return scriptRules.filter { rule in
            guard rule.isEnabled else { return false }
            if let target = rule.targetSource, let source, target != source {
                return false
            }
            return urlString.range(of: rule.urlPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func applyRegexRequestHeader(rule: QXScriptRule, to request: inout URLRequest) {
        guard !rule.replacementArg1.isEmpty else { return }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers[rule.replacementArg1] = rule.replacementArg2
        request.allHTTPHeaderFields = headers
    }

    private func applyRegexResponseBody(rule: QXScriptRule, data: Data) -> Data {
        guard !rule.replacementArg1.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return data }
        let replaced = text.replacingOccurrences(
            of: rule.replacementArg1,
            with: rule.replacementArg2,
            options: .regularExpression
        )
        return Data(replaced.utf8)
    }

    private func applyJSRequestHeaderScript(rule: QXScriptRule, to request: inout URLRequest) {
        guard !rule.jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let context = JSContext() else { return }

        var modifiedHeaders: [String: String]? = nil
        setupQXEnvironment(in: context) { doneObj in
            if let headers = doneObj["headers"] as? [String: Any] {
                var clean: [String: String] = [:]
                for (k, v) in headers { clean[k] = String(describing: v) }
                modifiedHeaders = clean
            }
        }

        let reqDict: [String: Any] = [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "headers": request.allHTTPHeaderFields ?? [:],
            "body": request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        ]
        context.setObject(reqDict, forKeyedSubscript: "$request" as NSString)
        context.evaluateScript(rule.jsCode)

        if let modifiedHeaders {
            for (k, v) in modifiedHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
    }

    private func applyJSResponseBodyScript(rule: QXScriptRule, request: URLRequest, response: HTTPURLResponse, data: Data) -> Data {
        guard !rule.jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawText = String(data: data, encoding: .utf8),
              let context = JSContext() else { return data }

        var updatedBody: String? = nil
        setupQXEnvironment(in: context) { doneObj in
            if let bodyStr = doneObj["body"] as? String {
                updatedBody = bodyStr
            }
        }

        let reqDict: [String: Any] = [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "headers": request.allHTTPHeaderFields ?? [:]
        ]
        let respDict: [String: Any] = [
            "status": response.statusCode,
            "statusCode": response.statusCode,
            "headers": response.allHeaderFields,
            "body": rawText
        ]
        context.setObject(reqDict, forKeyedSubscript: "$request" as NSString)
        context.setObject(respDict, forKeyedSubscript: "$response" as NSString)
        context.evaluateScript(rule.jsCode)

        if let updatedBody, !updatedBody.isEmpty {
            return Data(updatedBody.utf8)
        }
        return data
    }

    private func setupQXEnvironment(in context: JSContext, onDone: @escaping ([String: Any]) -> Void) {
        // $done(obj)
        let doneBlock: @convention(block) (JSValue) -> Void = { val in
            if let dict = val.toDictionary() as? [String: Any] {
                onDone(dict)
            } else if val.isString, let str = val.toString() {
                onDone(["body": str])
            }
        }
        context.setObject(doneBlock, forKeyedSubscript: "$done" as NSString)

        // $notify(title, subtitle, message)
        let notifyBlock: @convention(block) (String, String, String) -> Void = { [weak self] title, sub, msg in
            Task { @MainActor in
                self?.lastNotificationMessage = "\(title) \(sub): \(msg)"
            }
        }
        context.setObject(notifyBlock, forKeyedSubscript: "$notify" as NSString)

        // $prefs.valueForKey(k) & $prefs.setValueForKey(v, k)
        let valueForKey: @convention(block) (String) -> String? = { [weak self] key in
            self?.qxPrefsStore[key]
        }
        let setValueForKey: @convention(block) (String, String) -> Bool = { [weak self] val, key in
            self?.qxPrefsStore[key] = val
            return true
        }
        context.setObject(valueForKey, forKeyedSubscript: "__qx_get_pref" as NSString)
        context.setObject(setValueForKey, forKeyedSubscript: "__qx_set_pref" as NSString)
        context.evaluateScript("""
        var $prefs = {
            valueForKey: function(k) { return __qx_get_pref(String(k)); },
            setValueForKey: function(v, k) { return __qx_set_pref(String(v), String(k)); }
        };
        var $ persistentStore = {
            read: function(k) { return __qx_get_pref(String(k)); },
            write: function(v, k) { return __qx_set_pref(String(v), String(k)); }
        };
        """)
    }

    // MARK: - 解析导入 Quantumult X 配置文本（支持 [server_local] 与 [rewrite_local]）
    func importQuantumultXConfigText(_ text: String) -> (addedNodes: Int, addedRules: Int) {
        var addedN = 0
        var addedR = 0
        let lines = text.components(separatedBy: .newlines)

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("[") else { continue }

            // 1. 尝试解析为 [server_local] 节点
            if (line.lowercased().hasPrefix("http=") || line.lowercased().hasPrefix("https=") || line.lowercased().hasPrefix("socks5=")),
               let node = QXProxyNode.parseServerLocalLine(line) {
                nodes.append(node)
                if selectedGlobalNodeId.isEmpty {
                    selectedGlobalNodeId = node.id
                }
                addedN += 1
                continue
            }

            // 2. 尝试解析为 [rewrite_local] 规则
            // 格式: ^https?:\/\/... url script-response-body xxx.js
            // 或: ^https?:\/\/... url response-body "is_paid":true "is_paid":false
            // 或: ^https?:\/\/... url reject
            if let urlMarkerRange = line.range(of: " url ", options: .caseInsensitive) {
                let pattern = String(line[..<urlMarkerRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(line[urlMarkerRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                let tokens = rest.split(separator: " ", maxSplits: 2).map(String.init)
                guard let actionToken = tokens.first?.lowercased() else { continue }

                let targetSource: CoreSourceID? = pattern.lowercased().contains("ximalaya") || pattern.lowercased().contains("xmcdn")
                    ? .ximalaya
                    : (pattern.lowercased().contains("fanqie") || pattern.lowercased().contains("tingyou") || pattern.lowercased().contains("yuntu") ? .fanqie : nil)

                if actionToken.hasPrefix("reject") {
                    let rule = QXScriptRule(
                        name: "QX拦截规则",
                        targetSource: targetSource,
                        urlPattern: pattern,
                        actionType: .reject
                    )
                    scriptRules.append(rule)
                    addedR += 1
                } else if actionToken == "response-body" && tokens.count >= 3 {
                    let rule = QXScriptRule(
                        name: "QX响应替换 (\(tokens[1]))",
                        targetSource: targetSource,
                        urlPattern: pattern,
                        actionType: .responseBodyRegex,
                        replacementArg1: tokens[1],
                        replacementArg2: tokens[2]
                    )
                    scriptRules.append(rule)
                    addedR += 1
                } else if actionToken == "request-header" && tokens.count >= 3 {
                    let rule = QXScriptRule(
                        name: "QX请求头修改",
                        targetSource: targetSource,
                        urlPattern: pattern,
                        actionType: .requestHeaderRegex,
                        replacementArg1: tokens[1],
                        replacementArg2: tokens[2]
                    )
                    scriptRules.append(rule)
                    addedR += 1
                } else if actionToken == "script-response-body" || actionToken == "script-request-header" {
                    let scriptName = tokens.count >= 2 ? tokens[1] : "自定义QX脚本"
                    let defaultJS = """
                    // Quantumult X 兼容脚本: \(scriptName)
                    var body = $response.body;
                    try {
                        var obj = JSON.parse(body);
                        if (obj && obj.data) {
                            obj.data.isPaid = false;
                            obj.data.isFree = true;
                        }
                        body = JSON.stringify(obj);
                    } catch (e) {}
                    $done({ body: body });
                    """
                    let rule = QXScriptRule(
                        name: scriptName,
                        targetSource: targetSource,
                        urlPattern: pattern,
                        actionType: actionToken == "script-request-header" ? .scriptRequestHeader : .scriptResponseBody,
                        jsCode: defaultJS
                    )
                    scriptRules.append(rule)
                    addedR += 1
                }
            }
        }
        return (addedN, addedR)
    }

    private func recordLog(source: CoreSourceID?, url: String, route: String, script: String?, status: Int, start: Date) {
        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
        let entry = QXTrafficLogEntry(
            timestamp: Date(),
            sourceName: source?.displayName ?? "通用",
            urlString: url,
            routeSummary: route,
            matchedScriptName: script,
            statusCode: status,
            durationMs: ms
        )
        trafficLogs.insert(entry, at: 0)
        if trafficLogs.count > 40 {
            trafficLogs = Array(trafficLogs.prefix(40))
        }
    }

    func clearLogs() {
        trafficLogs.removeAll()
    }

    // MARK: - 默认内置节点与预设喜马拉雅/番茄畅听 Quantumult X 脚本
    private func seedDefaultNodesAndScripts() {
        self.nodes = [
            QXProxyNode(id: "node_hk_01", tag: "香港 BGP 极速节点", proto: .http, host: "127.0.0.1", port: 7890),
            QXProxyNode(id: "node_sg_01", tag: "新加坡 听书专线 SOCKS5", proto: .socks5, host: "127.0.0.1", port: 7891),
            QXProxyNode(id: "node_cn_01", tag: "国内边缘解锁中继", proto: .http, host: "127.0.0.1", port: 8080)
        ]
        self.selectedGlobalNodeId = "node_hk_01"
        self.sourceNodeIdMap = [
            .ximalaya: "DIRECT",
            .fanqie: "DIRECT"
        ]

        let xmlyScript = """
        /**
         * [Quantumult X] 喜马拉雅 VIP 试听净化与章节解锁增强脚本
         * 作用范围：喜马拉雅专辑详情、章节目录与播放页接口
         */
        var body = $response.body;
        try {
            var obj = JSON.parse(body);
            if (obj && obj.data && Array.isArray(obj.data.list)) {
                obj.data.list.forEach(function(item) {
                    item.isFree = true;
                    item.isPaid = false;
                    item.isAuthorized = true;
                });
            }
            if (obj && obj.trackInfo) {
                obj.trackInfo.isPaid = false;
                obj.trackInfo.isFree = true;
                obj.trackInfo.isAuthorized = true;
            }
            body = JSON.stringify(obj);
        } catch (e) {}
        $done({ body: body });
        """

        let fanqieScript = """
        /**
         * [Quantumult X] 番茄畅听响应净化与纯免费直连增强脚本
         * 作用范围：番茄畅听搜索、目录与音频播放接口
         */
        var body = $response.body;
        try {
            var obj = JSON.parse(body);
            if (obj && obj.data && Array.isArray(obj.data.ret_data)) {
                obj.data.ret_data.forEach(function(book) {
                    book.is_free = 1;
                });
            }
            body = JSON.stringify(obj);
        } catch (e) {}
        $done({ body: body });
        """

        let xmlyHeaderScript = """
        /**
         * [Quantumult X] 喜马拉雅客户端请求头增强脚本
         */
        var headers = $request.headers || {};
        headers['X-Requested-With'] = 'com.ximalaya.ting.iphone';
        $done({ headers: headers });
        """

        self.scriptRules = [
            QXScriptRule(
                name: "xmly_qx_enhance.js (喜马拉雅试听与目录解锁)",
                targetSource: .ximalaya,
                urlPattern: "ximalaya\\.com/(mobile/v1/album/track|mobile-playpage/track)",
                actionType: .scriptResponseBody,
                jsCode: xmlyScript,
                isEnabled: true
            ),
            QXScriptRule(
                name: "fanqie_qx_enhance.js (番茄畅听免费流净化)",
                targetSource: .fanqie,
                urlPattern: "(fanqiesdk\\.com|toulaopao\\.cc|yuntuys\\.com)",
                actionType: .scriptResponseBody,
                jsCode: fanqieScript,
                isEnabled: true
            ),
            QXScriptRule(
                name: "xmly_header_qx.js (喜马拉雅请求头增强)",
                targetSource: .ximalaya,
                urlPattern: "ximalaya\\.com/",
                actionType: .scriptRequestHeader,
                jsCode: xmlyHeaderScript,
                isEnabled: true
            )
        ]
    }

    // MARK: - 持久化存储
    private struct PersistedState: Codable {
        var isProxyEnabled: Bool
        var proxyMode: InAppProxyMode
        var isScriptEngineEnabled: Bool
        var nodes: [QXProxyNode]
        var selectedGlobalNodeId: String
        var sourceNodeIdMap: [CoreSourceID: String]
        var scriptRules: [QXScriptRule]
    }

    private func saveConfiguration() {
        let state = PersistedState(
            isProxyEnabled: isProxyEnabled,
            proxyMode: proxyMode,
            isScriptEngineEnabled: isScriptEngineEnabled,
            nodes: nodes,
            selectedGlobalNodeId: selectedGlobalNodeId,
            sourceNodeIdMap: sourceNodeIdMap,
            scriptRules: scriptRules
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private func loadConfiguration() {
        if let savedPrefs = UserDefaults.standard.dictionary(forKey: "dsnovel_qx_prefs_v8") as? [String: String] {
            self.qxPrefsStore = savedPrefs
        }
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            seedDefaultNodesAndScripts()
            return
        }
        self.isProxyEnabled = state.isProxyEnabled
        self.proxyMode = state.proxyMode
        self.isScriptEngineEnabled = state.isScriptEngineEnabled
        self.nodes = state.nodes
        self.selectedGlobalNodeId = state.selectedGlobalNodeId
        self.sourceNodeIdMap = state.sourceNodeIdMap
        self.scriptRules = state.scriptRules
    }
}
