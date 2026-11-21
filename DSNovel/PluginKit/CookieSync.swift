import Foundation
import WebKit

// MARK: - 全局跨子域 Cookie 持久化与 WebView 双向同步器（严格对齐 ssts CookieSync & Http.cookies(for:)）

enum CookieSync {
    private static let persistedKey = "PersistedCookies.v1"
    private static let verifiedLoginsKey = "VerifiedSourceLogins.v1"
    private static let cookieStoreFileName = "DSNovelCookies.bin"
    private static let lock = NSLock()
    private static nonisolated(unsafe) var isPersistDirty = false
    private static nonisolated(unsafe) var pendingPersistTask: Task<Void, Never>?
    private static nonisolated(unsafe) var persistGeneration: UInt64 = 0

    /// 含认证态的关键 Cookie 名称特征（供 hostOnly 场景判断是否需要向根域同步）
    private static let authCookieKeywords: [String] = [
        "token", "sess", "sid", "auth", "uid", "user", "login",
        "jwt", "ticket", "key", "csrf", "xsrf", "sign",
        "bili_jct", "dedeuserid", "buvid", "music_u"
    ]

    private struct PersistedCookieRecord: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let expires: TimeInterval
    }

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

    private static func cookieStoreFileURL() -> URL? {
        guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent(cookieStoreFileName, isDirectory: false)
    }

    private static func shouldMirrorToRootDomain(_ cookie: HTTPCookie) -> Bool {
        // 非 hostOnly（带前导点的域级 Cookie）直接允许根域同步
        if cookie.domain.hasPrefix(".") {
            return true
        }
        // hostOnly Cookie 仅在包含认证态特征关键字时做根域同步
        let lowerName = cookie.name.lowercased()
        return authCookieKeywords.contains { lowerName.contains($0) }
    }

    private static func targetRootDomain(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        let root = rootDomain(of: host)
        return root.isEmpty ? host : root
    }

    private static func matchesTargetRoot(_ cookie: HTTPCookie, targetRoot: String?) -> Bool {
        guard let targetRoot, !targetRoot.isEmpty else { return true }
        let cDomain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !cDomain.isEmpty else { return false }
        return cDomain == targetRoot || cDomain.hasSuffix(".\(targetRoot)") || rootDomain(of: cDomain) == targetRoot
    }

    /// 写入单条 Cookie 到 HTTPCookieStorage，并按 S7 规则收敛根域共享副本（仅非 hostOnly 或关键认证态 Cookie 同步至根域，保留原 path）
    static func storeCookie(_ cookie: HTTPCookie) {
        HTTPCookieStorage.shared.setCookie(cookie)

        guard shouldMirrorToRootDomain(cookie) else { return }

        let root = rootDomain(of: cookie.domain)
        guard !root.isEmpty, root.contains(".") else { return }
        let targetDomain = ".\(root)"
        // 已是根域 Cookie 时无需重复克隆
        guard cookie.domain.lowercased() != targetDomain else { return }

        var props = cookie.properties ?? [:]
        props[.domain] = targetDomain
        props[.path] = cookie.path.isEmpty ? "/" : cookie.path
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

    /// 将当前 HTTPCookieStorage 中的所有有效 Cookie 持久化到受保护文件（默认 1.5s 可取消防抖 + 脏标记）
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
        guard let fileURL = cookieStoreFileURL() else { return }
        let allCookies = HTTPCookieStorage.shared.cookies ?? []
        let now = Date()
        var records: [PersistedCookieRecord] = []
        records.reserveCapacity(allCookies.count)
        for c in allCookies {
            if let exp = c.expiresDate, exp < now { continue }
            let expTime = (c.expiresDate ?? now.addingTimeInterval(30 * 24 * 3600)).timeIntervalSince1970
            records.append(
                PersistedCookieRecord(
                    name: c.name,
                    value: c.value,
                    domain: c.domain,
                    path: c.path.isEmpty ? "/" : c.path,
                    secure: c.isSecure,
                    expires: expTime
                )
            )
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(records) else { return }
        #if os(iOS)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: fileURL, options: [.atomic])
        #endif
    }

    /// 从受保护文件恢复持久化的登录 Cookie（S7：启动时自动兼容迁移旧 UserDefaults 明文数据并立即清除旧键）
    static func restoreFromDefaults() {
        let now = Date()

        // 1. 优先读取受文件保护的 Application Support/DSNovelCookies.bin
        if let fileURL = cookieStoreFileURL(),
           let data = try? Data(contentsOf: fileURL),
           let records = try? PropertyListDecoder().decode([PersistedCookieRecord].self, from: data) {
            for item in records {
                let expDate = Date(timeIntervalSince1970: item.expires)
                guard expDate > now else { continue }
                restoreSingleCookie(
                    name: item.name,
                    value: item.value,
                    domain: item.domain,
                    path: item.path,
                    secure: item.secure,
                    expires: expDate
                )
            }
        }

        // 2. 兼容迁移旧版 UserDefaults 明文 Cookie，迁移完成后立即清除明文旧键
        if let legacyList = UserDefaults.standard.array(forKey: persistedKey) as? [[String: Any]] {
            for item in legacyList {
                guard let name = item["name"] as? String,
                      let value = item["value"] as? String,
                      let domain = item["domain"] as? String else { continue }
                let path = (item["path"] as? String) ?? "/"
                let expTime = (item["expires"] as? TimeInterval) ?? now.addingTimeInterval(30 * 24 * 3600).timeIntervalSince1970
                let expDate = Date(timeIntervalSince1970: expTime)
                guard expDate > now else { continue }
                restoreSingleCookie(
                    name: name,
                    value: value,
                    domain: domain,
                    path: path,
                    secure: (item["secure"] as? Bool) == true,
                    expires: expDate
                )
            }
            performPersistToDefaults()
            UserDefaults.standard.removeObject(forKey: persistedKey)
        }
    }

    private static func restoreSingleCookie(
        name: String,
        value: String,
        domain: String,
        path: String,
        secure: Bool,
        expires: Date
    ) {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
            .expires: expires,
            .discard: "FALSE"
        ]
        if secure {
            props[.secure] = "TRUE"
        }
        if let c = HTTPCookie(properties: props) {
            storeCookie(c)
        }
    }

    /// RFC 6265 Cookie 路径前缀匹配校验
    static func pathMatches(requestPath rawRequestPath: String, cookiePath rawCookiePath: String) -> Bool {
        let reqPath = rawRequestPath.isEmpty ? "/" : rawRequestPath
        let cPath = rawCookiePath.isEmpty ? "/" : rawCookiePath
        if cPath == "/" || reqPath == cPath {
            return true
        }
        if cPath.hasSuffix("/") {
            return reqPath.hasPrefix(cPath)
        }
        return reqPath.hasPrefix(cPath + "/")
    }

    /// 查询目标 URL 匹配的全部 Cookie（含标准匹配 + 同根域跨子域匹配；M-P0-8 补齐 isSecure / expiresDate / path 校验）
    static func cookies(for url: URL) -> [HTTPCookie] {
        bootstrap()
        let now = Date()
        let isHTTPS = (url.scheme?.lowercased() == "https")
        let reqPath = url.path.isEmpty ? "/" : url.path
        var result: [HTTPCookie] = []
        var seenNames = Set<String>()

        if let direct = HTTPCookieStorage.shared.cookies(for: url) {
            for c in direct where !c.value.isEmpty {
                if c.isSecure && !isHTTPS { continue }
                if let exp = c.expiresDate, exp <= now { continue }
                guard pathMatches(requestPath: reqPath, cookiePath: c.path) else { continue }
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
                // M-P0-8：明文 HTTP 绝不带出 Secure Cookie；过滤已过期与路径不匹配的 Cookie
                if c.isSecure && !isHTTPS { continue }
                if let exp = c.expiresDate, exp <= now { continue }
                guard pathMatches(requestPath: reqPath, cookiePath: c.path) else { continue }
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

    /// 将 HTTPCookieStorage 中的 Cookie 推送至 WKWebView（S7：支持按可选目标 URL 根域过滤，无参默认全量兼容）
    @MainActor
    static func pushToWebView(_ store: WKHTTPCookieStore? = nil, for url: URL? = nil) async {
        bootstrap()
        let targetStore = store ?? WKWebsiteDataStore.default().httpCookieStore
        let targetRoot = targetRootDomain(for: url)
        let shared = HTTPCookieStorage.shared.cookies ?? []
        for cookie in shared where matchesTargetRoot(cookie, targetRoot: targetRoot) {
            await targetStore.setCookie(cookie)
        }
    }

    /// 从 WKWebView 拉取 Cookie 到 HTTPCookieStorage 并持久化（S7：支持按可选目标 URL 根域过滤，无参默认全量兼容）
    @MainActor
    static func pullFromWebView(_ store: WKHTTPCookieStore? = nil, for url: URL? = nil) async -> Int {
        bootstrap()
        let targetStore = store ?? WKWebsiteDataStore.default().httpCookieStore
        let targetRoot = targetRootDomain(for: url)
        let webCookies = await targetStore.allCookies()
        var matchedCount = 0
        for cookie in webCookies where matchesTargetRoot(cookie, targetRoot: targetRoot) {
            storeCookie(cookie)
            matchedCount += 1
        }
        if matchedCount > 0 {
            persistToDefaults()
        }
        return matchedCount
    }
}
