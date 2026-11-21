import Foundation
import CryptoKit

// MARK: - 内置解析：磁盘存储
//
// 目录结构：
//   Application Support/BuiltinParsers/<parserID>/
//        parser.js      解析脚本正文（用户导入的 .js）
//        meta.json      解析器元数据 + 校验信息（供列表展示，避免每次都要起 JSContext）
//        parser.js.bak  上一版本脚本备份（更新失败可回滚）
//        meta.json.bak  上一版本元数据备份（回滚时成对恢复并校验 SHA-256 一致）
//
// 设计约束：
// - 所有目录名都经过 sanitize()，禁止 "." / ".." / 路径分隔符，并剥离前导点号与下划线
// - 写入与回滚均采用「临时目录 / replaceItemAt 原子替换」，失败不会破坏已安装版本
// - 启动时清扫残留的 `.staging-*` / `.trash-*` 目录（L-02）
// - 读取脚本时校验 sha256 完整性（L-03）

enum BuiltinParserStore {

    /// 单个解析器在磁盘上的元数据（meta.json 的结构）
    struct StoredMeta: Codable, Sendable {
        var id: String
        var name: String
        var version: String
        var author: String
        var summary: String
        var hosts: [String]
        var sourceIDs: [String]
        var supportsPlayback: Bool
        var supportsDownload: Bool
        var requiresCookie: Bool
        /// 脚本声明的音质档位（可选：老 meta.json 没有该键，解码为 nil）
        var qualities: [String]?
        var config: [BuiltinParserConfigItem]
        var methods: [String]
        var fileName: String
        var sha256: String
        var sizeBytes: Int
        var importedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, name, version, author, summary, hosts, sourceIDs
            case supportsPlayback, supportsDownload, requiresCookie
            case qualities, config, methods, fileName, sha256, sizeBytes, importedAt
        }

        init(
            id: String, name: String, version: String, author: String, summary: String,
            hosts: [String], sourceIDs: [String], supportsPlayback: Bool, supportsDownload: Bool,
            requiresCookie: Bool, qualities: [String]?, config: [BuiltinParserConfigItem],
            methods: [String], fileName: String, sha256: String, sizeBytes: Int, importedAt: Date
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.author = author
            self.summary = summary
            self.hosts = hosts
            self.sourceIDs = sourceIDs
            self.supportsPlayback = supportsPlayback
            self.supportsDownload = supportsDownload
            self.requiresCookie = requiresCookie
            self.qualities = qualities
            self.config = config
            self.methods = methods
            self.fileName = fileName
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.importedAt = importedAt
        }

        /// 修复 L-01：对非核心字段使用 decodeIfPresent，兼容历史版本 meta.json
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try c.decode(String.self, forKey: .id)
            self.id = decodedID
            self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? decodedID
            self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
            self.author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
            self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            self.hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
            self.sourceIDs = try c.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
            self.supportsPlayback = try c.decodeIfPresent(Bool.self, forKey: .supportsPlayback) ?? true
            self.supportsDownload = try c.decodeIfPresent(Bool.self, forKey: .supportsDownload) ?? true
            self.requiresCookie = try c.decodeIfPresent(Bool.self, forKey: .requiresCookie) ?? true
            self.qualities = try c.decodeIfPresent([String].self, forKey: .qualities)
            self.config = try c.decodeIfPresent([BuiltinParserConfigItem].self, forKey: .config) ?? []
            self.methods = try c.decodeIfPresent([String].self, forKey: .methods) ?? []
            self.fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "parser.js"
            self.sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
            self.sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
            self.importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? .distantPast
        }
    }

    static let scriptFileName = "parser.js"
    static let metaFileName = "meta.json"
    static let backupFileName = "parser.js.bak"
    static let metaBackupFileName = "meta.json.bak"

    // MARK: 路径

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BuiltinParsers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func directory(for parserID: String) -> URL {
        rootDirectory.appendingPathComponent(sanitize(parserID), isDirectory: true)
    }

    /// 目录名/文件名白名单化：仅保留字母数字与 . _ -，其它字符替换为 '_'，并剥离前导 '.' 与 '_'
    /// 修复 P0-06：`sanitize("../evil")` 返回 `"evil"`，与单测契约完全一致。
    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ._-")
        var out = ""
        for scalar in trimmed.unicodeScalars {
            out.unicodeScalars.append(allowed.contains(scalar) ? scalar : "_")
        }
        while out.hasPrefix(".") || out.hasPrefix("_") {
            out.removeFirst()
        }
        if out.isEmpty { out = "parser" }
        if out.count > 64 { out = String(out.prefix(64)) }
        return out
    }

    /// 清扫崩溃或中断遗留的 `.staging-*` / `.trash-*` 临时目录（L-02）
    static func cleanupTemporaryDirectories() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootDirectory,
                                                        includingPropertiesForKeys: nil,
                                                        options: []) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".staging-") || name.hasPrefix(".trash-") {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: 读取

    /// 扫描磁盘上已安装的解析器（解析路径的唯一数据源）
    static func installedParsers() -> [InstalledBuiltinParser] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootDirectory,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [InstalledBuiltinParser] = []
        for dir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let parser = loadParser(in: dir) {
                result.append(parser)
            }
        }
        return result.sorted { $0.importedAt > $1.importedAt }
    }

    static func loadParser(in dir: URL) -> InstalledBuiltinParser? {
        let metaURL = dir.appendingPathComponent(metaFileName)
        guard let data = try? Data(contentsOf: metaURL),
              let stored = try? JSONDecoder.builtinParser.decode(StoredMeta.self, from: data) else {
            return nil
        }
        let scriptURL = dir.appendingPathComponent(scriptFileName)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return nil }

        let meta = BuiltinParserMeta(
            id: stored.id,
            name: stored.name,
            version: stored.version,
            author: stored.author,
            summary: stored.summary,
            targets: BuiltinParserTargets(hosts: stored.hosts, sourceIDs: stored.sourceIDs),
            supportsPlayback: stored.supportsPlayback,
            supportsDownload: stored.supportsDownload,
            requiresCookie: stored.requiresCookie,
            qualities: Set(stored.qualities ?? []),
            config: stored.config,
            methods: Set(stored.methods)
        )
        return InstalledBuiltinParser(
            meta: meta,
            fileName: stored.fileName,
            sha256: stored.sha256,
            sizeBytes: stored.sizeBytes,
            importedAt: stored.importedAt,
            directory: dir
        )
    }

    /// 读取解析脚本正文（自动兼容 BOM / UTF-16 / GB18030），并校验 sha256 完整性（L-03）
    static func scriptText(for parser: InstalledBuiltinParser, verifyIntegrity: Bool = true) -> String? {
        let url = parser.directory.appendingPathComponent(scriptFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if verifyIntegrity, !parser.sha256.isEmpty {
            let actual = sha256Hex(data)
            if actual != parser.sha256 {
                BuiltinParserLogStore.shared.append(
                    parser.id,
                    "脚本完整性校验失败（期望 \(parser.sha256.prefix(12))，实际 \(actual.prefix(12))），已拒绝加载"
                )
                return nil
            }
        }
        return PluginRuntimeDecoding.decodeScriptText(data)
    }

    static func installedVersion(for parserID: String) -> String? {
        guard let parser = loadParser(in: directory(for: parserID)) else { return nil }
        return parser.meta.version
    }

    // MARK: 写入 / 删除

    /// 安装或更新解析器：先写临时目录，再原子替换，旧版本脚本与元数据成对保留为 .bak 以便回滚
    @discardableResult
    static func install(preview: BuiltinParserPreview, importedAt: Date = .now) throws -> InstalledBuiltinParser {
        let fm = FileManager.default
        let targetDir = directory(for: preview.meta.id)

        // M-03：检测不同 parserID 经 sanitize 后的目录碰撞，防止静默覆盖
        if fm.fileExists(atPath: targetDir.path),
           let existing = loadParser(in: targetDir),
           existing.meta.id != preview.meta.id {
            throw BuiltinParserError.scriptInvalid("解析器 ID「\(preview.meta.id)」与已安装的「\(existing.meta.id)」目录名冲突，请修改 ID 后重试")
        }

        let staging = rootDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        defer { try? fm.removeItem(at: staging) }

        let scriptData = Data(preview.scriptText.utf8)
        let computedSha = sha256Hex(scriptData)
        try scriptData.write(to: staging.appendingPathComponent(scriptFileName), options: .atomic)

        let stored = StoredMeta(
            id: preview.meta.id,
            name: preview.meta.name,
            version: preview.meta.version,
            author: preview.meta.author,
            summary: preview.meta.summary,
            hosts: preview.meta.targets.hosts,
            sourceIDs: preview.meta.targets.sourceIDs,
            supportsPlayback: preview.meta.supportsPlayback,
            supportsDownload: preview.meta.supportsDownload,
            requiresCookie: preview.meta.requiresCookie,
            qualities: Array(preview.meta.qualities).sorted(),
            config: preview.meta.config,
            methods: Array(preview.meta.methods).sorted(),
            fileName: preview.fileName,
            sha256: computedSha,
            sizeBytes: scriptData.count,
            importedAt: importedAt
        )
        let metaData = try JSONEncoder.builtinParser.encode(stored)
        try metaData.write(to: staging.appendingPathComponent(metaFileName), options: .atomic)

        if fm.fileExists(atPath: targetDir.path) {
            // 8-5：成对备份旧版 parser.js 与 meta.json（补齐或校验 SHA-256），避免只留单边备份导致回滚校验失败
            let backupSource = targetDir.appendingPathComponent(scriptFileName)
            let backupMetaSource = targetDir.appendingPathComponent(metaFileName)
            let stagedScriptBak = staging.appendingPathComponent(backupFileName)
            let stagedMetaBak = staging.appendingPathComponent(metaBackupFileName)
            if let oldScriptData = try? Data(contentsOf: backupSource),
               let oldMetaRaw = try? Data(contentsOf: backupMetaSource),
               var oldMeta = try? JSONDecoder.builtinParser.decode(StoredMeta.self, from: oldMetaRaw) {
                let oldSha = sha256Hex(oldScriptData)
                if oldMeta.sha256.isEmpty || oldMeta.sha256 != oldSha {
                    oldMeta.sha256 = oldSha
                    oldMeta.sizeBytes = oldScriptData.count
                }
                do {
                    let normalizedOldMeta = try JSONEncoder.builtinParser.encode(oldMeta)
                    try oldScriptData.write(to: stagedScriptBak, options: .atomic)
                    try normalizedOldMeta.write(to: stagedMetaBak, options: .atomic)
                } catch {
                    try? fm.removeItem(at: stagedScriptBak)
                    try? fm.removeItem(at: stagedMetaBak)
                }
            }
            let trash = rootDirectory.appendingPathComponent(".trash-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: targetDir, to: trash)
            do {
                try fm.moveItem(at: staging, to: targetDir)
                try? fm.removeItem(at: trash)
            } catch {
                // 回滚
                try? fm.moveItem(at: trash, to: targetDir)
                throw error
            }
        } else {
            try fm.moveItem(at: staging, to: targetDir)
        }

        guard let installed = loadParser(in: targetDir) else {
            throw BuiltinParserError.invokeFailed("安装后无法读取解析器元数据")
        }
        return installed
    }

    static func remove(parserID: String) throws {
        let dir = directory(for: parserID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    static func backupExists(parserID: String) -> Bool {
        let dir = directory(for: parserID)
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(backupFileName).path)
            && fm.fileExists(atPath: dir.appendingPathComponent(metaBackupFileName).path)
    }

    /// 8-5：成对回滚脚本与 `meta.json.bak` 并强校验 SHA-256 一致；若元数据替换失败则自动恢复原脚本，防止半回滚损坏
    static func rollbackScript(parserID: String) throws {
        let fm = FileManager.default
        let dir = directory(for: parserID)
        let backup = dir.appendingPathComponent(backupFileName)
        let metaBackup = dir.appendingPathComponent(metaBackupFileName)
        guard fm.fileExists(atPath: backup.path) else {
            throw BuiltinParserError.invokeFailed("没有可回滚的备份")
        }
        let script = dir.appendingPathComponent(scriptFileName)
        let meta = dir.appendingPathComponent(metaFileName)

        let backupScriptData = try Data(contentsOf: backup)
        let backupSha = sha256Hex(backupScriptData)

        let resolvedMetaData: Data
        let hasMetaBackup = fm.fileExists(atPath: metaBackup.path)
        if hasMetaBackup {
            let rawBakMeta = try Data(contentsOf: metaBackup)
            var decodedBakMeta = try JSONDecoder.builtinParser.decode(StoredMeta.self, from: rawBakMeta)
            if !decodedBakMeta.sha256.isEmpty && decodedBakMeta.sha256 != backupSha {
                throw BuiltinParserError.scriptInvalid("回滚备份校验失败：脚本与 meta.json.bak 的 SHA-256 不一致")
            }
            decodedBakMeta.sha256 = backupSha
            decodedBakMeta.sizeBytes = backupScriptData.count
            resolvedMetaData = try JSONEncoder.builtinParser.encode(decodedBakMeta)
        } else {
            // 兼容旧版仅存 parser.js.bak 的场景：基于当前 meta.json 同步修正 sha256 与 sizeBytes，保证回滚后可通过完整性校验
            guard let currentMetaRaw = try? Data(contentsOf: meta),
                  var patchedMeta = try? JSONDecoder.builtinParser.decode(StoredMeta.self, from: currentMetaRaw) else {
                throw BuiltinParserError.invokeFailed("缺少配对的 meta.json.bak，无法安全回滚")
            }
            patchedMeta.sha256 = backupSha
            patchedMeta.sizeBytes = backupScriptData.count
            resolvedMetaData = try JSONEncoder.builtinParser.encode(patchedMeta)
        }

        // 先在 staging 准备目标副本及当前版本应急副本，再通过 replaceItemAt 原子替换
        let staging = rootDirectory.appendingPathComponent(".staging-rollback-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let stagedScript = staging.appendingPathComponent(scriptFileName)
        let stagedMeta = staging.appendingPathComponent(metaFileName)
        try backupScriptData.write(to: stagedScript, options: .atomic)
        try resolvedMetaData.write(to: stagedMeta, options: .atomic)

        let previousScriptCopy = staging.appendingPathComponent("prev-\(scriptFileName)")
        let hasPrevScript = fm.fileExists(atPath: script.path)
        if hasPrevScript {
            try fm.copyItem(at: script, to: previousScriptCopy)
        }

        _ = try fm.replaceItemAt(script, withItemAt: stagedScript)
        do {
            _ = try fm.replaceItemAt(meta, withItemAt: stagedMeta)
        } catch {
            // 若 meta.json 替换失败，立即还原脚本正文以维持 script/meta SHA-256 一致
            if hasPrevScript && fm.fileExists(atPath: previousScriptCopy.path) {
                _ = try? fm.replaceItemAt(script, withItemAt: previousScriptCopy)
            }
            throw error
        }

        try? fm.removeItem(at: backup)
        if hasMetaBackup {
            try? fm.removeItem(at: metaBackup)
        }
    }

    // MARK: 工具

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var builtinParser: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var builtinParser: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - 脚本解码（复用 PluginRuntime 的口径，避免两处实现漂移）

enum PluginRuntimeDecoding {
    /// 与 PluginRuntime.decodeScriptText 保持一致：UTF-8 BOM → UTF-8 → UTF-16 → GB18030 兜底
    static func decodeScriptText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gbEncoding))
    }
}
