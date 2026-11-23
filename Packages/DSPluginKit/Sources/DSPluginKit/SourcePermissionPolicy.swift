import DSCore
import Foundation

/// 宿主网络与权限错误
public enum PluginSecurityError: Error, Sendable, Equatable, LocalizedError, AudioFailureClassifying {
    case networkDisabledInPreview
    case invalidURL(String)
    case ssrfBlocked(String)
    case hostNotAllowed(host: String, ownerID: String)
    case timeout(seconds: TimeInterval)
    case scriptError(String)
    case parserRejected(reason: String, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .networkDisabledInPreview: return "预览沙箱已禁止网络请求"
        case .invalidURL(let raw): return "无效的 URL：\(raw)"
        case .ssrfBlocked(let host): return "已拦截内网或回环地址访问：\(host)"
        case .hostNotAllowed(let host, let owner): return "域名 \(host) 不在 \(owner) 允许列表中"
        case .timeout(let sec): return "脚本执行超时（\(Int(sec))s）"
        case .scriptError(let msg): return msg
        case .parserRejected(_, let msg): return msg
        case .cancelled: return "操作已取消"
        }
    }

    public var isRetryableAudioFailure: Bool {
        switch self {
        case .parserRejected, .invalidURL, .ssrfBlocked, .hostNotAllowed, .networkDisabledInPreview:
            return false
        case .timeout, .scriptError, .cancelled:
            return true
        }
    }
}

/// 私网/回环 SSRF 硬拦截器（委托 DSCore.DSSSRFValidator，与封面管线共享同一套私网防线）
public enum SSRFGuard {
    public static func validatePublicURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw PluginSecurityError.invalidURL(url.absoluteString)
        }
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            throw PluginSecurityError.invalidURL(url.absoluteString)
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if DSSSRFValidator.isBlockedHost(host) {
            throw PluginSecurityError.ssrfBlocked(host)
        }
    }

    public static func validateResolvedAddresses(for url: URL) async throws {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            throw PluginSecurityError.invalidURL(url.absoluteString)
        }
        if let blocked = await DSSSRFValidator.firstBlockedResolvedHost(for: url) {
            throw PluginSecurityError.ssrfBlocked(blocked)
        }
    }

    public static func isBlockedHost(_ host: String) -> Bool {
        DSSSRFValidator.isBlockedHost(host)
    }
}

/// 书源与内置解析器域名权限策略（固化 Q5 决策）
public struct SourcePermissionPolicy: Sendable, Equatable {
    public let ownerID: String
    public let isBuiltinParser: Bool
    public let permissionMode: SourcePermissionMode
    public let declaredHosts: [String]
    public let allowNetwork: Bool

    public init(
        ownerID: String,
        isBuiltinParser: Bool = false,
        permissionMode: SourcePermissionMode = .declaredHosts,
        declaredHosts: [String] = [],
        allowNetwork: Bool = true
    ) {
        self.ownerID = ownerID
        self.isBuiltinParser = isBuiltinParser
        self.permissionMode = permissionMode
        self.declaredHosts = declaredHosts.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        self.allowNetwork = allowNetwork
    }

    public func validate(url: URL) throws {
        guard allowNetwork else {
            throw PluginSecurityError.networkDisabledInPreview
        }
        try SSRFGuard.validatePublicURL(url)
        guard let host = url.host?.lowercased() else {
            throw PluginSecurityError.invalidURL(url.absoluteString)
        }
        if isBuiltinParser {
            guard matchesDeclaredHosts(host) else {
                throw PluginSecurityError.hostNotAllowed(host: host, ownerID: ownerID)
            }
            return
        }
        switch permissionMode {
        case .declaredHosts:
            guard !declaredHosts.isEmpty && matchesDeclaredHosts(host) else {
                throw PluginSecurityError.hostNotAllowed(host: host, ownerID: ownerID)
            }
        case .compatApproved:
            return
        }
    }

    public func matchesDeclaredHosts(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !h.isEmpty else { return false }
        for allowed in declaredHosts where !allowed.isEmpty {
            let stripped = allowed.hasPrefix("*.") ? String(allowed.dropFirst(2)) : allowed
            let clean = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !clean.isEmpty && (h == clean || h.hasSuffix("." + clean)) {
                return true
            }
        }
        return false
    }
}
