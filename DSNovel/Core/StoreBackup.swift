import Foundation
import SQLite3

/// SwiftData 数据库迁移与损坏修复前的自动备份底座（T0-04 / D-3 / 8-3：
/// 迁至 Application Support/Backups 并排除 iCloud 备份；备份前执行 WAL 检查点并通过隔离暂存目录原子落盘，保留最近 2 份）
enum StoreBackup {
    static var defaultStoreDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var defaultBackupsRootDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Backups", isDirectory: true)
    }

    /// 排除目录的 iCloud 备份，避免将本地数据库快照同步至用户 iCloud 配额
    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    /// 检测文件是否为合法 SQLite 3 数据库头，避免对非 SQLite 测试占位文件执行 checkpoint
    private static func isSQLiteDatabaseFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else { return false }
        let magic = Data("SQLite format 3\0".utf8)
        return header == magic
    }

    /// 在拷贝前对活跃 SQLite 数据库执行 TRUNCATE WAL 检查点，尽可能将 WAL 刷回主库并降低热拷贝撕裂风险
    private static func checkpointSQLiteWALIfNeeded(at storeFileURL: URL) {
        guard isSQLiteDatabaseFile(storeFileURL) else { return }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(storeFileURL.path, &db, flags, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close_v2(db) }
            return
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 2000)
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        _ = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointedFrames)
    }

    @discardableResult
    static func backupCurrentStore(
        storeDirectory: URL = defaultStoreDirectory,
        backupsRoot: URL = defaultBackupsRootDirectory,
        maxRetainedCount: Int = 2,
        now: Date = .now
    ) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        excludeFromBackup(backupsRoot)

        guard let entries = try? fm.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let storeFiles = entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("default.store") || name.hasSuffix(".store") || name.hasSuffix(".store-wal") || name.hasSuffix(".store-shm")
        }
        guard !storeFiles.isEmpty else { return nil }

        // 对主 .store 文件执行 WAL 检查点，减少直接热拷贝活跃 WAL 的一致性风险
        for fileURL in storeFiles where fileURL.lastPathComponent.hasSuffix(".store") {
            checkpointSQLiteWALIfNeeded(at: fileURL)
        }

        // 重新扫描以反映检查点后的最新文件集合
        let refreshedEntries = (try? fm.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil)) ?? entries
        let filesToCopy = refreshedEntries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("default.store") || name.hasSuffix(".store") || name.hasSuffix(".store-wal") || name.hasSuffix(".store-shm")
        }
        guard !filesToCopy.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let folderName = formatter.string(from: now)
        let targetDir = backupsRoot.appendingPathComponent(folderName, isDirectory: true)

        // 先写入隔离暂存目录，完成后再原子移动到目标目录，防止中途中断留下半成品快照
        let stagingDir = backupsRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        excludeFromBackup(stagingDir)
        defer {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
        }

        for fileURL in filesToCopy {
            guard fm.fileExists(atPath: fileURL.path) else { continue }
            let dst = stagingDir.appendingPathComponent(fileURL.lastPathComponent)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: fileURL, to: dst)
            excludeFromBackup(dst)
        }

        if fm.fileExists(atPath: targetDir.path) {
            try fm.removeItem(at: targetDir)
        }
        try fm.moveItem(at: stagingDir, to: targetDir)
        excludeFromBackup(targetDir)

        pruneOldBackups(in: backupsRoot, maxRetainedCount: maxRetainedCount)
        return targetDir
    }

    static func removeStoreFiles(in storeDirectory: URL = defaultStoreDirectory) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeDirectory.path) else { return }
        let entries = try fm.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil)
        var firstError: Error?
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("default.store") || name.hasSuffix(".store") || name.hasSuffix(".store-wal") || name.hasSuffix(".store-shm") {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    static func pruneOldBackups(in backupsRoot: URL, maxRetainedCount: Int = 2) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = dirs.sorted { a, b in
            a.lastPathComponent > b.lastPathComponent
        }
        if sorted.count > maxRetainedCount {
            for oldDir in sorted.dropFirst(maxRetainedCount) {
                try? fm.removeItem(at: oldDir)
            }
        }
    }
}
