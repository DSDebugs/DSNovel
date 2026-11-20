import Foundation

/// SwiftData 数据库迁移与损坏修复前的自动备份底座（T0-04 / D-3：仅用于迁移前自动备份与数据修复页重建前备份，保留最近 2 份）
enum StoreBackup {
    static var defaultStoreDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var defaultBackupsRootDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Backups", isDirectory: true)
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

        guard let entries = try? fm.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let storeFiles = entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("default.store") || name.hasSuffix(".store") || name.hasSuffix(".store-wal") || name.hasSuffix(".store-shm")
        }
        guard !storeFiles.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let folderName = formatter.string(from: now)
        let targetDir = backupsRoot.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        for fileURL in storeFiles {
            let dst = targetDir.appendingPathComponent(fileURL.lastPathComponent)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: fileURL, to: dst)
        }

        pruneOldBackups(in: backupsRoot, maxRetainedCount: maxRetainedCount)
        return targetDir
    }

    static func removeStoreFiles(in storeDirectory: URL = defaultStoreDirectory) throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("default.store") || name.hasSuffix(".store") || name.hasSuffix(".store-wal") || name.hasSuffix(".store-shm") {
                try? fm.removeItem(at: url)
            }
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
