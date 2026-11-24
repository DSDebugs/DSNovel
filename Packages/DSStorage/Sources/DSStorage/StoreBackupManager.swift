import DSCore
import Foundation
import SQLite3

/// 备份快照元信息
public struct StoreBackupInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let url: URL
    public let createdAt: Date
    public let sizeBytes: Int64

    public init(id: String, url: URL, createdAt: Date, sizeBytes: Int64) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
    }
}

/// SQLite WAL 安全备份与一键还原管理器（保留最近 5 份，还原前自动做安全快照）
public actor StoreBackupManager {
    private let storeURL: URL
    private let backupDir: URL
    private let maxBackups: Int

    public init(storeURL: URL, maxBackups: Int = 5) {
        self.storeURL = storeURL
        self.backupDir = storeURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        self.maxBackups = max(1, maxBackups)
        try? FileManager.default.createDirectory(at: self.backupDir, withIntermediateDirectories: true)
    }

    /// 执行 WAL TRUNCATE 检查点并创建一致性数据库快照
    public func createBackup() throws -> StoreBackupInfo {
        try createBackupInternal(prune: true)
    }

    private func createBackupInternal(prune: Bool, excludingFromPrune excludedURL: URL? = nil) throws -> StoreBackupInfo {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let stamp = Self.timestampString(Date())
        let suffix = UUID().uuidString.prefix(6)
        let name = "DSNovelV3-\(stamp)-\(suffix).store"
        let dstURL = backupDir.appendingPathComponent(name)
        let tmpURL = backupDir.appendingPathComponent(".tmp_\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // P1-05：先写临时文件，VACUUM INTO 失败则删临时文件并校验完整 WAL checkpoint 后复制
        if !vacuumIntoBackup(from: storeURL, to: tmpURL) {
            try? FileManager.default.removeItem(at: tmpURL)
            guard checkpointWALTruncate(at: storeURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.copyItem(at: storeURL, to: tmpURL)
        }
        guard verifySQLiteIntegrity(at: tmpURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if FileManager.default.fileExists(atPath: dstURL.path) {
            try FileManager.default.removeItem(at: dstURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: dstURL)
        if prune {
            pruneOldBackups(excluding: excludedURL)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: dstURL.path)[.size] as? Int64) ?? 0
        return StoreBackupInfo(id: name, url: dstURL, createdAt: Date(), sizeBytes: size)
    }

    /// B14：退后台定期自动备份（默认至少间隔 24 小时，确保修复页始终有可用历史快照）
    public func createBackupIfNeeded(minIntervalSeconds: TimeInterval = 86_400) throws -> StoreBackupInfo? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        if let latest = listBackups().first,
           minIntervalSeconds > 0,
           Date().timeIntervalSince(latest.createdAt) < minIntervalSeconds {
            return nil
        }
        return try createBackup()
    }

    public func listBackups() -> [StoreBackupInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "store" }
            .compactMap { url -> StoreBackupInfo? in
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = vals?.contentModificationDate ?? .distantPast
                let size = Int64(vals?.fileSize ?? 0)
                return StoreBackupInfo(id: url.lastPathComponent, url: url, createdAt: date, sizeBytes: size)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 一键还原指定备份（AUD-08：损坏库连同 -wal/-shm 一并归档，替换前先清理旧 -wal/-shm，替换后再幂等清理）
    public func restoreBackup(_ backup: StoreBackupInfo) throws {
        guard FileManager.default.fileExists(atPath: backup.url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let tempTarget = storeURL.deletingLastPathComponent().appendingPathComponent(".restore_\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: tempTarget) }

        try FileManager.default.copyItem(at: backup.url, to: tempTarget)
        guard verifySQLiteIntegrity(at: tempTarget) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")

        if FileManager.default.fileExists(atPath: storeURL.path) {
            if verifySQLiteIntegrity(at: storeURL) {
                _ = try? createBackupInternal(prune: false, excludingFromPrune: backup.url)
            } else {
                let corruptedDir = storeURL.deletingLastPathComponent().appendingPathComponent(".corrupted", isDirectory: true)
                try? FileManager.default.createDirectory(at: corruptedDir, withIntermediateDirectories: true)
                let dst = corruptedDir.appendingPathComponent("corrupted-\(Self.timestampString(Date()))-\(UUID().uuidString.prefix(6)).store")
                try? FileManager.default.copyItem(at: storeURL, to: dst)
                copySidecarIfExists(from: walURL, to: URL(fileURLWithPath: dst.path + "-wal"))
                copySidecarIfExists(from: shmURL, to: URL(fileURLWithPath: dst.path + "-shm"))
            }
        }

        // 先移除旧 WAL/SHM，避免替换主库瞬间旧 WAL 被误重放
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)

        if FileManager.default.fileExists(atPath: storeURL.path) {
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tempTarget)
        } else {
            try FileManager.default.moveItem(at: tempTarget, to: storeURL)
        }

        // 替换后再次幂等清理伴生文件
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)
    }

    /// 极端无备份逃生舱（UX3-02 / AUD-08）：将损坏库及伴生 -wal/-shm 一并归档至 .corrupted/ 取证，再清理残留以重建干净空库
    public func archiveCorruptedAndResetStore() throws -> URL? {
        let corruptedDir = storeURL.deletingLastPathComponent().appendingPathComponent(".corrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptedDir, withIntermediateDirectories: true)
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        var archivedURL: URL?
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let dst = corruptedDir.appendingPathComponent("corrupted-\(Self.timestampString(Date()))-\(UUID().uuidString.prefix(6)).store")
            try FileManager.default.moveItem(at: storeURL, to: dst)
            moveSidecarIfExists(from: walURL, to: URL(fileURLWithPath: dst.path + "-wal"))
            moveSidecarIfExists(from: shmURL, to: URL(fileURLWithPath: dst.path + "-shm"))
            archivedURL = dst
        }
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)
        return archivedURL
    }

    private func copySidecarIfExists(from src: URL, to dst: URL) {
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    private func moveSidecarIfExists(from src: URL, to dst: URL) {
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.moveItem(at: src, to: dst)
    }

    private func openSQLiteReadOnlyStrict(at dbURL: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle = db else {
            if let leaked = db { sqlite3_close(leaked) }
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
        return handle
    }

    private func openSQLiteReadOnlyWithFallback(at dbURL: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        var rc = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        if rc != SQLITE_OK || db == nil {
            if let leaked = db {
                sqlite3_close(leaked)
                db = nil
            }
            rc = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil)
        }
        guard rc == SQLITE_OK, let handle = db else {
            if let leaked = db { sqlite3_close(leaked) }
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
        return handle
    }

    private func vacuumIntoBackup(from srcURL: URL, to dstURL: URL) -> Bool {
        guard let handle = openSQLiteReadOnlyWithFallback(at: srcURL) else {
            return false
        }
        defer { sqlite3_close(handle) }
        let escaped = dstURL.path.replacingOccurrences(of: "'", with: "''")
        let rc = sqlite3_exec(handle, "VACUUM INTO '\(escaped)';", nil, nil, nil)
        if rc != SQLITE_OK {
            try? FileManager.default.removeItem(at: dstURL)
            return false
        }
        return true
    }

    public func verifySQLiteIntegrity(at dbURL: URL) -> Bool {
        guard let handle = openSQLiteReadOnlyStrict(at: dbURL) else {
            return false
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA quick_check(1);", -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            return false
        }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let cStr = sqlite3_column_text(s, 0) else { return false }
        return String(cString: cStr).lowercased() == "ok"
    }

    private func checkpointWALTruncate(at dbURL: URL) -> Bool {
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle = db else {
            return false
        }
        sqlite3_busy_timeout(handle, 3000)
        var pnLog: Int32 = 0
        var pnCkpt: Int32 = 0
        let rc = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &pnLog, &pnCkpt)
        return rc == SQLITE_OK && pnLog == pnCkpt
    }

    private func pruneOldBackups(excluding excludedURL: URL? = nil) {
        let excludedPath = excludedURL?.standardizedFileURL.path
        let all = listBackups().filter { $0.url.standardizedFileURL.path != excludedPath }
        guard all.count > maxBackups else { return }
        for stale in all.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

/// 版本化 JSON 书架与进度备份编解码器
public enum LibraryBackupCodec {
    public static func encode(_ payload: LibraryBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data) throws -> LibraryBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LibraryBackupPayload.self, from: data)
        guard payload.schemaVersion >= 1, payload.schemaVersion <= LibraryBackupPayload.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return payload
    }
}
