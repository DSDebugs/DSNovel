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

        // F1：先将超 10 分钟孤儿文件移入 .orphan_quarantine 隔离保留 3 天，满期再彻底删除，防写库失败误删音频
        var orphansRemoved = 0
        let graceCutoff = now.addingTimeInterval(-600)
        let quarantineTTL: TimeInterval = 3 * 86_400
        let resolvedRoot = downloadsRoot.resolvingSymlinksInPath()
        let quarantineDir = resolvedRoot.appendingPathComponent(".orphan_quarantine", isDirectory: true)
        if let qFiles = try? FileManager.default.contentsOfDirectory(
            at: quarantineDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let expireCutoff = now.addingTimeInterval(-quarantineTTL)
            for qURL in qFiles {
                let mtime = (try? qURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if mtime <= expireCutoff {
                    try? FileManager.default.removeItem(at: qURL)
                }
            }
        }

        if let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let p = fileURL.path
                if p.contains(".pending_staging") || p.contains(".resume_data") || p.contains(".orphan_quarantine") { continue }
                let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard vals?.isRegularFile == true else { continue }
                guard let mtime = vals?.contentModificationDate else { continue }
                if mtime > graceCutoff { continue }
                if !expectedPaths.contains(fileURL.resolvingSymlinksInPath().standardizedFileURL.path) {
                    try? FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
                    let qDst = quarantineDir.appendingPathComponent("\(UUID().uuidString.prefix(8))_\(fileURL.lastPathComponent)")
                    if (try? FileManager.default.moveItem(at: fileURL, to: qDst)) != nil {
                        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: qDst.path)
                        orphansRemoved += 1
                    }
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
                if name == ".pending_staging" || name == ".resume_data" || name == ".orphan_quarantine" { continue }
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
