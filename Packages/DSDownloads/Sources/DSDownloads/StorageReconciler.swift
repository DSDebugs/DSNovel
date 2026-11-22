import DSCore
import Foundation

/// 磁盘对账报告
public struct StorageReconcileReport: Sendable, Equatable {
    public let totalAudioBytes: Int64
    public let verifiedFiles: Int
    public let missingRecordIDs: [String]
    public let orphanFilesRemoved: Int

    public init(totalAudioBytes: Int64, verifiedFiles: Int, missingRecordIDs: [String], orphanFilesRemoved: Int) {
        self.totalAudioBytes = totalAudioBytes
        self.verifiedFiles = verifiedFiles
        self.missingRecordIDs = missingRecordIDs
        self.orphanFilesRemoved = orphanFilesRemoved
    }
}

/// 异步节流磁盘对账器（L-IOS-2：60s 节流，离主线程校验已完成记录与磁盘文件一致性）
public actor StorageReconciler {
    private let downloadsRoot: URL
    private let minIntervalSeconds: TimeInterval
    private var lastReconciledAt: Date = .distantPast

    public init(downloadsRoot: URL, minIntervalSeconds: TimeInterval = 60) {
        self.downloadsRoot = downloadsRoot
        self.minIntervalSeconds = max(1, minIntervalSeconds)
        try? FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
    }

    public func reconcileIfNeeded(
        completedRecords: [DownloadRecordSnapshot],
        force: Bool = false
    ) -> StorageReconcileReport? {
        let now = Date()
        if !force && now.timeIntervalSince(lastReconciledAt) < minIntervalSeconds {
            return nil
        }
        lastReconciledAt = now

        var expectedPaths: Set<String> = []
        var missingIDs: [String] = []
        var verified = 0
        var totalBytes: Int64 = 0

        for record in completedRecords {
            guard let rel = record.localRelPath else {
                missingIDs.append(record.id)
                continue
            }
            let fullURL = downloadsRoot.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: fullURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: fullURL.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value,
               size > 0 {
                expectedPaths.insert(fullURL.resolvingSymlinksInPath().standardizedFileURL.path)
                verified += 1
                totalBytes += size
            } else {
                missingIDs.append(record.id)
            }
        }

        // 清理不在已完成记录中的孤儿音频文件（P1-11：10 分钟冷却保护窗防误删刚落盘新文件，忽略 .pending_staging / .resume_data）
        var orphansRemoved = 0
        let graceCutoff = now.addingTimeInterval(-600)
        let resolvedRoot = downloadsRoot.resolvingSymlinksInPath()
        if let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.path.contains(".pending_staging") || fileURL.path.contains(".resume_data") { continue }
                let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard vals?.isRegularFile == true else { continue }
                guard let mtime = vals?.contentModificationDate else { continue }
                if mtime > graceCutoff { continue }
                if !expectedPaths.contains(fileURL.resolvingSymlinksInPath().standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: fileURL)
                    orphansRemoved += 1
                }
            }
        }

        // 清理孤儿文件后顺手移除空的 <md5(bookID)> 子目录
        if let subdirs = try? FileManager.default.contentsOfDirectory(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dirURL in subdirs {
                let name = dirURL.lastPathComponent
                if name == ".pending_staging" || name == ".resume_data" { continue }
                let isDir = (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { continue }
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path),
                   contents.isEmpty {
                    try? FileManager.default.removeItem(at: dirURL)
                }
            }
        }

        return StorageReconcileReport(
            totalAudioBytes: totalBytes,
            verifiedFiles: verified,
            missingRecordIDs: missingIDs,
            orphanFilesRemoved: orphansRemoved
        )
    }
}
