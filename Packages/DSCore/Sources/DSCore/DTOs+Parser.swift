import Foundation

/// 内置解析器健康状态（拆分自 DTOs.swift 以确保单文件 ≤ 385 行）
public enum ParserHealthStatus: String, Codable, Sendable, Equatable {
    case healthy
    case degraded
    case failed
    case unknown
}

/// 内置解析器元数据
public struct BuiltinParserMetaDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let author: String
    public let summary: String
    public let hosts: [String]
    public let networkHosts: [String]
    public let sourceIDs: [String]
    public let qualities: [AudioQualityTier]
    public let supportsPlayback: Bool
    public let supportsDownload: Bool
    public let requiresCookie: Bool
    public let sha256: String
    public let isEnabled: Bool
    public let healthStatus: ParserHealthStatus

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        author: String = "",
        summary: String = "",
        hosts: [String] = [],
        networkHosts: [String] = [],
        sourceIDs: [String] = [],
        qualities: [AudioQualityTier] = [.auto, .saver, .standard, .high],
        supportsPlayback: Bool = true,
        supportsDownload: Bool = true,
        requiresCookie: Bool = true,
        sha256: String = "",
        isEnabled: Bool = true,
        healthStatus: ParserHealthStatus = .unknown
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.hosts = hosts
        self.networkHosts = networkHosts
        self.sourceIDs = sourceIDs
        self.qualities = qualities
        self.supportsPlayback = supportsPlayback
        self.supportsDownload = supportsDownload
        self.requiresCookie = requiresCookie
        self.sha256 = sha256
        self.isEnabled = isEnabled
        self.healthStatus = healthStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        self.author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        self.networkHosts = try c.decodeIfPresent([String].self, forKey: .networkHosts) ?? []
        self.sourceIDs = try c.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
        self.qualities = try c.decodeIfPresent([AudioQualityTier].self, forKey: .qualities) ?? [.auto, .saver, .standard, .high]
        self.supportsPlayback = try c.decodeIfPresent(Bool.self, forKey: .supportsPlayback) ?? true
        self.supportsDownload = try c.decodeIfPresent(Bool.self, forKey: .supportsDownload) ?? true
        self.requiresCookie = try c.decodeIfPresent(Bool.self, forKey: .requiresCookie) ?? true
        self.sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.healthStatus = try c.decodeIfPresent(ParserHealthStatus.self, forKey: .healthStatus) ?? .unknown
    }
}
