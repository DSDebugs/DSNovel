import Foundation

extension CookieVault {
    /// 冷启动增量补齐 Cookie（仅补充当前保险箱缺失条目，不覆盖已更新的同名 Cookie）
    public func mergeMissingCookies(_ cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else { return }
        let now = Date()
        let normalized = Self.withNormalizedXimalayaAuthCookies(cookies)
        var added = false
        for incoming in normalized {
            if let exp = incoming.expiresDate, exp <= now { continue }
            let incomingDomain = incoming.domain.lowercased()
            let exists = storedCookies.contains {
                $0.name == incoming.name && $0.domain.lowercased() == incomingDomain && $0.path == incoming.path
            }
            if !exists {
                storedCookies.append(incoming)
                added = true
            }
        }
        if added { persistCookiesIfNeeded() }
    }

    public static func withNormalizedXimalayaAuthCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var result = cookies
        for c in cookies where c.name == "1&_token" {
            let d = c.domain.lowercased()
            if d == "ximalaya.com" || d.hasSuffix(".ximalaya.com") && d != ".ximalaya.com" {
                var props: [HTTPCookiePropertyKey: Any] = [
                    .name: c.name, .value: c.value, .domain: ".ximalaya.com", .path: "/"
                ]
                if c.isSecure { props[.secure] = "TRUE" }
                if c.isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let exp = c.expiresDate { props[.expires] = exp }
                if let promoted = HTTPCookie(properties: props) {
                    result.append(promoted)
                }
            }
        }
        return result
    }

    internal static func isProtectedAuthCookie(_ cookie: HTTPCookie) -> Bool {
        let lower = cookie.name.lowercased()
        return lower == "1&_token" || lower.contains("token") || lower.contains("session") || lower.contains("auth")
    }


    internal static func defaultFallbackFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("DSNovelV3/cookies.vault", isDirectory: false)
    }

    internal static func loadCookiesFromFile(at url: URL) -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([PersistedCookieRecord].self, from: data) else {
            return []
        }
        return decodeCookieRecords(records)
    }

}
