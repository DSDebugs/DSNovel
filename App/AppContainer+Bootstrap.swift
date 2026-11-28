import DSCore
import DSDownloads
import DSStorage
import Foundation
import UIKit
import WebKit

// SAFETY: 仅在 @MainActor 上下文初始化与读取，用作 beginBackgroundTask 过期回调句柄传递。
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
        OfflineAudioExporter.cleanupStaleStagingDirectories(maxAge: 600)
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

    func syncBundledParserIfInstalledAndOlder() async {
        _ = await BundledParserLoader.upgradeBundledXimalayaParserIfInstalledAndOlder(engine: builtinParser)
    }

    func syncWebKitCookiesToVaultIfNeeded() async {
        let allCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        guard !allCookies.isEmpty else { return }
        await cookieVault.mergeMissingCookies(allCookies)
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

    internal func wireReactiveLinks(registerGlobalBackgroundSession: Bool) {
        if registerGlobalBackgroundSession {
            BackgroundSessionCoordinator.shared.registerHandler { [weak self] completion in
                guard let self else { completion(); return }
                if self.didFinishDownloadsBootstrap {
                    self.downloads.handleBackgroundURLSessionEvents(completionHandler: completion)
                } else {
                    Task { @MainActor [weak self] in
                        guard let self else { completion(); return }
                        await self.ensureSourcesRegistered()
                        await self.ensureDownloadsBootstrappedIfNeeded()
                        self.downloads.handleBackgroundURLSessionEvents(completionHandler: completion)
                    }
                }
            }
        }

        networkMonitor.setOnInitialNetworkStateSynced { [weak self] isWiFi in
            guard let self else { return }
            self.playback.isOnWiFi = isWiFi
            self.downloads.updatePolicy(
                wifiOnly: self.settings.wifiOnlyDownload,
                maxManualConcurrent: self.settings.maxConcurrentDownloads,
                isOnWiFi: isWiFi,
                smartDownloadMode: self.settings.smartDownloadMode
            )
        }

        networkMonitor.setOnNetworkTypeChanged { [weak self] isWiFi in
            guard let self else { return }
            self.playback.isOnWiFi = isWiFi
            self.downloads.invalidateResumeDataOnAuthOrNetworkChange()
            Task { await self.coverPipeline.clearNegativeCache() }
            self.downloads.updatePolicy(
                wifiOnly: self.settings.wifiOnlyDownload,
                maxManualConcurrent: self.settings.maxConcurrentDownloads,
                isOnWiFi: isWiFi,
                smartDownloadMode: self.settings.smartDownloadMode
            )
        }

        playback.onRecordListeningDelta = { [weak self] book, delta in
            self?.listeningStats.recordListening(book: book, deltaSeconds: delta)
        }

        downloads.onLocalFilesChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.playback.refreshActiveLocalSourceKind()
            }
        }

        playback.onResolveBookRate = { [weak self] book in
            guard let self else { return 1.0 }
            return self.settings.resolvedPlaybackRate(forBookID: book.id)
        }

        playback.onAutoBookmarkBeforeSleep = { [weak self] book, chapter, positionMs in
            guard let self else { return }
            self.bookmarks.addBookmark(
                bookID: book.id,
                bookTitle: book.title,
                chapterID: chapter.id,
                chapterIndex: chapter.index,
                chapterTitle: chapter.title,
                positionMs: positionMs,
                note: "睡眠定时自动打点",
                kind: .sleepAuto
            )
        }

        playback.onResolveBookQuality = { [weak self] book in
            self?.resolvedQuality(for: book) ?? .auto
        }
        wireNowPlayingArtwork()

        playback.onRequestPrecache = { [weak self] book, upcomingChapters in
            self?.handlePrecacheRequest(book: book, upcomingChapters: upcomingChapters)
        }
    }
}
