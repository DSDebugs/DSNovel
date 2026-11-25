import DSCore
import DSStorage
import Foundation
import UIKit

final class BackgroundTaskToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _taskID: UIBackgroundTaskIdentifier = .invalid
    var taskID: UIBackgroundTaskIdentifier {
        get { lock.withLock { _taskID } }
        set { lock.withLock { _taskID = newValue } }
    }
}

extension AppContainer {
    static func bootstrapStorage(inMemoryOnly: Bool, storageDir: URL) throws -> StorageBootstrapResult {
        if inMemoryOnly {
            let mem = try StorageContainerFactory.makeInMemory()
            return StorageBootstrapResult(
                container: mem,
                storeURL: storageDir.appendingPathComponent("DSNovelV3-Memory.store"),
                isDegradedInMemory: false,
                startupErrorDescription: nil
            )
        }
        do {
            return try StorageContainerFactory.makePersistent(baseDirectory: storageDir)
        } catch {
            let mem = try StorageContainerFactory.makeInMemory()
            return StorageBootstrapResult(
                container: mem,
                storeURL: storageDir.appendingPathComponent("DSNovelV3.store"),
                isDegradedInMemory: true,
                startupErrorDescription: "无法创建持久化存储，已降级为内存恢复模式：\(error.localizedDescription)"
            )
        }
    }

    /// P1-19：将大体积音频下载与可再生缓存目录排除出 iCloud / 设备备份
    static func excludeCachesFromBackup(baseDir: URL) {
        for name in ["Downloads", "ChapterCache", "PluginCache"] {
            var dirURL = baseDir.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dirURL.setResourceValues(values)
        }
    }

    static func loadBundledResource(named name: String, ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return content
    }

    func wireNowPlayingArtwork() {
        playback.onLookupCachedArtwork = { [weak self] url in
            self?.coverPipeline.cachedImageSync(for: url)
        }
        playback.onLoadArtwork = { [weak self] url in
            guard let self else { return nil }
            return await self.coverPipeline.image(for: url)
        }
    }

    func syncProtectedChapterCacheBookIDs() {
        let ids = StorageCachePolicyEngine.protectedChapterBookIDs(container: self)
        let cache = chapterCache
        Task { await cache.updateProtectedBookIDs(ids) }
    }

    func handlePrecacheRequest(book: BookSummaryDTO, upcomingChapters: [ChapterDTO]) {
        syncProtectedChapterCacheBookIDs()
        let count = settings.precacheNextCount
        let currentIndex = playback.currentChapterIndex
        let quality = resolvedQuality(for: book)
        let shouldEnqueue = count > 0
            && !upcomingChapters.isEmpty
            && !(settings.wifiOnlyDownload && !networkMonitor.isOnWiFi)
        let slice = shouldEnqueue ? Array(upcomingChapters.prefix(count)) : []
        Task {
            await self.downloads.prunePrecache(
                activeBookID: book.id,
                currentChapterIndex: currentIndex,
                keepAheadCount: count
            )
            if !slice.isEmpty {
                await self.downloads.enqueuePrecache(book: book, chapters: slice, quality: quality)
            }
        }
    }
}
