import DSCore
import Foundation
import SwiftData

/// 书源实体（记录 Q5 权限模式与用户分组/置顶/排序，覆盖升级原地保留；拆分自 SwiftDataModels.swift 确保单文件 ≤ 385 行）
@Model
public final class SourceRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var summary: String
    public var scriptBody: String
    public var declaredHostsJSON: String
    public var permissionModeRaw: String
    public var methodsJSON: String
    public var isEnabled: Bool
    public var isPinned: Bool
    public var groupName: String
    public var sortOrder: Int
    public var loginURL: String?
    public var isBundled: Bool
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        author: String = "",
        summary: String = "",
        scriptBody: String,
        declaredHostsJSON: String = "[]",
        permissionModeRaw: String = SourcePermissionMode.declaredHosts.rawValue,
        methodsJSON: String = "[]",
        isEnabled: Bool = true,
        isPinned: Bool = false,
        groupName: String = "默认分组",
        sortOrder: Int = 0,
        loginURL: String? = nil,
        isBundled: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.scriptBody = scriptBody
        self.declaredHostsJSON = declaredHostsJSON
        self.permissionModeRaw = permissionModeRaw
        self.methodsJSON = methodsJSON
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.groupName = groupName
        self.sortOrder = sortOrder
        self.loginURL = loginURL
        self.isBundled = isBundled
        self.updatedAt = updatedAt
    }

    public func toMetaDTO() -> SourceMetaDTO {
        let hosts = (try? JSONDecoder().decode([String].self, from: Data(declaredHostsJSON.utf8))) ?? []
        let methods = (try? JSONDecoder().decode([String].self, from: Data(methodsJSON.utf8))) ?? []
        return SourceMetaDTO(
            id: id,
            name: name,
            version: version,
            author: author,
            summary: summary,
            declaredHosts: hosts,
            permissionMode: SourcePermissionMode(rawValue: permissionModeRaw) ?? .declaredHosts,
            methods: methods,
            isEnabled: isEnabled,
            isPinned: isPinned,
            groupName: groupName,
            sortOrder: sortOrder,
            loginURL: loginURL
        )
    }
}

/// 内置解析器实体（带 SHA-256 与真实健康状态）
@Model
public final class BuiltinParserEntity {
    @Attribute(.unique) public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var summary: String
    public var hostsJSON: String
    public var sourceIDsJSON: String
    public var qualitiesJSON: String
    public var supportsPlayback: Bool
    public var supportsDownload: Bool
    public var requiresCookie: Bool
    public var sha256: String
    public var isEnabled: Bool
    public var healthStatusRaw: String
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        version: String,
        author: String = "",
        summary: String = "",
        hostsJSON: String = "[]",
        sourceIDsJSON: String = "[]",
        qualitiesJSON: String = "[]",
        supportsPlayback: Bool = true,
        supportsDownload: Bool = true,
        requiresCookie: Bool = true,
        sha256: String,
        isEnabled: Bool = true,
        healthStatusRaw: String = ParserHealthStatus.unknown.rawValue,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.hostsJSON = hostsJSON
        self.sourceIDsJSON = sourceIDsJSON
        self.qualitiesJSON = qualitiesJSON
        self.supportsPlayback = supportsPlayback
        self.supportsDownload = supportsDownload
        self.requiresCookie = requiresCookie
        self.sha256 = sha256
        self.isEnabled = isEnabled
        self.healthStatusRaw = healthStatusRaw
        self.updatedAt = updatedAt
    }

    public func toMetaDTO() -> BuiltinParserMetaDTO {
        let hosts = (try? JSONDecoder().decode([String].self, from: Data(hostsJSON.utf8))) ?? []
        let sourceIDs = (try? JSONDecoder().decode([String].self, from: Data(sourceIDsJSON.utf8))) ?? []
        let qRaw = (try? JSONDecoder().decode([String].self, from: Data(qualitiesJSON.utf8))) ?? []
        let qualities = qRaw.compactMap { AudioQualityTier.fromParserToken($0) }
        return BuiltinParserMetaDTO(
            id: id,
            name: name,
            version: version,
            author: author,
            summary: summary,
            hosts: hosts,
            sourceIDs: sourceIDs,
            qualities: qualities.isEmpty ? [.auto, .saver, .standard, .high] : qualities,
            supportsPlayback: supportsPlayback,
            supportsDownload: supportsDownload,
            requiresCookie: requiresCookie,
            sha256: sha256,
            isEnabled: isEnabled,
            healthStatus: ParserHealthStatus(rawValue: healthStatusRaw) ?? .unknown
        )
    }
}

/// 书架自定义分组实体
@Model
public final class ShelfGroupEntity {
    @Attribute(.unique) public var id: String
    public var name: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// 搜索历史实体
@Model
public final class SearchHistoryEntity {
    @Attribute(.unique) public var keyword: String
    public var searchedAt: Date

    public init(keyword: String, searchedAt: Date = Date()) {
        self.keyword = keyword
        self.searchedAt = searchedAt
    }
}

/// AUD-41：固化 SwiftData v1 版本化 Schema（保持全部顶层模型类名 100% 向后兼容）
public enum DSNovelSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            BookEntity.self,
            ChapterProgressEntity.self,
            DownloadRecord.self,
            SourceRecord.self,
            BuiltinParserEntity.self,
            ShelfGroupEntity.self,
            SearchHistoryEntity.self
        ]
    }
}

/// AUD-41：固化 SwiftData 迁移计划基线，为后续版本演进预留无损升级路径
public enum DSNovelMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DSNovelSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
