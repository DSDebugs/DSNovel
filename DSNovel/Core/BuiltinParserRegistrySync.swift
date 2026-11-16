import Foundation
import SwiftData

// MARK: - 内置解析：磁盘 ↔ SwiftData 展示记录同步
//
// 磁盘（Application Support/BuiltinParsers）是解析链路的唯一数据源；
// SwiftData 的 BuiltinParserRecord 只用于「书源管理」界面展示与管理。
// 两侧在安装/删除时同步写入，启动时再对账一次，保证界面不出现幽灵记录。

@MainActor
enum BuiltinParserRegistrySync {

    /// 以磁盘为准对账 SwiftData 记录（保留用户的启用开关与自检结果）
    static func syncRecords(context: ModelContext, diskParsers: [InstalledBuiltinParser]? = nil) {
        let installed = diskParsers ?? BuiltinParserStore.installedParsers()
        let existing = (try? context.fetch(FetchDescriptor<BuiltinParserRecord>())) ?? []
        var byID: [String: BuiltinParserRecord] = [:]
        for record in existing { byID[record.id] = record }

        for parser in installed {
            if let record = byID[parser.id] {
                record.applyDiskState(parser)
                byID[parser.id] = nil
            } else {
                let record = BuiltinParserRecord(
                    id: parser.id,
                    name: parser.meta.name,
                    version: parser.meta.version,
                    author: parser.meta.author,
                    summary: parser.meta.summary,
                    targetHosts: parser.meta.targets.hosts.joined(separator: ","),
                    targetSourceIDs: parser.meta.targets.sourceIDs.joined(separator: ","),
                    fileName: parser.fileName,
                    sha256: parser.sha256,
                    sizeBytes: parser.sizeBytes,
                    importedAt: parser.importedAt
                )
                context.insert(record)
            }
        }

        // 磁盘上已不存在 → 删除界面记录（不触碰用户的书源记录）
        for orphan in byID.values {
            context.delete(orphan)
        }

        try? context.save()
    }

    /// 安装后写入/更新单条记录
    static func upsert(context: ModelContext, parser: InstalledBuiltinParser) {
        let targetID = parser.id
        let descriptor = FetchDescriptor<BuiltinParserRecord>(
            predicate: #Predicate<BuiltinParserRecord> { $0.id == targetID }
        )
        if let record = (try? context.fetch(descriptor))?.first {
            record.applyDiskState(parser)
        } else {
            let record = BuiltinParserRecord(
                id: parser.id,
                name: parser.meta.name,
                version: parser.meta.version,
                author: parser.meta.author,
                summary: parser.meta.summary,
                targetHosts: parser.meta.targets.hosts.joined(separator: ","),
                targetSourceIDs: parser.meta.targets.sourceIDs.joined(separator: ","),
                fileName: parser.fileName,
                sha256: parser.sha256,
                sizeBytes: parser.sizeBytes,
                importedAt: parser.importedAt
            )
            context.insert(record)
        }
        try? context.save()
    }

    static func remove(context: ModelContext, parserID: String) {
        let targetID = parserID
        let descriptor = FetchDescriptor<BuiltinParserRecord>(
            predicate: #Predicate<BuiltinParserRecord> { $0.id == targetID }
        )
        if let record = (try? context.fetch(descriptor))?.first {
            context.delete(record)
            try? context.save()
        }
    }
}
