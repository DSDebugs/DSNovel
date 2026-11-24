import Darwin
import Foundation

/// 公共私网/回环 SSRF 硬拦截器（下沉至 DSCore，供 DSPluginKit 与 DSDesignSystem 共同复用，保持单向依赖 DAG）
public enum DSSSRFValidator {
    private static let dnsQueue = DispatchQueue(label: "com.dsnovel.v3.ssrf.dns", qos: .userInitiated, attributes: .concurrent)

    /// 快速同步校验 URL 是否为合法公网 HTTP(S) 地址
    public static func isPublicHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return !isBlockedHost(host)
    }

    /// 异步通过 getaddrinfo 解析域名全部 A/AAAA 记录，返回命中的首个私网/回环主机名（离线/无法解析返回 nil）
    public static func firstBlockedResolvedHost(for url: URL) async -> String? {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return url.absoluteString
        }
        let cleanHost = normalizeHost(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard !cleanHost.isEmpty else { return rawHost }
        if parseIPv4(cleanHost) != nil {
            return isBlockedHost(cleanHost) ? cleanHost : nil
        }
        var probeV6 = in6_addr()
        if inet_pton(AF_INET6, cleanHost, &probeV6) == 1 {
            return isBlockedHost(cleanHost) ? cleanHost : nil
        }
        let resolvedIPs: [String] = await resolveIPStringsWithTimeout(for: cleanHost, timeoutSeconds: 3.0)
        for ip in resolvedIPs where isBlockedHost(ip) {
            return cleanHost
        }
        return nil
    }

    public static func isBlockedHost(_ host: String) -> Bool {
        let lower = normalizeHost(host)
        if lower.isEmpty { return true }
        if lower == "localhost"
            || lower.hasSuffix(".localhost")
            || lower.hasSuffix(".local")
            || lower.hasSuffix(".internal")
            || lower == "0.0.0.0"
            || lower == "::1"
            || lower == "::" {
            return true
        }
        if let ipv4 = parseIPv4(lower), isBlockedIPv4Tuple(ipv4) {
            return true
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, lower, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if isBlockedIPv6Bytes(bytes) { return true }
        }
        if lower.contains(":") {
            if lower.hasPrefix("fc") || lower.hasPrefix("fd")
                || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb")
                || lower.hasPrefix("fec") || lower.hasPrefix("fed") || lower.hasPrefix("fee") || lower.hasPrefix("fef") {
                return true
            }
            if lower.contains("127.0.0.") || lower.contains("::ffff:127.") || lower.contains("::ffff:10.") || lower.contains("::ffff:192.168.") {
                return true
            }
        }
        return false
    }

    private static func normalizeHost(_ host: String) -> String {
        var lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let pct = lower.firstIndex(of: "%") {
            lower = String(lower[..<pct])
        }
        return lower.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isBlockedIPv6Bytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        let isAllZero = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        if isAllZero || isLoopback { return true }
        if (bytes[0] & 0xFE) == 0xFC { return true }
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0 { return true }
        if bytes[0] == 0xFF { return true }

        let tailV4 = (Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15]))
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isBlockedIPv4Tuple(tailV4)
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isBlockedIPv4Tuple(tailV4)
        }
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B
            && bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return isBlockedIPv4Tuple(tailV4)
        }
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B
            && bytes[4] == 0x00 && bytes[5] == 0x01 {
            return true
        }
        if bytes[0..<8].allSatisfy({ $0 == 0 }) && bytes[8] == 0xFF && bytes[9] == 0xFF
            && bytes[10] == 0x00 && bytes[11] == 0x00 {
            return isBlockedIPv4Tuple(tailV4)
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return isBlockedIPv4Tuple((Int(bytes[2]), Int(bytes[3]), Int(bytes[4]), Int(bytes[5])))
        }
        return false
    }

    private final class OneShotDNSContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<[String], Never>?
        private var done = false

        init(_ cont: CheckedContinuation<[String], Never>) { self.cont = cont }

        func finish(_ ips: [String]) {
            let pending: CheckedContinuation<[String], Never>? = lock.withLock {
                guard !done else { return nil }
                done = true
                let c = cont
                cont = nil
                return c
            }
            pending?.resume(returning: ips)
        }
    }

    private static func resolveIPStringsWithTimeout(for host: String, timeoutSeconds: TimeInterval) async -> [String] {
        await withCheckedContinuation { cont in
            let gate = OneShotDNSContinuation(cont)
            dnsQueue.async { gate.finish(resolveIPStrings(for: host)) }
            dnsQueue.asyncAfter(deadline: .now() + timeoutSeconds) { gate.finish([]) }
        }
    }

    private static func resolveIPStrings(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &res)
        guard status == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let info = current.pointee
            if let sa = info.ai_addr {
                if info.ai_family == AF_INET {
                    var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        out.append(String(cString: buf))
                    }
                } else if info.ai_family == AF_INET6 {
                    var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        out.append(String(cString: buf))
                    }
                }
            }
            cursor = info.ai_next
        }
        return out
    }

    private static func isBlockedIPv4Tuple(_ ip: (Int, Int, Int, Int)) -> Bool {
        let (a, b, c, _) = ip
        if a == 0 || a == 10 || a == 127 || a >= 224 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 192 && b == 0 && c == 0 { return true }
        // 放行 198.18.0.0/15，避免 iOS Fake-IP 代理（Clash/Surge/Shadowrocket）解析域名时误判 SSRF
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }

    private static func parseIPv4(_ host: String) -> (Int, Int, Int, Int)? {
        var addr = in_addr()
        if inet_aton(host, &addr) == 1 {
            let v = UInt32(bigEndian: addr.s_addr)
            return (Int((v >> 24) & 0xFF), Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
        }
        return nil
    }
}
