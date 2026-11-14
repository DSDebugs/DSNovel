import Foundation
import Observation

// MARK: - 在线配置数据源模型（URL 仅作为关键参数与网关数据源）
struct DebugDataSourceItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var urlString: String
    var lastSyncedText: String
    var isBuiltIn: Bool

    init(
        id: String = UUID().uuidString,
        title: String,
        urlString: String,
        lastSyncedText: String = "内置就绪",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.lastSyncedText = lastSyncedText
        self.isBuiltIn = isBuiltIn
    }
}

/// DSNovel v11.0 原生“调试功能”引擎 (`SourceDebugEngine`)
/// 核心设计：
/// 1. 彻底移除沉重的 `JavaScriptCore` 虚拟机与阻塞式脚本执行，所有逻辑 100% 由客户端 Swift 原生实现，接口请求零额外延迟。
/// 2. 在线 URL 仅作为轻量级配置与接口元数据更新源：读取在线文本中的有效网关域名、客户端版本号标识（如 `9.4.50`）与音频流路由参数，自动忽略冗余的广告规则与无效代码。
/// 3. 内置两大客户端原生调试能力：
///    - 接口参数与请求头自适应调试 (`endpointTuningEnabled`)
///    - 章节音源多通道智能优选 (`streamFallbackTuningEnabled`)
@Observable
@MainActor
final class SourceDebugEngine {
    static let shared = SourceDebugEngine()

    /// “调试功能”总开关
    var isEnabled: Bool = true {
        didSet { saveState() }
    }

    /// 原生集成项 1：接口参数与客户端标识调试
    var endpointTuningEnabled: Bool = true {
        didSet { saveState() }
    }

    /// 原生集成项 2：章节多通道音源智能优选与回退
    var streamFallbackTuningEnabled: Bool = true {
        didSet { saveState() }
    }

    /// 在线数据源 URL 列表（仅作关键数据读取与配置同步源）
    var dataSources: [DebugDataSourceItem] = [] {
        didSet { saveState() }
    }

    var activeSourceId: String = "builtin_primary_source" {
        didSet { saveState() }
    }

    var isSyncingData: Bool = false
    var statusSummary: String = "客户端原生调试引擎已就绪"
    var syncedClientVersion: String = "9.4.50"
    var syncedHostCount: Int = 6
    var optimizedRequestCount: Int = 0

    /// 从在线数据源提取出的有效音频与接口域名集合
    private var extractedHosts: [String] = [
        "mobile.ximalaya.com",
        "mobwsa.ximalaya.com",
        "www.ximalaya.com",
        "search.ximalaya.com",
        "api.fanqiesdk.com",
        "open-service.yuntuys.com"
    ]

    private let stateKey = "dsnovel_source_debug_state_v11"
    private let urlSession: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 16
        config.requestCachePolicy = .useProtocolCachePolicy
        self.urlSession = URLSession(configuration: config)
        loadState()
    }

    // MARK: - 添加与删除在线数据源 URL
    func addOnlineDataURL(title: String, urlString: String) {
        let cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (URL(string: cleanURL)?.lastPathComponent ?? "自定义调试数据源")
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        let item = DebugDataSourceItem(
            title: cleanTitle,
            urlString: cleanURL,
            lastSyncedText: "待同步",
            isBuiltIn: false
        )
        dataSources.append(item)
        activeSourceId = item.id
        Task {
            await syncKeyDataFromURL(sourceId: item.id)
        }
    }

    func removeDataSource(id: String) {
        dataSources.removeAll { $0.id == id && !$0.isBuiltIn }
        if !dataSources.contains(where: { $0.id == activeSourceId }), let first = dataSources.first {
            activeSourceId = first.id
        }
    }

    // MARK: - 从在线 URL 极速读取关键配置数据（仅提取版本号、端点路径与主机名，剔除冗余内容）
    func syncKeyDataFromURL(sourceId: String? = nil) async {
        let targetId = sourceId ?? activeSourceId
        guard let idx = dataSources.firstIndex(where: { $0.id == targetId }) else { return }
        let source = dataSources[idx]

        guard let url = URL(string: source.urlString) else {
            statusSummary = "数据源 URL 格式有误"
            return
        }

        isSyncingData = true
        statusSummary = "正在读取在线源关键参数..."

        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 8
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let rawText = String(data: data, encoding: .utf8), !rawText.isEmpty else {
                throw NSError(domain: "SourceDebug", code: -1, userInfo: nil)
            }

            // 仅解析关键配置数据（如软件版本号、有效域名与核心音频路径），忽略无关脚本体
            parseLightweightMetadata(from: rawText)

            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            if dataSources.indices.contains(idx) {
                dataSources[idx].lastSyncedText = "已同步 " + formatter.string(from: Date())
            }
            statusSummary = "已同步关键参数 (v\(syncedClientVersion) · \(syncedHostCount) 节点)"
        } catch {
            statusSummary = "使用内置高速参数 (v\(syncedClientVersion) · 原生直连)"
        }

        isSyncingData = false
    }

    private func parseLightweightMetadata(from text: String) {
        // 仅提取 VIP 解锁相关关键参数：软件版本号（用于 User-Agent 与客户端标识）
        if let verRange = text.range(of: #"软件版本[：:]\s*([0-9.]+)"#, options: .regularExpression) {
            let matched = String(text[verRange])
            let digits = matched.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
            if !digits.isEmpty {
                self.syncedClientVersion = digits
            }
        }

        // 提取 [rewrite_local] 块中的核心 API 路径（仅 VIP 解锁相关，忽略 reject/reject-200 广告规则）
        let vipAPIPatterns = [
            "mobile-playpage/track/v4/baseInfo/ts",
            "mobile/download/v2/track",
            "v1/album/track/ts",
            "mobile-playpage/playpage/track/qualityAndEffect"
        ]
        var foundCount = 0
        for pattern in vipAPIPatterns {
            if text.contains(pattern) { foundCount += 1 }
        }
        if foundCount > 0 {
            self.syncedHostCount = foundCount
        }
    }

    // MARK: - 纯原生极速网络请求通道（零 JS 虚拟机开销）
    func performRequest(_ originalRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = originalRequest
        let urlString = request.url?.absoluteString ?? ""

        if isEnabled && endpointTuningEnabled {
            if urlString.contains("ximalaya.com") || urlString.contains("xmcdn.com") {
                request.setValue("ting_v\(syncedClientVersion)_c5(CFNetwork, iOS 27.0, iPhone17,2)", forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.ximalaya.com/", forHTTPHeaderField: "Referer")
                if request.value(forHTTPHeaderField: "Cookie") == nil,
                   let userCookie = DualSourceEngine.shared.customCookies[.ximalaya],
                   !userCookie.isEmpty {
                    request.setValue(userCookie, forHTTPHeaderField: "Cookie")
                }
                optimizedRequestCount += 1
            }
        }

        let (data, resp) = try await urlSession.data(for: request)
        let http = (resp as? HTTPURLResponse) ?? HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, http)
    }

    // MARK: - 客户端原生多通道音频流优选解析（VIP 全端点覆盖 + 多设备/多质量等级 + 三线回退）
    func resolveOptimizedXimalayaStream(
        trackId: String,
        book: BookItem,
        episode: EpisodeItem,
        cookie: String?
    ) async -> URL? {
        guard isEnabled else { return nil }
        let ts = Int(Date().timeIntervalSince1970 * 1000)

        // ── 第一梯队：高音质 v4 + v3（多设备 + 多质量等级） ──
        let tier1Endpoints: [String] = [
            // v4 — iPhone 高音质
            "https://mobile.ximalaya.com/mobile-playpage/track/v4/baseInfo/ts-\(ts)?device=iPhone&trackId=\(trackId)&trackQualityLevel=2",
            // v4 — iPad
            "https://mobile.ximalaya.com/mobile-playpage/track/v4/baseInfo/ts-\(ts)?device=iPad&trackId=\(trackId)&trackQualityLevel=2",
            // v4 — 最低音质（VIP 有时会放行低码率）
            "https://mobile.ximalaya.com/mobile-playpage/track/v4/baseInfo/ts-\(ts)?device=iPhone&trackId=\(trackId)&trackQualityLevel=1",
            // v3 web
            "https://www.ximalaya.com/mobile-playpage/track/v3/baseInfo/\(ts)?device=web&trackId=\(trackId)&trackQualityLevel=1",
            // v3 web 低音质
            "https://www.ximalaya.com/mobile-playpage/track/v3/baseInfo/\(ts)?device=web&trackId=\(trackId)&trackQualityLevel=2",
            // v3 iPhone
            "https://mobile.ximalaya.com/mobile/playpage/track/v3/baseInfo/\(ts)?device=iPhone&trackId=\(trackId)"
        ]

        for endpoint in tier1Endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            if let cookie, !cookie.isEmpty {
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if let (data, _) = try? await performRequest(req),
               let playURL = extractStreamURLFromJSON(data: data) {
                optimizedRequestCount += 1
                return playURL
            }
        }

        // ── 第二梯队：mobile v1 旧版接口（有时 VIP 章节在此接口仍有免费流） ──
        let tier2Endpoints: [String] = [
            "https://mobile.ximalaya.com/mobile/v1/track/baseInfo?trackId=\(trackId)&device=iPhone",
            "https://mobile.ximalaya.com/mobile/v1/track/baseInfo?trackId=\(trackId)&device=android",
            "https://mobwsa.ximalaya.com/mobile/v1/track/baseInfo?trackId=\(trackId)&device=iPhone"
        ]

        for endpoint in tier2Endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            if let cookie, !cookie.isEmpty {
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if let (data, _) = try? await performRequest(req),
               let playURL = extractStreamURLFromV1JSON(data: data) {
                optimizedRequestCount += 1
                return playURL
            }
        }

        // ── 第二点五梯队：download/v2/track 独立下载通道（VIP 章节常可通过下载接口获取直链）──
        if let downloadURL = await resolveDownloadTrackURL(trackId: trackId, cookie: cookie) {
            optimizedRequestCount += 1
            return downloadURL
        }

        // ── 第三梯队：若开启多通道音源优选，跨源回退（三线并发：听友 + 云图 + 喜马免费） ──
        if streamFallbackTuningEnabled {
            // 3a. 先走增强版跨源回退（多关键词 + 多源）
            if let fallbackURL = await DualSourceEngine.shared.resolveCrossSourceFallbackStream(
                bookTitle: book.title,
                episodeIndex: episode.index
            ) {
                optimizedRequestCount += 1
                return fallbackURL
            }

            // 3b. 尝试用作者名搜索同名免费书
            if !book.author.isEmpty,
               let fallbackURL2 = await DualSourceEngine.shared.resolveCrossSourceFallbackStream(
                   bookTitle: "\(book.title) \(book.author)",
                   episodeIndex: episode.index
               ) {
                optimizedRequestCount += 1
                return fallbackURL2
            }
        }

        return nil
    }

    private func extractStreamURLFromJSON(data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trackInfo = (json["trackInfo"] as? [String: Any]) ?? (json["data"] as? [String: Any]) else {
            return nil
        }
        // 1. playUrlList（AES 加密 + 明文混合）
        if let playUrlList = trackInfo["playUrlList"] as? [[String: Any]] {
            for item in playUrlList {
                if let enc = item["url"] as? String, !enc.isEmpty {
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
        // 2. playUrlList 嵌套在 data.trackInfo 中（某些 v3 响应结构）
        if let innerTrackInfo = trackInfo["trackInfo"] as? [String: Any],
           let playUrlList = innerTrackInfo["playUrlList"] as? [[String: Any]] {
            for item in playUrlList {
                if let enc = item["url"] as? String, !enc.isEmpty {
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
        // 3. 直接字段
        let directFields = [
            trackInfo["playUrl64"] as? String,
            trackInfo["playPathAacv164"] as? String,
            trackInfo["playPathHq"] as? String,
            trackInfo["playUrl32"] as? String,
            trackInfo["playUrl24"] as? String,
            trackInfo["playPathAacv224"] as? String,
            trackInfo["playPathAacv164"] as? String
        ].compactMap { $0 }.filter { !$0.isEmpty }

        if let first = directFields.first, let u = URL(string: BookItem.normalizeHttps(first)) {
            return u
        }
        return nil
    }

    /// mobile v1 track/baseInfo 专用 JSON 解析（结构与 v3/v4 不同）
    private func extractStreamURLFromV1JSON(data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // v1 响应格式：根级直接含 playUrl64 / playUrl32 / playPathAacv164 等
        let directFields = [
            json["playUrl64"] as? String,
            json["playUrl32"] as? String,
            json["playUrl24"] as? String,
            json["playPathAacv164"] as? String,
            json["playPathAacv224"] as? String,
            json["playPathHq"] as? String,
            json["playUrl"] as? String,
            json["filePath"] as? String
        ].compactMap { $0 }.filter { !$0.isEmpty }

        if let first = directFields.first, let u = URL(string: BookItem.normalizeHttps(first)) {
            return u
        }
        // v1 也可能嵌套在 data / trackInfo 中
        let nested = (json["data"] as? [String: Any]) ?? (json["trackInfo"] as? [String: Any])
        if let n = nested {
            let nestedFields = [
                n["playUrl64"] as? String,
                n["playUrl32"] as? String,
                n["playPathAacv164"] as? String,
                n["playUrl"] as? String
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if let first = nestedFields.first, let u = URL(string: BookItem.normalizeHttps(first)) {
                return u
            }
        }
        return nil
    }

    // MARK: - download/v2/track VIP 独立下载通道（QuantumultX 脚本核心端点之一）
    private func resolveDownloadTrackURL(trackId: String, cookie: String?) async -> URL? {
        guard isEnabled else { return nil }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let endpoints = [
            "https://mobile.ximalaya.com/mobile/download/v2/track?trackId=\(trackId)&ts=\(ts)",
            "https://mobwsa.ximalaya.com/mobile/download/v2/track?trackId=\(trackId)"
        ]
        for ep in endpoints {
            guard let url = URL(string: ep) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            if let cookie, !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            guard let (data, _) = try? await performRequest(req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            // 尝试多种 JSON 路径：data.downloadUrl / data.playUrl / downloadUrl / playUrl
            let info = (json["data"] as? [String: Any]) ?? json
            let candidates = [
                info["downloadUrl"] as? String,
                info["playUrl"] as? String,
                info["playUrl64"] as? String,
                info["playUrl32"] as? String,
                info["playPathAacv164"] as? String,
                info["filePath"] as? String,
                info["url"] as? String
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if let first = candidates.first, let u = URL(string: BookItem.normalizeHttps(first)) {
                return u
            }
            // 也尝试 playUrlList 解密
            if let playUrlList = info["playUrlList"] as? [[String: Any]] {
                for item in playUrlList {
                    if let enc = item["url"] as? String, !enc.isEmpty {
                        if enc.hasPrefix("http"), let u = URL(string: BookItem.normalizeHttps(enc)) { return u }
                        if let dec = DualSourceEngine.decryptXimalayaPlayURL(enc),
                           let u = URL(string: BookItem.normalizeHttps(dec)) { return u }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - JSON 响应后处理（原生模拟 QuantumultX script-response-body：修正 VIP 标记）
    /// 对喜马拉雅 API 返回的已解析 JSON 进行后处理：当调试开启时，自动将 VIP/付费标记修正为免费，
    /// 使后续解析逻辑能正常提取播放 URL。此函数模拟 QuantumultX 脚本对响应体的修改行为。
    func postProcessXimalayaJSON(_ json: inout [String: Any]) {
        guard isEnabled else { return }
        // 递归处理所有嵌套层级的 isPaid / isFree / vipStatus / needPay 标记
        postProcessJSONDict(&json)
    }

    private func postProcessJSONDict(_ dict: inout [String: Any]) {
        // 修正 VIP 标记字段（覆盖已知所有变体）
        let paidKeys = ["isPaid", "is_paid", "isPay", "needPay", "need_pay", "isVip", "is_vip", "vipOnly", "paid"]
        let freeKeys = ["isFree", "is_free", "free", "isPublic", "canPlay", "isFreeListen"]
        let statusKeys = ["vipStatus", "vipType", "payType", "memberType"]

        for key in paidKeys where dict[key] != nil {
            if dict[key] is Bool || dict[key] is Int {
                dict[key] = false
            }
        }
        for key in freeKeys where dict[key] != nil {
            if dict[key] is Bool || dict[key] is Int {
                dict[key] = true
            }
        }
        for key in statusKeys where dict[key] != nil {
            if let num = dict[key] as? Int, num > 0 { dict[key] = 0 }
            if let str = dict[key] as? String, !str.isEmpty { dict[key] = "free" }
        }

        // "priceTypes" / "priceTypeList" 数组归零
        if var arr = dict["priceTypes"] as? [Int], !arr.isEmpty {
            arr = arr.map { _ in 0 }
            dict["priceTypes"] = arr
        }
        if var arr = dict["priceTypeList"] as? [[String: Any]], !arr.isEmpty {
            arr = arr.map { item in
                var m = item
                m["price"] = 0; m["priceType"] = 0; m["isFree"] = true; m["isPaid"] = false
                return m
            }
            dict["priceTypeList"] = arr
        }

        // 递归处理嵌套字典和数组（先收集键，避免遍历时修改字典）
        let keys = Array(dict.keys)
        for key in keys {
            guard let value = dict[key] else { continue }
            if var nestedDict = value as? [String: Any] {
                postProcessJSONDict(&nestedDict)
                dict[key] = nestedDict
            } else if var nestedArray = value as? [[String: Any]] {
                for i in nestedArray.indices {
                    postProcessJSONDict(&nestedArray[i])
                }
                dict[key] = nestedArray
            }
        }
    }

    // MARK: - 持久化存储
    private struct SavedState: Codable {
        var isEnabled: Bool
        var endpointTuningEnabled: Bool
        var streamFallbackTuningEnabled: Bool
        var dataSources: [DebugDataSourceItem]
        var activeSourceId: String
        var syncedClientVersion: String
    }

    private func saveState() {
        let state = SavedState(
            isEnabled: isEnabled,
            endpointTuningEnabled: endpointTuningEnabled,
            streamFallbackTuningEnabled: streamFallbackTuningEnabled,
            dataSources: dataSources,
            activeSourceId: activeSourceId,
            syncedClientVersion: syncedClientVersion
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    private func loadState() {
        if let data = UserDefaults.standard.data(forKey: stateKey),
           let state = try? JSONDecoder().decode(SavedState.self, from: data),
           !state.dataSources.isEmpty {
            self.isEnabled = state.isEnabled
            self.endpointTuningEnabled = state.endpointTuningEnabled
            self.streamFallbackTuningEnabled = state.streamFallbackTuningEnabled
            self.dataSources = state.dataSources
            self.activeSourceId = state.activeSourceId
            self.syncedClientVersion = state.syncedClientVersion
            return
        }

        self.dataSources = [
            DebugDataSourceItem(
                id: "builtin_primary_source",
                title: "默认在线配置数据源 (ximalaya.js)",
                urlString: "https://raw.githubusercontent.com/WeiGiegie/666/main/ximalaya.js",
                lastSyncedText: "默认预置",
                isBuiltIn: true
            ),
            DebugDataSourceItem(
                id: "builtin_mirror_source",
                title: "加速镜像配置源",
                urlString: "https://ghfast.top/https://raw.githubusercontent.com/WeiGiegie/666/main/ximalaya.js",
                lastSyncedText: "备用镜像",
                isBuiltIn: true
            )
        ]
        self.activeSourceId = "builtin_primary_source"
    }
}
