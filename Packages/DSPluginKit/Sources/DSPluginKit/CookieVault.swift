import DSCore
import Foundation
import OSLog
import Security

/// 隔离式 Cookie 与凭据保险箱（L-IOS-5 强检 isSecure/expiresDate/path/isHTTPOnly；L-IOS-7 零全局共享状态污染）
public actor CookieVault {
    private static let osLog = Logger(subsystem: "com.dsnovel.v3", category: "CookieVault")

    private var storedCookies: [HTTPCookie] = []
    private let keychainService: String
    private let inMemorySecretsOnly: Bool
    private var memorySecrets: [String: String] = [:]

    private struct PersistedCookieRecord: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let isSecure: Bool
        let isHTTPOnly: Bool
        let expiresAt: Double?

        init(
            name: String,
            value: String,
            domain: String,
            path: String,
            isSecure: Bool,
            isHTTPOnly: Bool,
            expiresAt: Double?
        ) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.isSecure = isSecure
            self.isHTTPOnly = isHTTPOnly
            self.expiresAt = expiresAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try c.decode(String.self, forKey: .value)
            domain = try c.decode(String.self, forKey: .domain)
            path = try c.decode(String.self, forKey: .path)
            isSecure = try c.decode(Bool.self, forKey: .isSecure)
            isHTTPOnly = try c.decodeIfPresent(Bool.self, forKey: .isHTTPOnly) ?? false
            expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        }
    }

    public init(
        keychainService: String = "com.dsnovel.v3.secrets",
        inMemorySecretsOnly: Bool = false
    ) {
        self.keychainService = keychainService
        self.inMemorySecretsOnly = inMemorySecretsOnly
        if !inMemorySecretsOnly {
            self.storedCookies = Self.loadPersistedCookies(keychainService: keychainService)
        }
    }

    public func setCookies(_ cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else { return }
        let now = Date()
        for incoming in cookies {
            let incomingDomain = incoming.domain.lowercased()
            storedCookies.removeAll {
                $0.name == incoming.name && $0.domain.lowercased() == incomingDomain && $0.path == incoming.path
            }
            if let exp = incoming.expiresDate, exp <= now { continue }
            storedCookies.append(incoming)
        }
        if storedCookies.count > 200 {
            storedCookies.removeAll { cookie in
                if let exp = cookie.expiresDate, exp <= now { return true }
                return false
            }
        }
        if storedCookies.count > 200 {
            let overflow = storedCookies.count - 200
            let rankedIndices = storedCookies.indices.sorted { lhs, rhs in
                let lExp = storedCookies[lhs].expiresDate
                let rExp = storedCookies[rhs].expiresDate
                switch (lExp, rExp) {
                case (nil, nil): return lhs < rhs
                case (nil, .some): return true
                case (.some, nil): return false
                case (.some(let l), .some(let r)): return l != r ? l < r : lhs < rhs
                }
            }
            let toRemove = Set(rankedIndices.prefix(overflow))
            storedCookies = storedCookies.enumerated().compactMap { toRemove.contains($0.offset) ? nil : $0.element }
        }
        persistCookiesIfNeeded()
    }

    public func storeCookies(from response: HTTPURLResponse, for url: URL) {
        var headerFields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                headerFields[ks] = vs
            }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        setCookies(parsed)
    }

    /// 按 RFC 6265 强校验 domain（区分 Host-Only）、path、isSecure、isHTTPOnly 与 expiresDate
    public func matchingCookies(for url: URL, includeHTTPOnly: Bool = true, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let isHTTPS = url.scheme?.lowercased() == "https"
        let reqPath = url.path.isEmpty ? "/" : url.path

        return storedCookies.filter { cookie in
            if let exp = cookie.expiresDate, exp <= now { return false }
            if cookie.isSecure && !isHTTPS { return false }
            if !includeHTTPOnly && cookie.isHTTPOnly { return false }
            if !domainMatches(cookieDomain: cookie.domain, requestHost: host) { return false }
            if !pathMatches(cookiePath: cookie.path, requestPath: reqPath) { return false }
            return true
        }
    }

    public func cookieHeader(for url: URL, includeHTTPOnly: Bool = true, now: Date = Date()) -> String {
        matchingCookies(for: url, includeHTTPOnly: includeHTTPOnly, now: now)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 按授权域名策略安全读取 Cookie（校验通过后方返回，杜绝跨源越权读取）
    public func authorizedCookieHeader(
        for url: URL,
        policy: SourcePermissionPolicy,
        includeHTTPOnly: Bool = true,
        now: Date = Date()
    ) throws -> String {
        try policy.validate(url: url)
        return cookieHeader(for: url, includeHTTPOnly: includeHTTPOnly, now: now)
    }

    public func clearCookies(forDomain domain: String? = nil) {
        guard let rawTarget = domain?.lowercased() else {
            storedCookies.removeAll()
            persistCookiesIfNeeded()
            return
        }
        let target = rawTarget.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !target.isEmpty else {
            storedCookies.removeAll()
            persistCookiesIfNeeded()
            return
        }
        storedCookies.removeAll { cookie in
            let cookieHost = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return cookieHost == target
                || cookieHost.hasSuffix("." + target)
                || target.hasSuffix("." + cookieHost)
        }
        persistCookiesIfNeeded()
    }

    private func persistCookiesIfNeeded() {
        guard !inMemorySecretsOnly else { return }
        let now = Date()
        let records = storedCookies.compactMap { c -> PersistedCookieRecord? in
            if let exp = c.expiresDate, exp <= now { return nil }
            return PersistedCookieRecord(
                name: c.name, value: c.value, domain: c.domain, path: c.path,
                isSecure: c.isSecure, isHTTPOnly: c.isHTTPOnly,
                expiresAt: c.expiresDate?.timeIntervalSince1970
            )
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        upsertKeychainItem(account: "v3.persisted.cookies", data: data)
    }

    private static func loadPersistedCookies(keychainService: String) -> [HTTPCookie] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "v3.persisted.cookies",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let records = try? JSONDecoder().decode([PersistedCookieRecord].self, from: data) else {
            return []
        }
        let now = Date()
        return records.compactMap { r in
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: r.name,
                .value: r.value,
                .domain: r.domain,
                .path: r.path
            ]
            if r.isSecure { props[.secure] = "TRUE" }
            if r.isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let ts = r.expiresAt {
                let exp = Date(timeIntervalSince1970: ts)
                if exp <= now { return nil }
                props[.expires] = exp
            }
            return HTTPCookie(properties: props)
        }
    }

    // MARK: - 强绑定 ownerID 的 Keychain 凭据隔离（杜绝跨源越权读取）

    public func setSecret(_ value: String?, ownerID: String, key: String) {
        let scopedAccount = Self.scopedKey(ownerID: ownerID, key: key)
        if inMemorySecretsOnly {
            if let val = value {
                memorySecrets[scopedAccount] = val
            } else {
                memorySecrets.removeValue(forKey: scopedAccount)
            }
            return
        }
        guard let val = value, let data = val.data(using: .utf8) else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: scopedAccount
            ]
            let delStatus = SecItemDelete(query as CFDictionary)
            if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
                Self.osLog.error("Keychain SecItemDelete failed: OSStatus \(delStatus)")
            }
            return
        }
        upsertKeychainItem(account: scopedAccount, data: data)
    }

    public func getSecret(ownerID: String, key: String) -> String? {
        let scopedAccount = Self.scopedKey(ownerID: ownerID, key: key)
        if inMemorySecretsOnly {
            return memorySecrets[scopedAccount]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: scopedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func scopedKey(ownerID: String, key: String) -> String {
        let safeOwner = DSCrypto.sha256Hex(ownerID).prefix(16)
        let safeKey = DSCrypto.sha256Hex(key).prefix(16)
        return "v3.\(safeOwner).\(safeKey)"
    }

    private func upsertKeychainItem(account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Self.osLog.error("Keychain SecItemAdd failed: OSStatus \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            Self.osLog.error("Keychain SecItemUpdate failed: OSStatus \(updateStatus)")
        }
    }

    /// RFC 6265 域名匹配：仅以 `.` 开头的 Domain Cookie 允许子域后缀匹配，Host-Only Cookie 必须严格相等
    private func domainMatches(cookieDomain: String, requestHost: String) -> Bool {
        let host = requestHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let rawDomain = cookieDomain.lowercased()
        let isDomainCookie = rawDomain.hasPrefix(".")
        let clean = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !clean.isEmpty else { return false }
        if isDomainCookie {
            return host == clean || host.hasSuffix("." + clean)
        }
        return host == clean
    }

    private func pathMatches(cookiePath: String, requestPath: String) -> Bool {
        let normalized = cookiePath.isEmpty ? "/" : cookiePath
        if requestPath == normalized { return true }
        if requestPath.hasPrefix(normalized) {
            if normalized.hasSuffix("/") { return true }
            let nextIdx = requestPath.index(requestPath.startIndex, offsetBy: normalized.count)
            return requestPath[nextIdx] == "/"
        }
        return false
    }
}
