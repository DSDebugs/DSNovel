import Foundation
import SwiftData

/// 下载存储对账、孤儿文件清理与磁盘容量统计协调器（P11 / 7-4：从 DownloadManager 拆分，并将 onAppear 全表 fileExists/MD5 对账迁至后台异步执行与 60s 节流）
@MainActor
final class DownloadStorageReconciler {
    struct StorageMetrics: Sendable {
        let manualBytes: Int64
        let precacheBytes: Int64
        let temporaryCacheBytes: Int64
        let availableDiskBytes: Int64
    }

    private struct CompletedEntrySnapshot: Sendable {
        let itemID: String
        let localPath: String
    }

    private struct OrphanSeedSnapshot: Sendable {
        let bookID: String
        let chapterID: String
        let localPath: String
    }

    /// 孤儿文件对账节流时间戳（避免多页面 onAppear 频繁触发全目录扫描）
    private var lastOrphanSweepAt: Date?
    /// 已完成文件对账节流时间戳（60 秒窗口内不重复全检）
    private var lastReconcileAt: Date?
    /// 后台异步对账任务句柄（防重入）
    private var asyncReconcileTask: Task<Void, Never>?

    init() {}

    /// 7-4：节流版后台异步已完成文件对账入口（60 秒内不重复全检；所有 `fileExists` 与孤儿 MD5 计算均在后台线程执行）
    func reconcileCompletedFilesIfNeeded(
        minInterval: TimeInterval = 60,
        context: ModelContext?,
        downloadsRoot: URL,
        verifyFileExists: @escaping (String) -> Bool,
        onRemoveRecord: @escaping (String) -> Void,
        onRebuildSummaries: @escaping () -> Void
    ) {
        guard let ctx = context else { return }
        let now = Date()
        if asyncReconcileTask != nil {
            return
        }
        if let last = lastReconcileAt, now.timeIntervalSince(last) < minInterval {
            return
        }
        lastReconcileAt = now

        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "completed" })
        let items = (try? ctx.fetch(desc)) ?? []
        let snapshots = items.map { CompletedEntrySnapshot(itemID: $0.id, localPath: $0.localPath) }
        let rootDir = downloadsRoot

        // 同步触发孤儿清理快照（MD5 与磁盘遍历已全量迁入后台 detached 任务）
        sweepOrphanFiles(context: ctx, downloadsRoot: rootDir)

        guard !snapshots.isEmpty else { return }

        asyncReconcileTask = Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var missingIDs: [String] = []
            for entry in snapshots {
                if Task.isCancelled { break }
                if entry.localPath.isEmpty {
                    missingIDs.append(entry.itemID)
                    continue
                }
                if entry.localPath.hasPrefix("fixture/") {
                    continue
                }
                let fullPath = rootDir.appendingPathComponent(entry.localPath).path
                if !fm.fileExists(atPath: fullPath) {
                    missingIDs.append(entry.itemID)
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.asyncReconcileTask = nil
                guard !missingIDs.isEmpty else { return }
                let missingSet = Set(missingIDs)
                let refreshDesc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "completed" })
                if let currentItems = try? ctx.fetch(refreshDesc), !currentItems.isEmpty {
                    var changed = false
                    for item in currentItems where missingSet.contains(item.id) {
                        if item.localPath.isEmpty || !verifyFileExists(item.localPath) {
                            onRemoveRecord(item.id)
                            ctx.delete(item)
                            changed = true
                        }
                    }
                    if changed {
                        try? ctx.save()
                        onRebuildSummaries()
                    }
                }
            }
        }
    }

    /// 显式同步对账入口（保留供测试与手动强校验调用）
    func reconcileCompletedFiles(
        context: ModelContext?,
        downloadsRoot: URL,
        verifyFileExists: (String) -> Bool,
        onRemoveRecord: (String) -> Void,
        onRebuildSummaries: () -> Void
    ) {
        guard let ctx = context else { return }
        let desc = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.state == "completed" })
        if let items = try? ctx.fetch(desc), !items.isEmpty {
            var changed = false
            for item in items {
                if item.localPath.isEmpty || !verifyFileExists(item.localPath) {
                    onRemoveRecord(item.id)
                    ctx.delete(item)
                    changed = true
                }
            }
            if changed {
                try? ctx.save()
            }
        }
        onRebuildSummaries()
        sweepOrphanFiles(context: ctx, downloadsRoot: downloadsRoot)
    }

    func sweepOrphanFiles(context: ModelContext?, downloadsRoot: URL) {
        guard let ctx = context else { return }
        let now = Date()
        if let last = lastOrphanSweepAt, now.timeIntervalSince(last) <= 300 {
            return
        }
        lastOrphanSweepAt = now
        let items = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        // 7-4：仅在主线程提取轻量值快照，将全部 MD5 哈希计算与磁盘目录遍历迁至后台线程执行
        let seeds: [OrphanSeedSnapshot] = items.compactMap { item in
            if item.localPath.hasPrefix("fixture/") { return nil }
            return OrphanSeedSnapshot(bookID: item.bookID, chapterID: item.chapterID, localPath: item.localPath)
        }
        let rootDir = downloadsRoot
        Task.detached(priority: .utility) {
            var keys: Set<String> = []
            keys.reserveCapacity(seeds.count * 2)
            for seed in seeds {
                keys.insert("\(JsHostBridge.md5Hex(seed.bookID))/\(JsHostBridge.md5Hex(seed.chapterID))")
                if !seed.localPath.isEmpty {
                    let url = URL(fileURLWithPath: seed.localPath)
                    let dirName = url.deletingLastPathComponent().lastPathComponent
                    let stem = url.deletingPathExtension().lastPathComponent
                    if !dirName.isEmpty && dirName != "/" && dirName != "." && !stem.isEmpty {
                        keys.insert("\(dirName)/\(stem)")
                    }
                }
            }
            let n = Self.cleanupOrphanFilesOnDisk(root: rootDir, whitelistKeys: keys)
            if n > 0 {
                NSLog("[Downloads] 清理孤儿文件 \(n) 个")
            }
        }
    }

    func cleanupStagingFilesAsync(in stagingDir: URL, olderThan maxAgeSeconds: TimeInterval = 1800) {
        Task.detached(priority: .utility) {
            Self.cleanupOrphanedStagingFilesOnDisk(in: stagingDir, olderThan: maxAgeSeconds)
        }
    }

    /// R3-2：异步清理过期或孤儿 `.resume` 断点文件
    func cleanupExpiredResumeFilesAsync(
        in resumeDir: URL,
        whitelistItemIDs: Set<String>,
        maxAge: TimeInterval = 24 * 3600
    ) {
        Task.detached(priority: .utility) {
            let removed = Self.cleanupExpiredResumeFiles(
                in: resumeDir,
                whitelistItemIDs: whitelistItemIDs,
                maxAge: maxAge
            )
            if removed > 0 {
                NSLog("[Downloads] 清理过期/孤儿断点文件 \(removed) 个")
            }
        }
    }

    @discardableResult
    func cleanupExpiredResumeFiles(
        in resumeDir: URL,
        whitelistItemIDs: Set<String>,
        maxAge: TimeInterval = 24 * 3600
    ) -> Int {
        Self.cleanupExpiredResumeFiles(in: resumeDir, whitelistItemIDs: whitelistItemIDs, maxAge: maxAge)
    }

    func totalPrecacheBytes(context: ModelContext?, fallback: Int64) -> Int64 {
        guard let ctx = context else { return fallback }
        let desc = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.kind == "precache" && $0.state == "completed" }
        )
        let items = (try? ctx.fetch(desc)) ?? []
        return items.reduce(0) { $0 + $1.bytes }
    }

    func computeStorageMetrics(
        manualBytes: Int64,
        context: ModelContext?,
        fallbackPrecacheBytes: Int64,
        availableDiskBytesProvider: @escaping @Sendable () -> Int64
    ) async -> StorageMetrics {
        let precache = totalPrecacheBytes(context: context, fallback: fallbackPrecacheBytes)
        let coverBytes = await CoverImagePipeline.shared.diskUsageBytes()
        let freeBytes = await Task.detached(priority: .utility) {
            availableDiskBytesProvider()
        }.value
        return StorageMetrics(
            manualBytes: manualBytes,
            precacheBytes: precache,
            temporaryCacheBytes: precache + coverBytes,
            availableDiskBytes: freeBytes
        )
    }

    // MARK: - 磁盘孤儿清理核心（供后台线程直接调用，并由 DownloadFileProcessor 转发保持兼容）

    /// R3-2：清理超过 `maxAge`（默认 24 小时）或不在白名单内的孤儿 `.resume` 文件
    @discardableResult
    nonisolated static func cleanupExpiredResumeFiles(
        in resumeDir: URL,
        whitelistItemIDs: Set<String>,
        maxAge: TimeInterval = 24 * 3600
    ) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: resumeDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var whitelistKeys: Set<String> = []
        whitelistKeys.reserveCapacity(whitelistItemIDs.count * 2)
        for itemID in whitelistItemIDs {
            whitelistKeys.insert(JsHostBridge.md5Hex(itemID))
            whitelistKeys.insert(itemID)
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var removed = 0
        for url in urls where url.pathExtension.lowercased() == "resume" {
            let stem = url.deletingPathExtension().lastPathComponent
            let isOrphan = !whitelistKeys.contains(stem)
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                ?? .distantPast
            let isExpired = mod < cutoff
            if isOrphan || isExpired {
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                }
            }
        }
        return removed
    }

    nonisolated static func cleanupOrphanedStagingFilesOnDisk(
        in stagingDir: URL,
        olderThan maxAgeSeconds: TimeInterval = 1800
    ) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        for url in urls where url.pathExtension.lowercased() == "tmp" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    nonisolated static func cleanupOrphanFilesOnDisk(
        root: URL,
        whitelistKeys: Set<String>,
        minAgeSeconds: TimeInterval = 600
    ) -> Int {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-minAgeSeconds)
        var removed = 0
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        for dir in dirs {
            let dirName = dir.lastPathComponent
            // 注：staging 目录位于 tmp/DSNovelDownloadStaging，不在下载根目录下，无需在此过滤
            if dirName == "fixture" { continue }
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else {
                continue
            }
            for file in files {
                let ext = file.pathExtension.lowercased()
                if ext == "tmp" || ext == "download" { continue }
                let key = "\(dirName)/\(file.deletingPathExtension().lastPathComponent)"
                if whitelistKeys.contains(key) { continue }
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if mod > cutoff { continue }
                if (try? fm.removeItem(at: file)) != nil {
                    removed += 1
                }
            }
        }
        return removed
    }
}
