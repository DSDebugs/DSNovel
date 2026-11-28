import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import Foundation

/// 缓存上限自动清理引擎（仅统计并淘汰自动预缓存、封面图片与非保护目录，绝不删除手动下载的离线书籍）
@MainActor
enum StorageCachePolicyEngine {
    static func protectedChapterBookIDs(container: AppContainer) -> Set<String> {
        var ids = Set(container.downloads.manualRecords.filter { $0.state == .completed }.map(\.bookID))
        if let activeID = container.playback.currentBook?.id {
            ids.insert(activeID)
        }
        return ids
    }

    static func currentPrecacheBytes(container: AppContainer) async -> Int64 {
        guard let records = try? await container.persistence.fetchDownloads(kind: .precache, limit: 500) else {
            return 0
        }
        return records.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
    }

    /// 评估是否超过用户设定的缓存上限；超限时按「最久自动预缓存 → 旧封面 → 非书架旧目录」压回 85% 安全水位
    @discardableResult
    static func enforceLimitIfNeeded(container: AppContainer) async -> Bool {
        let settings = container.settings
        guard settings.autoCacheCleanupEnabled else { return false }

        let limitBytes = Int64(max(200, settings.cacheLimitMB)) * 1024 * 1024
        let targetBytes = Int64(Double(limitBytes) * 0.85)

        async let pTask = currentPrecacheBytes(container: container)
        async let cTask = container.coverPipeline.diskUsageBytes()
        async let chTask = container.chapterCache.diskUsageBytes()
        let precache = await pTask
        let cover = await cTask
        let chapter = await chTask
        let total = precache + cover + chapter
        guard total > limitBytes else { return false }

        var remainingOver = total - targetBytes

        // 1. 优先淘汰最久未用的自动预缓存音频
        if precache > 0 && remainingOver > 0 {
            let precacheTarget = max(0, precache - remainingOver)
            await container.downloads.trimPrecache(toMaxBytes: precacheTarget)
            let newPrecache = await currentPrecacheBytes(container: container)
            remainingOver -= max(0, precache - newPrecache)
        }

        // 2. 仍超限则裁剪最旧封面图片缓存
        if cover > 0 && remainingOver > 0 {
            let coverTarget = max(0, cover - remainingOver)
            await container.coverPipeline.trimDiskCache(toMaxBytes: coverTarget)
            let newCover = await container.coverPipeline.diskUsageBytes()
            remainingOver -= max(0, cover - newCover)
        }

        // 3. 最后裁剪非保护书籍的最旧章节目录缓存
        if chapter > 0 && remainingOver > 0 {
            let chapterTarget = max(0, chapter - remainingOver)
            await container.chapterCache.trimOldestCaches(
                toMaxBytes: chapterTarget,
                preservingBookIDs: protectedChapterBookIDs(container: container)
            )
        }

        return true
    }
}
