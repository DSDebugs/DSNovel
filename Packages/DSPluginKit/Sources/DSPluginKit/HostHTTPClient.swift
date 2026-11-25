import DSCore
import Foundation

/// HTTP 响应模型
public struct HostHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let finalURL: URL
    public let headers: [String: String]
    public let bodyData: Data
    public let preferredEncoding: String?

    public var bodyString: String {
        let headerCharset: String? = {
            guard let ct = headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased(),
                  let range = ct.range(of: "charset=") else { return nil }
            return ct[range.upperBound...].split(separator: ";").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }()
        let enc = (preferredEncoding ?? headerCharset)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let enc, enc == "gbk" || enc == "gb2312" || enc == "gb18030" || enc == "gb_18030_2000" {
            let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
            if let decoded = String(data: bodyData, encoding: String.Encoding(rawValue: nsEnc)) {
                return decoded
            }
            var converted: NSString?
            let opts: [StringEncodingDetectionOptionsKey: Any] = [
                .suggestedEncodingsKey: [NSNumber(value: nsEnc)],
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: true
            ]
            if NSString.stringEncoding(for: bodyData, encodingOptions: opts, convertedString: &converted, usedLossyConversion: nil) != 0,
               let text = converted as String? {
                return text
            }
        }
        return String(data: bodyData, encoding: .utf8) ?? String(decoding: bodyData, as: UTF8.self)
    }

    public init(
        statusCode: Int,
        finalURL: URL,
        headers: [String: String],
        bodyData: Data,
        preferredEncoding: String? = nil
    ) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.headers = headers
        self.bodyData = bodyData
        self.preferredEncoding = preferredEncoding
    }
}

/// 宿主 HTTP 客户端（L-IOS-5：私网 SSRF + DNS 复检 + 16MB 响应上限 + 302 跨域剥离敏感头 + 重定向深度上限）
public actor HostHTTPClient {
    public static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    public static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    public static let maxResponseBytes = 16 * 1024 * 1024

    private let session: URLSession
    private let ownsSession: Bool
    private let cookieVault: CookieVault
    private let maxRedirects: Int

    public init(
        session: URLSession? = nil,
        cookieVault: CookieVault,
        maxRedirects: Int = 5
    ) {
        if let custom = session {
            self.session = custom
            self.ownsSession = false
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg, delegate: RedirectBlockingDelegate(), delegateQueue: nil)
            self.ownsSession = true
        }
        self.cookieVault = cookieVault
        self.maxRedirects = max(1, maxRedirects)
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    public func send(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        policy: SourcePermissionPolicy,
        encoding: String? = nil
    ) async throws -> HostHTTPResponse {
        var currentURL = url
        var currentMethod = method.uppercased()
        var currentHeaders = headers
        var currentBody = body
        for hop in 0...maxRedirects {
            let hasExplicitCookie = currentHeaders.keys.contains { $0.lowercased() == "cookie" }
            try policy.validate(url: currentURL)
            try await SSRFGuard.validateResolvedAddresses(for: currentURL)

            var request = URLRequest(url: currentURL)
            request.httpMethod = currentMethod
            request.httpBody = currentBody
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")

            for (k, v) in currentHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }
            if request.value(forHTTPHeaderField: "Cookie") == nil {
                let vaulted = await cookieVault.cookieHeader(for: currentURL)
                if !vaulted.isEmpty {
                    request.setValue(vaulted, forHTTPHeaderField: "Cookie")
                }
            }

            let (data, http) = try await fetchCappedData(for: request, currentURL: currentURL)
            if !hasExplicitCookie {
                await cookieVault.storeCookies(from: http, for: currentURL)
            }

            var flatHeaders: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String {
                    flatHeaders[ks] = "\(v)"
                }
            }

            // 手动处理重定向：每跳复检 SSRF/DNS/权限，超限直接抛错，并剥离跨域敏感头
            if (300...399).contains(http.statusCode),
               let location = flatHeaders.first(where: { $0.key.lowercased() == "location" })?.value,
               let nextURL = Self.resolveRedirectURL(location, relativeTo: currentURL) {
                guard hop < maxRedirects else {
                    throw PluginSecurityError.scriptError("重定向次数超过上限")
                }
                currentHeaders = Self.sanitizeHeadersForRedirect(
                    headers: currentHeaders,
                    from: currentURL,
                    to: nextURL
                )
                if http.statusCode == 301 || http.statusCode == 302 || http.statusCode == 303 {
                    if currentMethod != "HEAD" && currentMethod != "GET" {
                        currentMethod = "GET"
                    }
                    currentBody = nil
                    currentHeaders = currentHeaders.filter { key, _ in
                        let lower = key.lowercased()
                        return lower != "content-type" && lower != "content-length"
                    }
                }
                currentURL = nextURL
                continue
            }

            return HostHTTPResponse(
                statusCode: http.statusCode,
                finalURL: currentURL,
                headers: flatHeaders,
                bodyData: data,
                preferredEncoding: encoding
            )
        }

        throw PluginSecurityError.scriptError("重定向次数超过上限")
    }

    private func fetchCappedData(for request: URLRequest, currentURL: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await DSCappedHTTPTransfer.fetch(
                request: request,
                session: session,
                maxBytes: Self.maxResponseBytes,
                blockRedirects: true
            )
        } catch DSCappedHTTPError.responseTooLarge {
            throw PluginSecurityError.scriptError("响应体超过 16MB 上限")
        } catch DSCappedHTTPError.nonHTTPResponse {
            throw PluginSecurityError.invalidURL(currentURL.absoluteString)
        }
    }

    private static func resolveRedirectURL(_ location: String, relativeTo currentURL: URL) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed, relativeTo: currentURL)?.absoluteURL {
            return direct
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let fallback = URL(string: encoded, relativeTo: currentURL)?.absoluteURL {
            return fallback
        }
        return nil
    }

    private static func normalizedPort(for url: URL) -> Int? {
        if let explicit = url.port { return explicit }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// 跨域重定向敏感头剥离（比较 scheme / host / 归一化 port，跨域剥离 cookie / authorization / proxy-authorization / host）
    public static func sanitizeHeadersForRedirect(
        headers: [String: String],
        from originalURL: URL,
        to redirectURL: URL
    ) -> [String: String] {
        let origScheme = originalURL.scheme?.lowercased()
        let nextScheme = redirectURL.scheme?.lowercased()
        let origHost = originalURL.host?.lowercased()
        let nextHost = redirectURL.host?.lowercased()
        let isSameOrigin = origScheme != nil
            && origScheme == nextScheme
            && origHost != nil
            && origHost == nextHost
            && normalizedPort(for: originalURL) == normalizedPort(for: redirectURL)
        if isSameOrigin {
            return headers
        }
        return headers.filter { key, _ in
            let lower = key.lowercased()
            return lower != "cookie"
                && lower != "authorization"
                && lower != "proxy-authorization"
                && lower != "host"
        }
    }
}

/// 禁用 URLSession 自动跟随重定向，交由 HostHTTPClient 逐跳审计
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
