import Foundation
import WebKit

// MARK: - 全局跨子域 Cookie 持久化与 WebView 双向同步器（严格对齐 ssts CookieSync & Http.cookies(for:)）

enum CookieSync {
    private static let persistedKey = "PersistedCookies.v1"
    private static let verifiedLoginsKey = "VerifiedSourceLogins.v1"
    private static let lock = NSLock()
    private static nonisolated(unsafe) var isPersistDirty = false
    private static nonisolated(unsafe) var pendingPersistTask: Task<Void, Never>?
    private static nonisolated(unsafe) var persistGeneration: UInt64 = 0

    /// 原子初始化（Swift static let 底层使用 dispatch_once 语义），保证冷启动恢复完成后再放行并发读取
    private static let _bootstrapOnce: Void = {
        HTTPCookieStorage.shared.cookieAcceptPolicy = .always
        restoreFromDefaults()
    }()

    /// 启动时恢复持久化的登录 Cookie，并将策略设为 .always
    static func bootstrap() {
        _ = _bootstrapOnce
    }

    /// 提取域名的注册根域（如 passport.ximalaya.com -> ximalaya.com，www.example.com.cn -> example.com.cn）
    static func rootDomain(of rawDomain: String) -> String {
        let trimmed = rawDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return trimmed }
        let multiPartSuffixes: Set<String> = [
            "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
            "co.uk", "co.jp", "com.hk", "com.tw"
        ]
        let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
        if multiPartSuffixes.contains(lastTwo), parts.count >= 3 {
            return "\(parts[parts.count - 3]).\(lastTwo)"
        }
        return lastTwo
    }

    /// 写入单条 Cookie 到 HTTPCookieStorage，并自动补齐同根域共享副本（解决 passport/m 子域登录但 API 请求发往 mobwsa/api 子域的问题）
    static func storeCookie(_ cookie: HTTPCookie) {
        HTTPCookieStorage.shared.setCookie(cookie)

        let root = rootDomain(of: cookie.domain)
        guard !root.isEmpty, root.contains(".") else { return }

        var props = cookie.properties ?? [:]
        props[.domain] = ".\(root)"
        props[.path] = "/"
        // 保留原始 Cookie 的 Secure 属性，不再无条件剥离，避免 HTTPS 会话凭证被降级发送至明文 HTTP
        if cookie.isSecure {
            props[.secure] = "TRUE"
        }
        props[.discard] = "FALSE"
        if props[.expires] == nil {
            props[.expires] = Date().addingTimeInterval(30 * 24 * 3600)
        }
        if let sharedCookie = HTTPCookie(properties: props) {
            HTTPCookieStorage.shared.setCookie(sharedCookie)
        }
    }

    /// 将当前 HTTPCookieStorage 中的所有有效 Cookie 持久化到 UserDefaults（默认 1.5s 可取消防抖 + 脏标记）
    static func persistToDefaults(immediate: Bool = false) {
        if immediate {
            lock.lock()
            persistGeneration &+= 1
            pendingPersistTask?.cancel()
            pendingPersistTask = nil
            isPersistDirty = false
            lock.unlock()
            performPersistToDefaults()
            return
        }
        lock.lock()
        isPersistDirty = true
        persistGeneration &+= 1
        let generation = persistGeneration
        pendingPersistTask?.cancel()
        pendingPersistTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            lock.lock()
            guard persistGeneration == generation else {
                lock.unlock()
                return
            }
            let dirty = isPersistDirty
            isPersistDirty = false
            pendingPersistTask = nil
            lock.unlock()
            guard dirty else { return }
            performPersistToDefaults()
        }
        lock.unlock()
    }

    private static func performPersistToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        let allCookies = HTTPCookieStorage.shared.cookies ?? []
        let now = Date()
        var serialized: [[String: Any]] = []
        for c in allCookies {
            if let exp = c.expiresDate, exp < now { continue }
            var dict: [String: Any] = [
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "secure": c.isSecure
            ]
            let expTime = (c.expiresDate ?? now.addingTimeInterval(30 * 24 * 3600)).timeIntervalSince1970
            dict["expires"] = expTime
            serialized.append(dict)
        }
        UserDefaults.standard.set(serialized, forKey: persistedKey)
    }

    /// 从 UserDefaults 恢复持久化的登录 Cookie
    static func restoreFromDefaults() {
        guard let list = UserDefaults.standard.array(forKey: persistedKey) as? [[String: Any]] else {
            return
        }
        let now = Date()
        for item in list {
            guard let name = item["name"] as? String,
                  let value = item["value"] as? String,
                  let domain = item["domain"] as? String else { continue }
            let path = (item["path"] as? String) ?? "/"
            let expTime = (item["expires"] as? TimeInterval) ?? now.addingTimeInterval(30 * 24 * 3600).timeIntervalSince1970
            let expDate = Date(timeIntervalSince1970: expTime)
            guard expDate > now else { continue }

            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .expires: expDate,
                .discard: "FALSE"
            ]
            if (item["secure"] as? Bool) == true {
                props[.secure] = "TRUE"
            }
            if let c = HTTPCookie(properties: props) {
                storeCookie(c)
            }
        }
    }

    /// 查询目标 URL 匹配的全部 Cookie（含标准匹配 + 同根域跨子域匹配，100% 对齐 ssts Http.cookies(for:)）
    static func cookies(for url: URL) -> [HTTPCookie] {
        bootstrap()
        var result: [HTTPCookie] = []
        var seenNames = Set<String>()

        if let direct = HTTPCookieStorage.shared.cookies(for: url) {
            for c in direct where !c.value.isEmpty {
                seenNames.insert(c.name)
                result.append(c)
            }
        }

        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return result
        }
        let targetRoot = rootDomain(of: host)
        guard !targetRoot.isEmpty else { return result }

        if let all = HTTPCookieStorage.shared.cookies {
            for c in all where !c.value.isEmpty && !seenNames.contains(c.name) {
                let cDomain = c.domain
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
                if cDomain == host || host.hasSuffix(".\(cDomain)") || rootDomain(of: cDomain) == targetRoot {
                    seenNames.insert(c.name)
                    result.append(c)
                }
            }
        }
        return result
    }

    /// 生成目标 URL 的 Cookie 请求头字符串
    static func cookieHeader(for url: URL) -> String {
        let matched = cookies(for: url)
        guard !matched.isEmpty else { return "" }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 判断指定站点/登录地址是否已存有非空 Cookie（注意：匿名请求也会产生访客 Set-Cookie，不可直接作为已登录依据）
    static func hasCookies(for urlString: String) -> Bool {
        guard let url = JsHostBridge.makeRequestURL(from: urlString) else { return false }
        return !cookies(for: url).isEmpty
    }

    /// 获取指定书源已通过真实校验（或用户明确完成授权）的登录昵称/状态
    static func verifiedNickname(for sourceID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let map = UserDefaults.standard.dictionary(forKey: verifiedLoginsKey) as? [String: String],
              let nick = map[sourceID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nick.isEmpty else {
            return nil
        }
        return nick
    }

    /// 判断指定书源是否已通过真实登录校验
    static func isSourceLoggedIn(_ sourceID: String) -> Bool {
        verifiedNickname(for: sourceID) != nil
    }

    /// 记录或清除指定书源的真实登录状态（每个书源按 sourceID 独立隔离，绝不因其他站点匿名 Cookie 串扰）
    static func setVerifiedLogin(sourceID: String, nickname: String?) {
        lock.lock()
        defer { lock.unlock() }
        var map = (UserDefaults.standard.dictionary(forKey: verifiedLoginsKey) as? [String: String]) ?? [:]
        if let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
            map[sourceID] = nick
        } else {
            map.removeValue(forKey: sourceID)
        }
        UserDefaults.standard.set(map, forKey: verifiedLoginsKey)
    }

    /// 退出指定书源登录并清除其对应根域名的全部 Cookie
    @MainActor
    static func clearCookies(for urlStrings: [String], sourceID: String) async {
        setVerifiedLogin(sourceID: sourceID, nickname: nil)
        let targetRoots: Set<String> = Set(
            urlStrings.compactMap { raw -> String? in
                guard let url = JsHostBridge.makeRequestURL(from: raw),
                      let host = url.host?.lowercased(), !host.isEmpty else { return nil }
                let root = rootDomain(of: host)
                return root.isEmpty ? host : root
            }
        )
        guard !targetRoots.isEmpty else { return }

        if let all = HTTPCookieStorage.shared.cookies {
            for c in all {
                let cDomain = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                let cRoot = rootDomain(of: cDomain)
                if targetRoots.contains(cDomain) || targetRoots.contains(cRoot) {
                    HTTPCookieStorage.shared.deleteCookie(c)
                }
            }
        }
        persistToDefaults(immediate: true)

        let store = WKWebsiteDataStore.default().httpCookieStore
        let webCookies = await store.allCookies()
        for c in webCookies {
            let cDomain = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let cRoot = rootDomain(of: cDomain)
            if targetRoots.contains(cDomain) || targetRoots.contains(cRoot) {
                await store.deleteCookie(c)
            }
        }
    }

    /// 将 HTTPCookieStorage 中的 Cookie 推送至 WKWebView
    @MainActor
    static func pushToWebView(_ store: WKHTTPCookieStore? = nil) async {
        bootstrap()
        let targetStore = store ?? WKWebsiteDataStore.default().httpCookieStore
        let shared = HTTPCookieStorage.shared.cookies ?? []
        for cookie in shared {
            await targetStore.setCookie(cookie)
        }
    }

    /// 从 WKWebView 拉取全部 Cookie 到 HTTPCookieStorage 并持久化
    @MainActor
    static func pullFromWebView(_ store: WKHTTPCookieStore? = nil) async -> Int {
        bootstrap()
        let targetStore = store ?? WKWebsiteDataStore.default().httpCookieStore
        let webCookies = await targetStore.allCookies()
        for cookie in webCookies {
            storeCookie(cookie)
        }
        if !webCookies.isEmpty {
            persistToDefaults()
        }
        return webCookies.count
    }
}
