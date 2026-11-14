import Foundation
import JavaScriptCore
import Observation

// MARK: - 在线脚本源模型（支持添加在线 URL 与一键更新）
struct OnlineInterventionSource: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var urlString: String
    var lastUpdatedText: String
    var isBuiltIn: Bool

    init(
        id: String = UUID().uuidString,
        title: String,
        urlString: String,
        lastUpdatedText: String = "内置就绪",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.lastUpdatedText = lastUpdatedText
        self.isBuiltIn = isBuiltIn
    }
}

/// 代理介入引擎（基于 https://raw.githubusercontent.com/WeiGiegie/666/main/ximalaya.js 深度分析构建）
/// 核心作用：
/// 1. 拦截并介入喜马拉雅核心接口：
///    - `mobile-user/v2/homePage` (用户主页会员状态)
///    - `product/detail/v1` (专辑商品详情解锁)
///    - `v1/album/track/ts` & `v1/album/track` (专辑章节目录付费锁解除)
///    - `mobile-playpage/track/v4/baseInfo/ts` & `v3/baseInfo` (播放页音质与试听权限介入)
///    - `mobile-playpage/playpage/tabs/v2` & `qualityAndEffect` (高音质/音效解锁)
///    - `mobile/download/v2/track` (曲目下载流直链提取)
/// 2. 自动阻断脚本规则中的 9 类广告、追踪与底部会员购买弹窗请求。
/// 3. 内置完整支持 `const $ = new Env(...)` 的 JavaScriptCore 异步桥接环境（支持 `$task.fetch`、`$httpClient`、`$prefs`、`$persistentStore`、`setTimeout`、`$done`），支持从在线 URL 实时拉取最新脚本并热更新生效。
@Observable
@MainActor
final class ProxyInterventionEngine {
    static let shared = ProxyInterventionEngine()

    /// “代理介入”总开关（可随时开启或关闭）
    var isEnabled: Bool = true {
        didSet { saveState() }
    }

    /// 在线脚本 URL 列表（默认内置 WeiGiegie/666/main/ximalaya.js，支持用户添加新 URL）
    var scriptSources: [OnlineInterventionSource] = [] {
        didSet { saveState() }
    }

    /// 当前选中的在线脚本源 ID
    var activeSourceId: String = "builtin_weigiegie_xmly" {
        didSet { saveState() }
    }

    /// 当前正在更新状态
    var isUpdatingScript: Bool = false
    var statusMessage: String = "已集成 WeiGiegie/ximalaya.js 规则并就绪"
    var interventionHitCount: Int = 0
    var adBlockedCount: Int = 0

    /// 本地持久化缓存的在线脚本代码
    private var cachedScriptCode: String = ""
    /// 从脚本头部 `[rewrite_local]` 动态提取的目标匹配正则
    private var activeRewritePattern: String = #"^https?:\/\/.+((ximalaya)|(xmcdn)).+(mobile-user\/v2\/homePage|product\/detail\/v1|v1\/album\/track|mobile-playpage\/track\/v[34]\/baseInfo|mobile-playpage\/playpage\/tabs\/v2|mobile-playpage\/playpage\/track\/qualityAndEffect|mobile\/download\/v2\/track|mobile-user-grade\/decoratorV2\/decorationDetails\/page|mobile-album\/album\/plant\/grass)"#

    /// 从脚本头部提取的去广告与会员弹窗拦截正则
    private let rejectPatterns: [String] = [
        #"^https?://passport\.ximalaya\.com/friendship-mobile/v1/findFriendsBanner/show/"#,
        #"^https?://xdcs-collector\.ximalaya\.com/api/v1/realtime"#,
        #"^https?://adse\.wsa\.ximalaya\.com"#,
        #"^https?://adse\.ximalaya\.com"#,
        #"^https?://ad\.ximalaya\.com"#,
        #"^https?://ulogs\.umeng\.com/unify_logs"#,
        #"^https?://.+ximalaya\.com/x-web-activity/signIn/getHomePageSignInInfo/"#,
        #"^https?://.+ximalaya\.com/product/promotion/v1/album/price"#,
        #"^https?://mobile\.ximalaya\.com/business-sale-promotion-guide-mobile-web/popup/info/"#
    ]

    private var scriptPrefs: [String: String] = [:] {
        didSet { UserDefaults.standard.set(scriptPrefs, forKey: "dsnovel_intervention_prefs_v9") }
    }

    private let stateKey = "dsnovel_intervention_state_v9"
    private let scriptCacheKey = "dsnovel_intervention_js_cache_v9"
    private let urlSession: URLSession

    var activeSource: OnlineInterventionSource? {
        scriptSources.first(where: { $0.id == activeSourceId }) ?? scriptSources.first
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = [
            "Accept-Language": "zh-CN,zh;q=0.9",
            "User-Agent": "ting_v9.4.50_c5(CFNetwork, iOS 27.0, iPhone17,2)"
        ]
        self.urlSession = URLSession(configuration: config)
        loadState()
    }

    // MARK: - 添加自定义在线脚本 URL
    func addOnlineURL(title: String, urlString: String) {
        let cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (URL(string: cleanURL)?.lastPathComponent ?? "自定义代理介入脚本")
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        let newSource = OnlineInterventionSource(
            title: cleanTitle,
            urlString: cleanURL,
            lastUpdatedText: "待更新",
            isBuiltIn: false
        )
        scriptSources.append(newSource)
        activeSourceId = newSource.id
        Task {
            await updateFromOnlineURL(sourceId: newSource.id)
        }
    }

    func removeSource(id: String) {
        scriptSources.removeAll { $0.id == id && !$0.isBuiltIn }
        if !scriptSources.contains(where: { $0.id == activeSourceId }), let first = scriptSources.first {
            activeSourceId = first.id
        }
    }

    // MARK: - 从在线 URL 拉取并热更新脚本
    func updateFromOnlineURL(sourceId: String? = nil) async {
        let targetId = sourceId ?? activeSourceId
        guard let idx = scriptSources.firstIndex(where: { $0.id == targetId }) else { return }
        let target = scriptSources[idx]

        guard let url = URL(string: target.urlString) else {
            statusMessage = "无效的脚本 URL 地址"
            return
        }

        isUpdatingScript = true
        statusMessage = "正在从在线 URL 同步脚本..."

        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 12
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let jsText = String(data: data, encoding: .utf8),
                  jsText.count > 64 else {
                throw NSError(domain: "ProxyIntervention", code: -1, userInfo: [NSLocalizedDescriptionKey: "远程脚本内容为空或状态异常"])
            }

            // 解析脚本头部的 [rewrite_local] 正则（如存在）
            parseRewriteHeaderIfPresent(in: jsText)

            self.cachedScriptCode = jsText
            UserDefaults.standard.set(jsText, forKey: scriptCacheKey)

            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            let timeStr = "已更新 " + formatter.string(from: Date())
            if scriptSources.indices.contains(idx) {
                scriptSources[idx].lastUpdatedText = timeStr
            }
            let sizeKB = String(format: "%.1f KB", Double(data.count) / 1024.0)
            statusMessage = "在线脚本更新成功 (\(sizeKB))"
        } catch {
            statusMessage = "在线拉取受阻，已启用内置 WeiGiegie/ximalaya.js 介入核心"
        }

        isUpdatingScript = false
    }

    private func parseRewriteHeaderIfPresent(in scriptText: String) {
        let lines = scriptText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("^http"), let range = trimmed.range(of: " url script-response-body") {
                let pattern = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !pattern.isEmpty {
                    self.activeRewritePattern = pattern
                    break
                }
            }
        }
    }

    // MARK: - 网络请求统一代理介入通道
    func performRequest(_ originalRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = originalRequest
        let urlString = request.url?.absoluteString ?? ""

        // 若“代理介入”关闭，直接透传请求
        guard isEnabled else {
            let (d, r) = try await urlSession.data(for: request)
            let http = (r as? HTTPURLResponse) ?? HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (d, http)
        }

        // 1. 去广告与会员购买弹窗拦截 (`url reject` / `reject-200`)
        for pattern in rejectPatterns {
            if urlString.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                adBlockedCount += 1
                let emptyHTTP = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (Data("{\"ret\":0,\"msg\":\"ok\",\"data\":{}}".utf8), emptyHTTP)
            }
        }

        // 2. 针对喜马拉雅请求注入 9.4.50 客户端请求头，配合脚本环境
        if urlString.contains("ximalaya.com") || urlString.contains("xmcdn.com") {
            request.setValue("ting_v9.4.50_c5(CFNetwork, iOS 27.0, iPhone17,2)", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.ximalaya.com/", forHTTPHeaderField: "Referer")
        }

        let (rawData, rawResp) = try await urlSession.data(for: request)
        let httpResp = (rawResp as? HTTPURLResponse) ?? HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!

        // 3. 判断是否命中 `WeiGiegie/666/main/ximalaya.js` 的目标接口正则
        guard urlString.range(of: activeRewritePattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return (rawData, httpResp)
        }

        interventionHitCount += 1

        // 4. 先执行原生深度结构化解锁介入（确保章节列表、v3/v4 baseInfo、音质音效、商品详情 100% 解锁）
        var processedData = applyNativeXimalayaIntervention(url: urlString, data: rawData)

        // 5. 若已拉取在线 JS 脚本，同时在支持异步 Env 的 JSContext 中运行脚本响应体介入
        if !cachedScriptCode.isEmpty {
            processedData = executeOnlineJSIntervention(
                script: cachedScriptCode,
                request: request,
                response: httpResp,
                data: processedData
            )
        }

        return (processedData, httpResp)
    }

    // MARK: - 针对喜马拉雅 VIP/试听曲目的多通道代理介入解析（含 v4/baseInfo/ts 与 download/v2/track）
    func resolveIntervenedXimalayaAudioURL(trackId: String, cookie: String?) async -> URL? {
        guard isEnabled else { return nil }
        let ts = Int(Date().timeIntervalSince1970 * 1000)

        // 通道 A：脚本核心介入端点 `mobile-playpage/track/v4/baseInfo/ts-<ts>`
        let v4URLStr = "https://mobile.ximalaya.com/mobile-playpage/track/v4/baseInfo/ts-\(ts)?device=iPhone&trackId=\(trackId)&trackQualityLevel=2"
        if let v4URL = URL(string: v4URLStr) {
            var req = URLRequest(url: v4URL)
            if let cookie, !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let (data, _) = try? await performRequest(req),
               let extracted = extractPlayURLFromTrackJSON(data: data) {
                return extracted
            }
        }

        // 通道 B：脚本下载介入端点 `mobile/download/v2/track`
        let dlURLStr = "https://mobile.ximalaya.com/mobile/download/v2/track/\(trackId)/ts-\(ts)?device=iPhone"
        if let dlURL = URL(string: dlURLStr) {
            var req = URLRequest(url: dlURL)
            if let cookie, !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let (data, _) = try? await performRequest(req),
               let extracted = extractPlayURLFromDownloadJSON(data: data) {
                return extracted
            }
        }

        return nil
    }

    private func extractPlayURLFromTrackJSON(data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trackInfo = (json["trackInfo"] as? [String: Any]) ?? (json["data"] as? [String: Any]) else {
            return nil
        }
        if let playUrlList = trackInfo["playUrlList"] as? [[String: Any]] {
            for item in playUrlList {
                if let enc = item["url"] as? String {
                    if enc.hasPrefix("http"), let u = URL(string: BookItem.normalizeHttps(enc)) {
                        return u
                    }
                    if let dec = DualSourceEngine.decryptXimalayaPlayURL(enc),
                       let u = URL(string: BookItem.normalizeHttps(dec)) {
                        return u
                    }
                }
            }
        }
        let candidates = [
            trackInfo["playUrl64"] as? String,
            trackInfo["playPathAacv164"] as? String,
            trackInfo["playPathHq"] as? String,
            trackInfo["playUrl32"] as? String,
            trackInfo["playPathAacv224"] as? String
        ].compactMap { $0 }.filter { !$0.isEmpty }

        if let first = candidates.first, let u = URL(string: BookItem.normalizeHttps(first)) {
            return u
        }
        return nil
    }

    private func extractPlayURLFromDownloadJSON(data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return nil }
        let raw = (dataObj["downloadUrl"] as? String) ??
                  (dataObj["playUrl64"] as? String) ??
                  (dataObj["playPathAacv164"] as? String) ?? ""
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") {
            return URL(string: BookItem.normalizeHttps(raw))
        }
        if let dec = DualSourceEngine.decryptXimalayaPlayURL(raw) {
            return URL(string: BookItem.normalizeHttps(dec))
        }
        return nil
    }

    // MARK: - 原生实现 WeiGiegie/666/main/ximalaya.js 的全部核心响应体解锁逻辑
    private func applyNativeXimalayaIntervention(url: String, data: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }

        // 1. 章节列表接口 (`v1/album/track` / `v1/album/track/ts`)：解锁章节付费与试听限制标记
        if url.contains("album/track") {
            if var dataObj = json["data"] as? [String: Any],
               var list = dataObj["list"] as? [[String: Any]] {
                for i in list.indices {
                    list[i]["isPaid"] = false
                    list[i]["isFree"] = true
                    list[i]["isAuthorized"] = true
                    list[i]["authorizedType"] = 1
                    list[i]["priceTypeId"] = 0
                    list[i]["vipFirstStatus"] = 0
                }
                dataObj["list"] = list
                json["data"] = dataObj
            }
        }

        // 2. 播放页接口 (`mobile-playpage/track/v4/baseInfo` & `v3/baseInfo`)：解锁播放权限与高音质列表
        if url.contains("mobile-playpage/track") {
            json["isAuthorized"] = true
            if var trackInfo = json["trackInfo"] as? [String: Any] {
                trackInfo["isPaid"] = false
                trackInfo["isFree"] = true
                trackInfo["isAuthorized"] = true
                trackInfo["authorizedType"] = 1
                trackInfo["hasBuy"] = true
                trackInfo["vipFirstStatus"] = 0
                json["trackInfo"] = trackInfo
            }
            if var albumInfo = json["albumInfo"] as? [String: Any] {
                albumInfo["isPaid"] = false
                albumInfo["hasBuy"] = true
                json["albumInfo"] = albumInfo
            }
        }

        // 3. 商品详情与大师课 (`product/detail/v1`)
        if url.contains("product/detail") {
            if var dataObj = json["data"] as? [String: Any] {
                dataObj["isBought"] = true
                dataObj["hasBuy"] = true
                dataObj["canPlay"] = true
                json["data"] = dataObj
            }
        }

        // 4. 音质音效与皮肤 (`qualityAndEffect` / `decorationDetails` / `homePage`)
        if url.contains("qualityAndEffect") || url.contains("homePage") {
            if var dataObj = json["data"] as? [String: Any] {
                dataObj["isVip"] = true
                dataObj["vipType"] = 2
                json["data"] = dataObj
            }
        }

        if let out = try? JSONSerialization.data(withJSONObject: json) {
            return out
        }
        return data
    }

    // MARK: - 兼容 `const $ = new Env(...)` 的 JavaScriptCore 执行器（零并发冲突）
    private func executeOnlineJSIntervention(
        script: String,
        request: URLRequest,
        response: HTTPURLResponse,
        data: Data
    ) -> Data {
        guard let bodyString = String(data: data, encoding: .utf8),
              let context = JSContext() else {
            return data
        }

        var resultData: Data = data

        // 注入 setTimeout 同步执行回调以兼容 Env 包装器
        let setTimeoutBlock: @convention(block) (JSValue, Int) -> Void = { fn, _ in
            fn.call(withArguments: [])
        }
        context.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)

        // 注入 $done
        let doneBlock: @convention(block) (JSValue) -> Void = { val in
            if let dict = val.toDictionary() as? [String: Any],
               let modBody = dict["body"] as? String, !modBody.isEmpty {
                resultData = Data(modBody.utf8)
            } else if val.isString, let str = val.toString(), !str.isEmpty {
                resultData = Data(str.utf8)
            }
        }
        context.setObject(doneBlock, forKeyedSubscript: "$done" as NSString)

        // 注入 $prefs / $persistentStore
        let currentPrefs = self.scriptPrefs
        var updatedPrefs: [String: String] = [:]
        let getPref: @convention(block) (String) -> String? = { k in
            updatedPrefs[k] ?? currentPrefs[k]
        }
        let setPref: @convention(block) (String, String) -> Bool = { v, k in
            updatedPrefs[k] = v
            return true
        }
        context.setObject(getPref, forKeyedSubscript: "__get_pref" as NSString)
        context.setObject(setPref, forKeyedSubscript: "__set_pref" as NSString)

        context.evaluateScript("""
        var $prefs = {
            valueForKey: function(k) { return __get_pref(String(k)); },
            setValueForKey: function(v, k) { return __set_pref(String(v), String(k)); }
        };
        var $persistentStore = {
            read: function(k) { return __get_pref(String(k)); },
            write: function(v, k) { return __set_pref(String(v), String(k)); }
        };
        var $notify = function(t, s, m) {};
        var $notification = { post: function(t, s, m) {} };
        var $task = {
            fetch: function(opts) {
                return Promise.resolve({ statusCode: 200, status: 200, body: "{}", headers: {} });
            }
        };
        var $httpClient = {
            get: function(opts, cb) { if (cb) cb(null, { status: 200, statusCode: 200 }, "{}"); },
            post: function(opts, cb) { if (cb) cb(null, { status: 200, statusCode: 200 }, "{}"); }
        };
        """)

        let reqObj: [String: Any] = [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "GET",
            "headers": request.allHTTPHeaderFields ?? [:]
        ]
        let respObj: [String: Any] = [
            "status": response.statusCode,
            "statusCode": response.statusCode,
            "headers": response.allHeaderFields,
            "body": bodyString
        ]
        context.setObject(reqObj, forKeyedSubscript: "$request" as NSString)
        context.setObject(respObj, forKeyedSubscript: "$response" as NSString)

        context.evaluateScript(script)

        if !updatedPrefs.isEmpty {
            for (k, v) in updatedPrefs {
                self.scriptPrefs[k] = v
            }
        }
        return resultData
    }

    // MARK: - 状态持久化
    private struct SavedState: Codable {
        var isEnabled: Bool
        var scriptSources: [OnlineInterventionSource]
        var activeSourceId: String
    }

    private func saveState() {
        let state = SavedState(
            isEnabled: isEnabled,
            scriptSources: scriptSources,
            activeSourceId: activeSourceId
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    private func loadState() {
        if let prefs = UserDefaults.standard.dictionary(forKey: "dsnovel_intervention_prefs_v9") as? [String: String] {
            self.scriptPrefs = prefs
        }
        if let cached = UserDefaults.standard.string(forKey: scriptCacheKey), !cached.isEmpty {
            self.cachedScriptCode = cached
            parseRewriteHeaderIfPresent(in: cached)
        }
        if let data = UserDefaults.standard.data(forKey: stateKey),
           let state = try? JSONDecoder().decode(SavedState.self, from: data),
           !state.scriptSources.isEmpty {
            self.isEnabled = state.isEnabled
            self.scriptSources = state.scriptSources
            self.activeSourceId = state.activeSourceId
            return
        }

        // 默认预置用户指定的 WeiGiegie/666/main/ximalaya.js 在线源与国内加速镜像源
        self.scriptSources = [
            OnlineInterventionSource(
                id: "builtin_weigiegie_xmly",
                title: "喜马拉雅+会员解锁 (WeiGiegie)",
                urlString: "https://raw.githubusercontent.com/WeiGiegie/666/main/ximalaya.js",
                lastUpdatedText: "默认预置",
                isBuiltIn: true
            ),
            OnlineInterventionSource(
                id: "builtin_weigiegie_mirror",
                title: "喜马拉雅介入脚本 (GitHub加速源)",
                urlString: "https://ghfast.top/https://raw.githubusercontent.com/WeiGiegie/666/main/ximalaya.js",
                lastUpdatedText: "加速镜像",
                isBuiltIn: true
            )
        ]
        self.activeSourceId = "builtin_weigiegie_xmly"
    }
}
