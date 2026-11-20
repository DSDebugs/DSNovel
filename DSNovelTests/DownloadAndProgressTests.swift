import XCTest
import SwiftData
@testable import DSNovel

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ initial: Bool = false) {
        self.storage = initial
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

@MainActor
final class FakeDownloadTransport: DownloadTransport {
    var onEvent: ((DownloadTransportEvent) -> Void)?
    var startedDescriptors: [DownloadTaskDescriptor] = []
    var receivedResumeData: [String: Data] = [:]
    var activeIDs: Set<String> = []
    var stubbedPauseData = Data("resume_token".utf8)

    func start(request: URLRequest, descriptor: DownloadTaskDescriptor, resumeData: Data?) {
        startedDescriptors.append(descriptor)
        activeIDs.insert(descriptor.itemID)
        if let resumeData {
            receivedResumeData[descriptor.itemID] = resumeData
        }
    }

    func pause(itemID: String) async -> Data? {
        activeIDs.remove(itemID)
        return stubbedPauseData
    }

    func cancel(itemID: String) {
        activeIDs.remove(itemID)
    }

    func activeTaskItemIDs() async -> Set<String> {
        activeIDs
    }

    func cancelTasksDisallowingMismatch(allowsCellular: Bool) async -> [String] {
        let list = Array(activeIDs)
        activeIDs.removeAll()
        return list
    }
}

final class DownloadAndProgressTests: XCTestCase {

    @MainActor
    @discardableResult
    private func waitUntil(
        timeoutSeconds: TimeInterval = 2.0,
        pollIntervalMs: Int = 10,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(pollIntervalMs))
        }
        return condition()
    }

    @MainActor
    private func assertWaitUntil(
        timeoutSeconds: TimeInterval = 2.0,
        pollIntervalMs: Int = 10,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let ok = await waitUntil(timeoutSeconds: timeoutSeconds, pollIntervalMs: pollIntervalMs, condition: condition)
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    // MARK: - T3-02 ChapterProgress 幂等迁移与淘汰测试

    @MainActor
    func testChapterProgressMigrationAndEviction() throws {
        let suiteName = "test_prog_mig_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let bookID = "src::https://e.com/b1"
        ctx.insert(Book(id: bookID, sourceID: "src", bookURL: "https://e.com/b1", title: "迁移测试书"))
        try ctx.save()

        ChapterProgressStore.save(bookID: bookID, chapterID: "ch1", positionMs: 42_000, defaults: defaults)
        ChapterProgressStore.save(bookID: bookID, chapterID: "ch2", positionMs: 88_000, defaults: defaults)

        let cache = ChapterProgressCache()
        cache.resetMemoryForTesting()
        var backupCalled = 0
        cache.migrateLegacyIfNeeded(context: ctx, defaults: defaults) {
            backupCalled += 1
        }
        XCTAssertEqual(backupCalled, 1)

        // 重复启动幂等，不重复备份或重复插入
        cache.migrateLegacyIfNeeded(context: ctx, defaults: defaults) {
            backupCalled += 1
        }
        XCTAssertEqual(backupCalled, 1)

        let all = try ctx.fetch(FetchDescriptor<ChapterProgress>())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(cache.progress(bookID: bookID, chapterID: "ch1")?.positionMs, 42_000)
    }

    // MARK: - T3-04 & T3-06 DownloadManager 对拍、延迟删除、后台传输测试

    @MainActor
    func testDownloadManagerIncrementalSummaryAndDeferredRemovalAndBackgroundTransport() async throws {
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer { AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelDLTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        manager.customStreamResolver = { item in
            PlayStreamInfo(url: "https://cdn.example.com/\(item.chapterID).mp3", headers: [:], kind: .onDemand, resolvedBy: BuiltinParserRuntime.resolverTag)
        }

        let book = BookRef(sourceID: "s1", bookURL: "https://e.com/1", title: "下载测试书")
        let ch1 = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/ep1")
        let ch2 = ChapterDTO(index: 1, title: "第 2 章", url: "https://e.com/ep2")

        // 1. 磁盘不足预检
        manager.availableDiskBytesProvider = { 1024 }
        XCTAssertThrowsError(try manager.enqueueChaptersWithCheck([ch1], for: book)) { err in
            XCTAssertEqual(err as? DownloadError, .insufficientDisk)
        }

        // 2. 仅 Wi-Fi 开启且非 Wi-Fi 时进入 waitingWiFi
        manager.availableDiskBytesProvider = { 10 * 1024 * 1024 * 1024 }
        AppSettingsStore.shared.wifiOnlyDownload = true
        manager.isOnWiFi = false
        _ = try manager.enqueueChaptersWithCheck([ch1, ch2], for: book)
        let items = try ctx.fetch(FetchDescriptor<DownloadItem>())
        XCTAssertTrue(items.allSatisfy { $0.state == "waitingWiFi" })

        // 3. 恢复 Wi-Fi 后入队并由 FakeTransport 接收
        manager.isOnWiFi = true
        await manager.handleWiFiOnlySettingChanged(false)
        let started = await waitUntil { !fakeTransport.startedDescriptors.isEmpty }
        XCTAssertTrue(started)

        // 4. 模拟后台下载完成（有效二进制音频 >= 1024 字节）
        let firstDesc = fakeTransport.startedDescriptors[0]
        let stagedFile = tempDir.appendingPathComponent("staged_ok.mp3")
        try Data(repeating: 0xAB, count: 4096).write(to: stagedFile)
        fakeTransport.onEvent?(.finished(descriptor: firstDesc, tempFileURL: stagedFile, statusCode: 200, mimeType: "audio/mpeg"))
        let completed = await waitUntil {
            manager.downloadState(bookID: book.id, chapterID: firstDesc.chapterID) == .completed
        }
        XCTAssertTrue(completed)

        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount, 1)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.totalBytes, 4096)
        XCTAssertEqual(manager.downloadState(bookID: book.id, chapterID: firstDesc.chapterID), .completed)

        // 5. 单章删除后状态立即回退为 .notDownloaded（消除绿勾残留 Bug）
        let deleted = manager.invalidateLocalFile(bookID: book.id, chapterID: firstDesc.chapterID)
        XCTAssertTrue(deleted)
        XCTAssertEqual(manager.downloadState(bookID: book.id, chapterID: firstDesc.chapterID), .notDownloaded)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount ?? 0, 0)
    }

    // MARK: - T3-05 AppSettingsStore.resetAll 覆盖性与 LaunchBehavior 迁移

    @MainActor
    func testAppSettingsStoreResetCoverageAndLaunchBehavior() {
        XCTAssertEqual(LaunchBehavior.migrate(fromLegacyAutoResume: true), .autoPlay)
        XCTAssertEqual(LaunchBehavior.migrate(fromLegacyAutoResume: false), .restorePaused)
        XCTAssertEqual(LaunchBehavior.migrate(fromLegacyAutoResume: nil), .restorePaused)

        let suite = "test_settings_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppSettingsStore(defaults: defaults)
        store.defaultSpeed = 2.0
        store.currentDiscoverSourceID = "custom_src"
        store.nightDimEnabled = true
        store.reduceMotionOverride = true
        store.resetAll()

        XCTAssertEqual(store.defaultSpeed, 1.0)
        XCTAssertEqual(store.currentDiscoverSourceID, "custom_src")
        XCTAssertFalse(store.nightDimEnabled)
        XCTAssertFalse(store.reduceMotionOverride)
        XCTAssertEqual(store.launchBehavior, .restorePaused)
        XCTAssertEqual(store.audioQualityTier, .hd)
        XCTAssertEqual(store.audioEffectPreset, .original)
        XCTAssertEqual(AppSettingsStore.allResettablePropertyNames.count, 21)

        // 验证 PlayerEngine.prepare 不进入 playing 状态
        let player = PlayerEngine.shared
        let book = BookRef(sourceID: "s", bookURL: "u", title: "测试")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "u/1", durationSec: 300)
        player.prepare(book: book, chapters: [ch], chapter: ch, positionMs: 15_000)
        XCTAssertNotEqual(player.state, .playing)
        XCTAssertEqual(player.state, .paused)

        // 验证 setSpeed 吸附到 0.05 与睡眠文案为「章」
        player.setSpeed(1.26, persist: false)
        XCTAssertEqual(player.speed, 1.25, accuracy: 0.001)
        XCTAssertEqual(SleepTimerOption.chaptersRemaining(3).label, "3 章后")
    }

    // MARK: - 书籍详情页已下载章节优先展示、跨分段定位与 ChapterRow 零重绘测试

    @MainActor
    func testBookDetailDownloadPriorityCrossSegmentLocateAndChapterRowEquatable() {
        let book = BookRef(sourceID: "xm", bookURL: "https://e.com/9zone", title: "第九特区")
        let chapters = (0..<600).map { i in
            ChapterDTO(index: i, title: "第 \(i + 1) 章", url: "https://e.com/ep/\(i + 1)", durationSec: 600)
        }
        let model = BookDetailModel(book: book)
        model.applyChapters(chapters)

        // 1. 当存在已下载章节时，进入页面默认开启 isShowingDownloadedOnly 优先展示已下载章节，并将分段对齐到第 502 章所在区间 (501–600, index 5)
        model.applyInitialPresentationIfNeeded(
            downloadedCount: 2,
            activeDownloadCount: 0,
            activeChapterID: chapters[501].id,
            savedChapterID: nil,
            savedChapterIndex: 502
        )
        XCTAssertTrue(model.isShowingDownloadedOnly)
        XCTAssertEqual(model.selectedSegmentIndex, 5)

        // 2. 用户切到 1–100 分段或处于已下载章节视图时，点击定位按钮应自动切回第 502 章所在的 501–600 分段 (index 5)
        model.selectedSegmentIndex = 0
        model.isShowingDownloadedOnly = true
        model.chapterSearchKeyword = "关键词"
        let located = model.prepareToLocateChapter(
            currentPlayingChapterID: chapters[501].id,
            savedChapterID: nil,
            savedChapterIndex: nil
        )
        XCTAssertEqual(located?.targetID, chapters[501].id)
        XCTAssertEqual(located?.didSwitchContext, true)
        XCTAssertFalse(model.isShowingDownloadedOnly)
        XCTAssertEqual(model.chapterSearchKeyword, "")
        XCTAssertEqual(model.selectedSegmentIndex, 5)

        // 3. 实时播放秒数注入：正在播放第 502 章且实时进度为 33,000ms 时，快照应实时反映 33,000ms
        let snaps = model.visibleChapterSnapshots(
            currentPlayingChapterID: chapters[501].id,
            isEnginePlaying: true,
            currentPlayingPositionMs: 33_000
        )
        let activeSnap = snaps.first(where: { $0.id == chapters[501].id })
        XCTAssertEqual(activeSnap?.savedPositionMs, 33_000)
        XCTAssertTrue(activeSnap?.subtitleText.contains("已播") == true)

        // 4. ChapterRow Equatable：非当前章节快照相等，推进播放时钟不触发非当前行重绘
        let snapA = ChapterRowSnapshot(
            chapter: chapters[0],
            displayIndex: 1,
            isCurrentPlayingChapter: false,
            isEnginePlaying: true,
            savedPositionMs: 0,
            isFinished: false,
            isVIP: false,
            downloadState: .notDownloaded
        )
        let snapB = ChapterRowSnapshot(
            chapter: chapters[0],
            displayIndex: 1,
            isCurrentPlayingChapter: false,
            isEnginePlaying: true,
            savedPositionMs: 0,
            isFinished: false,
            isVIP: false,
            downloadState: .notDownloaded
        )
        XCTAssertEqual(ChapterRow(snapshot: snapA), ChapterRow(snapshot: snapB))
    }

    // MARK: - b78 A1/A2/A3/A4/A5 音质档位重下、状态机刷新、旧文件保底与空路径对账测试

    @MainActor
    func testA5EmptyLocalPathIsNotVerifiedAndReconciled() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelA5Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true

        let bookID = "s1::https://e.com/a5"
        let emptyItem = DownloadItem(
            id: "\(bookID)::https://e.com/ep_empty",
            bookID: bookID,
            bookTitle: "A5 测试书",
            chapterID: "https://e.com/ep_empty",
            chapterTitle: "空路径脏记录",
            sourceID: "s1",
            kind: "manual",
            state: "completed",
            localPath: "",
            bytes: 2048,
            qualityTierSnapshot: AudioQualityTier.hd.rawValue
        )
        let fixtureItem = DownloadItem(
            id: "\(bookID)::https://e.com/ep_fixture",
            bookID: bookID,
            bookTitle: "A5 测试书",
            chapterID: "https://e.com/ep_fixture",
            chapterTitle: "Fixture 兼容记录",
            sourceID: "s1",
            kind: "manual",
            state: "completed",
            localPath: "fixture/sample.mp3",
            bytes: 4096,
            qualityTierSnapshot: AudioQualityTier.hd.rawValue
        )
        ctx.insert(emptyItem)
        ctx.insert(fixtureItem)
        try ctx.save()

        manager.reconcileCompletedFiles()

        let remaining = try ctx.fetch(FetchDescriptor<DownloadItem>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.chapterID, "https://e.com/ep_fixture")
        XCTAssertEqual(manager.downloadState(bookID: bookID, chapterID: "https://e.com/ep_empty"), .notDownloaded)
        XCTAssertEqual(manager.downloadState(bookID: bookID, chapterID: "https://e.com/ep_fixture"), .completed)
    }

    @MainActor
    func testA1StaleMarkingRefreshAndRollbackPreservesOldFile() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelA1Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false
        AppSettingsStore.shared.audioQualityTier = .std

        let shouldFailResolve = AtomicBool(false)
        manager.customStreamResolver = { item in
            if shouldFailResolve.value {
                throw PluginError.network("模拟断网")
            }
            return PlayStreamInfo(url: "https://cdn.example.com/\(item.chapterID).mp3", headers: [:], kind: .onDemand)
        }

        let book = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/a1", title: "A1 测试书")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/a1/ep1", durationSec: 600)
        _ = try manager.enqueueChaptersWithCheck([ch], for: book)
        let firstStarted = await waitUntil { !fakeTransport.startedDescriptors.isEmpty }
        XCTAssertTrue(firstStarted)

        guard let firstDesc = fakeTransport.startedDescriptors.first else {
            XCTFail("应启动首次下载")
            return
        }
        let stagedOld = tempDir.appendingPathComponent("old_saver.mp3")
        try Data(repeating: 0x11, count: 2048).write(to: stagedOld)
        fakeTransport.onEvent?(.finished(descriptor: firstDesc, tempFileURL: stagedOld, statusCode: 200, mimeType: "audio/mpeg"))
        let firstCompleted = await waitUntil {
            manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed
        }
        XCTAssertTrue(firstCompleted)

        XCTAssertEqual(manager.staleCompletedCount(forBookID: book.id), 0)
        XCTAssertFalse(manager.isChapterQualityStale(bookID: book.id, chapterID: ch.id))

        // 切换到高清档位并再次入队：应标记过期且保留旧文件
        AppSettingsStore.shared.audioQualityTier = .hd
        let added = try manager.enqueueChaptersWithCheck([ch], for: book)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(manager.staleCompletedCount(forBookID: book.id), 1)
        XCTAssertTrue(manager.isChapterQualityStale(bookID: book.id, chapterID: ch.id))
        let localBefore = manager.localFileInfo(bookID: book.id, chapterID: ch.id)
        XCTAssertNotNil(localBefore)
        XCTAssertEqual(localBefore?.tierRaw, AudioQualityTier.std.rawValue)
        XCTAssertEqual(localBefore?.isStale, true)

        // 模拟重下失败（超过重试上限）：重下窗口内旧文件保持可播，失败后自动回滚为 completed + qualityIsStale
        shouldFailResolve.value = true
        let refreshed = manager.refreshStaleQualityItems(bookID: book.id, chapterIDs: [ch.id])
        XCTAssertEqual(refreshed, 1)

        // D-1：重下刚启动时旧文件即可播且识别为旧档位
        let localDuringReDL = manager.localFileInfo(bookID: book.id, chapterID: ch.id)
        XCTAssertNotNil(localDuringReDL)
        XCTAssertEqual(localDuringReDL?.tierRaw, AudioQualityTier.std.rawValue)
        XCTAssertEqual(localDuringReDL?.isStale, true)
        if case .downloading = manager.downloadState(bookID: book.id, chapterID: ch.id) {
            // expected
        } else {
            XCTFail("重下刚触发时应处于 downloading 状态")
        }

        let rolledBack = await waitUntil(timeoutSeconds: 2.0) {
            manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed
        }
        XCTAssertTrue(rolledBack, "重下失败超过重试上限后应在超时内回滚为 completed")

        let localAfterFail = manager.localFileInfo(bookID: book.id, chapterID: ch.id)
        XCTAssertNotNil(localAfterFail, "重下失败后必须保留旧离线文件可播")
        XCTAssertEqual(localAfterFail?.isStale, true)
        XCTAssertEqual(localAfterFail?.tierRaw, AudioQualityTier.std.rawValue)
        XCTAssertEqual(manager.downloadState(bookID: book.id, chapterID: ch.id), .completed)
    }

    @MainActor
    func testA2A4RetryAndResumeRefreshTierAndClearResumeData() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelA2A4Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = false
        AppSettingsStore.shared.wifiOnlyDownload = true
        AppSettingsStore.shared.audioQualityTier = .std

        let bookID = "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64::https://e.com/a2"
        let pausedItem = DownloadItem(
            id: "\(bookID)::ep_paused",
            bookID: bookID,
            bookTitle: "A2 测试书",
            chapterID: "ep_paused",
            chapterTitle: "暂停章",
            sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
            kind: "manual",
            state: "paused",
            qualityTierSnapshot: AudioQualityTier.std.rawValue
        )
        let failedItem = DownloadItem(
            id: "\(bookID)::ep_failed",
            bookID: bookID,
            bookTitle: "A2 测试书",
            chapterID: "ep_failed",
            chapterTitle: "失败章",
            sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
            kind: "manual",
            state: "failed",
            retryCount: 2,
            qualityTierSnapshot: AudioQualityTier.std.rawValue
        )
        ctx.insert(pausedItem)
        ctx.insert(failedItem)
        try ctx.save()
        manager.rebuildSummariesFromContext()

        manager.saveResumeData(Data("old_resume".utf8), for: pausedItem.id)
        XCTAssertNotNil(manager.loadResumeData(for: pausedItem.id))

        // 切换音质后恢复与重试，应刷新 qualityTierSnapshot 并清理旧 resumeData
        AppSettingsStore.shared.audioQualityTier = .hd
        manager.resumeItem(pausedItem)
        manager.retryFailedItem(failedItem)

        XCTAssertEqual(pausedItem.qualityTierSnapshot, AudioQualityTier.hd.rawValue)
        XCTAssertNil(manager.loadResumeData(for: pausedItem.id))
        XCTAssertEqual(failedItem.qualityTierSnapshot, AudioQualityTier.hd.rawValue)
        XCTAssertEqual(failedItem.retryCount, 0)
    }

    @MainActor
    func testA3PrecachePromoteToManualMarksStaleWhenTierChanged() throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        defer { AppSettingsStore.shared.audioQualityTier = originalTier }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelA3Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true

        let book = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/a3", title: "A3 测试书")
        let ch = ChapterDTO(index: 0, title: "预缓存章", url: "https://e.com/a3/ep1", durationSec: 420)
        let precacheItem = DownloadItem(
            id: "\(book.id)::\(ch.id)",
            bookID: book.id,
            bookTitle: book.title,
            chapterID: ch.id,
            chapterTitle: ch.title,
            sourceID: book.sourceID,
            kind: "precache",
            state: "completed",
            localPath: "fixture/precache.mp3",
            bytes: 1024,
            qualityTierSnapshot: AudioQualityTier.std.rawValue
        )
        ctx.insert(precacheItem)
        try ctx.save()
        manager.rebuildSummariesFromContext()

        AppSettingsStore.shared.audioQualityTier = .hd
        let added = try manager.enqueueChaptersWithCheck([ch], for: book, kind: "manual")

        XCTAssertEqual(added, 1)
        XCTAssertEqual(precacheItem.kind, "manual")
        XCTAssertTrue(precacheItem.qualityIsStale)
        XCTAssertEqual(precacheItem.expectedDurationSec, 420)
        XCTAssertTrue(manager.isChapterQualityStale(bookID: book.id, chapterID: ch.id))
    }

    // MARK: - b79 D-3 rollbackTierByItemID 生命周期清理测试

    @MainActor
    func testD3RollbackTierClearedOnEveryDeletionPath() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelD3Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = false
        AppSettingsStore.shared.wifiOnlyDownload = true
        AppSettingsStore.shared.audioQualityTier = .hd

        func seedStaleReDownload(bookID: String, chapterID: String, createRealFile: Bool = false) throws -> DownloadItem {
            let relPath: String
            if createRealFile {
                let dir = tempDir.appendingPathComponent(JsHostBridge.md5Hex(bookID), isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("\(JsHostBridge.md5Hex(chapterID)).mp3")
                try Data(repeating: 0x22, count: 2048).write(to: file)
                relPath = "\(JsHostBridge.md5Hex(bookID))/\(JsHostBridge.md5Hex(chapterID)).mp3"
            } else {
                relPath = "fixture/\(chapterID).mp3"
            }
            let item = DownloadItem(
                id: "\(bookID)::\(chapterID)",
                bookID: bookID,
                bookTitle: "D3 测试书",
                chapterID: chapterID,
                chapterTitle: chapterID,
                sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
                kind: "manual",
                state: "completed",
                localPath: relPath,
                bytes: 2048,
                qualityTierSnapshot: AudioQualityTier.std.rawValue
            )
            ctx.insert(item)
            try ctx.save()
            let refreshed = manager.refreshStaleQualityItems(bookID: bookID, chapterIDs: [chapterID])
            XCTAssertEqual(refreshed, 1)
            XCTAssertEqual(manager.rollbackTierForTesting(itemID: item.id), AudioQualityTier.std.rawValue)
            return item
        }

        // 1. invalidateLocalFile
        let item1 = try seedStaleReDownload(bookID: "s1::b1", chapterID: "ep1")
        XCTAssertTrue(manager.invalidateLocalFile(bookID: "s1::b1", chapterID: "ep1"))
        XCTAssertNil(manager.rollbackTierForTesting(itemID: item1.id))

        // 2. removeDownloads(forBookID:)
        let item2 = try seedStaleReDownload(bookID: "s1::b2", chapterID: "ep2")
        manager.removeDownloads(forBookID: "s1::b2")
        XCTAssertNil(manager.rollbackTierForTesting(itemID: item2.id))

        // 3. cleanupPrecacheIfNeeded
        let item3 = try seedStaleReDownload(bookID: "s1::b3", chapterID: "ep3")
        item3.kind = "precache"
        try ctx.save()
        manager.cleanupPrecacheIfNeeded(bookID: "s1::b3", chapterID: "ep3")
        XCTAssertNil(manager.rollbackTierForTesting(itemID: item3.id))

        // 4. clearPrecacheOnly
        let item4 = try seedStaleReDownload(bookID: "s1::b4", chapterID: "ep4")
        item4.kind = "precache"
        try ctx.save()
        manager.clearPrecacheOnly()
        XCTAssertNil(manager.rollbackTierForTesting(itemID: item4.id))

        // 5. dropQueuedPrecache
        let item5 = try seedStaleReDownload(bookID: "s1::b5", chapterID: "ep5")
        item5.kind = "precache"
        item5.state = "queued"
        try ctx.save()
        manager.dropQueuedPrecache()
        XCTAssertNil(manager.rollbackTierForTesting(itemID: item5.id))

        // 6. rebuildSummariesFromContext 兜底清扫
        let item6 = try seedStaleReDownload(bookID: "s1::b6", chapterID: "ep6")
        ctx.delete(item6)
        try ctx.save()
        manager.rebuildSummariesFromContext()
        XCTAssertNil(manager.rollbackTierForTesting(itemID: item6.id))

        // 7. pauseAllActive：旧文件存在时保留 rollback，旧文件消失时移除 rollback
        let itemKeep = try seedStaleReDownload(bookID: "s1::b7", chapterID: "ep_keep", createRealFile: true)
        let itemGone = try seedStaleReDownload(bookID: "s1::b7", chapterID: "ep_gone", createRealFile: true)
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent(itemGone.localPath))
        await manager.pauseAllActive()
        XCTAssertEqual(manager.rollbackTierForTesting(itemID: itemKeep.id), AudioQualityTier.std.rawValue)
        XCTAssertNil(manager.rollbackTierForTesting(itemID: itemGone.id))

        manager.removeDownloads(forBookID: "s1::b7")
        XCTAssertEqual(manager.rollbackTierCountForTesting, 0)
    }

    @MainActor
    func testD3RollbackTierNotLeakedAcrossIDReuse() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelD3Reuse_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false

        let shouldFail = AtomicBool(false)
        manager.customStreamResolver = { item in
            if shouldFail.value { throw PluginError.network("模拟失败") }
            return PlayStreamInfo(url: "https://cdn.example.com/\(item.chapterID).mp3", headers: [:], kind: .onDemand)
        }

        let book = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/reuse", title: "ID 复用书")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/reuse/ep1")

        // 第一轮：标准落盘 -> 切高清触发重下（写入 standard 到 rollback 表）-> 删除条目
        AppSettingsStore.shared.audioQualityTier = .std
        _ = try manager.enqueueChaptersWithCheck([ch], for: book)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 1 }
        let staged1 = tempDir.appendingPathComponent("round1.mp3")
        try Data(repeating: 0x31, count: 2048).write(to: staged1)
        fakeTransport.onEvent?(.finished(descriptor: fakeTransport.startedDescriptors[0], tempFileURL: staged1, statusCode: 200, mimeType: "audio/mpeg"))
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }

        AppSettingsStore.shared.audioQualityTier = .hd
        AppSettingsStore.shared.wifiOnlyDownload = true
        manager.isOnWiFi = false
        XCTAssertEqual(manager.refreshStaleQualityItems(bookID: book.id, chapterIDs: [ch.id]), 1)
        XCTAssertEqual(manager.rollbackTierForTesting(itemID: "\(book.id)::\(ch.id)"), AudioQualityTier.std.rawValue)

        XCTAssertTrue(manager.invalidateLocalFile(bookID: book.id, chapterID: ch.id))
        XCTAssertNil(manager.rollbackTierForTesting(itemID: "\(book.id)::\(ch.id)"))

        // 第二轮：同 ID 以高清档位重新下载完成 -> 切超清重下失败 -> 应回滚为 high，绝不能泄漏第一轮的 standard
        AppSettingsStore.shared.wifiOnlyDownload = false
        manager.isOnWiFi = true
        AppSettingsStore.shared.audioQualityTier = .hd
        _ = try manager.enqueueChaptersWithCheck([ch], for: book)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 2 }
        let staged2 = tempDir.appendingPathComponent("round2.mp3")
        try Data(repeating: 0x32, count: 2048).write(to: staged2)
        fakeTransport.onEvent?(.finished(descriptor: fakeTransport.startedDescriptors[1], tempFileURL: staged2, statusCode: 200, mimeType: "audio/mpeg"))
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }

        AppSettingsStore.shared.audioQualityTier = .uhd
        shouldFail.value = true
        XCTAssertEqual(manager.refreshStaleQualityItems(bookID: book.id, chapterIDs: [ch.id]), 1)
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }

        let info = manager.localFileInfo(bookID: book.id, chapterID: ch.id)
        XCTAssertEqual(info?.tierRaw, AudioQualityTier.hd.rawValue)
    }

    // MARK: - b79 D-5 added 双计修复测试

    @MainActor
    func testD5PrecacheFailedPromoteCountsOnce() throws {
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer { AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        manager.modelContext = ctx
        manager.isOnWiFi = false
        AppSettingsStore.shared.wifiOnlyDownload = true

        let book = BookRef(sourceID: "s1", bookURL: "https://e.com/d5f", title: "D5 失败预缓存")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/d5f/ep1")
        let precacheFailed = DownloadItem(
            id: "\(book.id)::\(ch.id)",
            bookID: book.id,
            bookTitle: book.title,
            chapterID: ch.id,
            chapterTitle: ch.title,
            sourceID: book.sourceID,
            kind: "precache",
            state: "failed",
            retryCount: 2
        )
        ctx.insert(precacheFailed)
        try ctx.save()

        let added = try manager.enqueueChaptersWithCheck([ch], for: book, kind: "manual")
        XCTAssertEqual(added, 1, "预缓存失败条目提升为手动下载并重入队时只能计 1 次")
        XCTAssertEqual(precacheFailed.kind, "manual")
        XCTAssertEqual(precacheFailed.state, "waitingWiFi")
    }

    @MainActor
    func testD5PrecacheCompletedMissingFileCountsOnce() throws {
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer { AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelD5Miss_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = false
        AppSettingsStore.shared.wifiOnlyDownload = true

        let book = BookRef(sourceID: "s1", bookURL: "https://e.com/d5m", title: "D5 丢文件预缓存")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/d5m/ep1")
        let precacheMissing = DownloadItem(
            id: "\(book.id)::\(ch.id)",
            bookID: book.id,
            bookTitle: book.title,
            chapterID: ch.id,
            chapterTitle: ch.title,
            sourceID: book.sourceID,
            kind: "precache",
            state: "completed",
            localPath: "nonexistent/missing.mp3",
            bytes: 4096
        )
        ctx.insert(precacheMissing)
        try ctx.save()

        let added = try manager.enqueueChaptersWithCheck([ch], for: book, kind: "manual")
        XCTAssertEqual(added, 1, "已完成但文件缺失的预缓存条目提升为手动下载时只能计 1 次")
        XCTAssertEqual(precacheMissing.kind, "manual")
        XCTAssertEqual(precacheMissing.localPath, "")
        XCTAssertEqual(precacheMissing.state, "waitingWiFi")
    }

    // MARK: - b79 D-4 单章重下跳过预缓存测试

    @MainActor
    func testD4ChapterScopedRefreshSkipsPrecacheItems() throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        defer { AppSettingsStore.shared.audioQualityTier = originalTier }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        manager.modelContext = ctx
        manager.isOnWiFi = true

        let bookID = "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64::https://e.com/d4"
        let chID = "https://e.com/d4/ep1"
        let precacheItem = DownloadItem(
            id: "\(bookID)::\(chID)",
            bookID: bookID,
            bookTitle: "D4 预缓存书",
            chapterID: chID,
            chapterTitle: "第 1 章",
            sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
            kind: "precache",
            state: "completed",
            localPath: "fixture/d4_pre.mp3",
            bytes: 2048,
            qualityTierSnapshot: AudioQualityTier.std.rawValue
        )
        ctx.insert(precacheItem)
        try ctx.save()
        manager.rebuildSummariesFromContext()
        XCTAssertEqual(manager.cachedPrecacheBytes, 2048)

        AppSettingsStore.shared.audioQualityTier = .hd
        let refreshed = manager.refreshStaleQualityItems(bookID: bookID, chapterIDs: [chID])

        XCTAssertEqual(refreshed, 0)
        XCTAssertEqual(precacheItem.state, "completed")
        XCTAssertEqual(precacheItem.kind, "precache")
        XCTAssertEqual(manager.cachedPrecacheBytes, 2048)
    }

    // MARK: - b79 D-1 重下窗口旧文件可播与计入统计测试

    @MainActor
    func testD1RedownloadKeepsOldFilePlayableAndCounted() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelD1Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false
        AppSettingsStore.shared.audioQualityTier = .std
        manager.customStreamResolver = { item in
            PlayStreamInfo(url: "https://cdn.example.com/\(item.chapterID).mp3", headers: [:], kind: .onDemand)
        }

        let book = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/d1", title: "D1 测试书")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/d1/ep1")
        _ = try manager.enqueueChaptersWithCheck([ch], for: book)
        await assertWaitUntil { !fakeTransport.startedDescriptors.isEmpty }

        let staged = tempDir.appendingPathComponent("d1_old.mp3")
        try Data(repeating: 0x44, count: 3072).write(to: staged)
        fakeTransport.onEvent?(.finished(descriptor: fakeTransport.startedDescriptors[0], tempFileURL: staged, statusCode: 200, mimeType: "audio/mpeg"))
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }

        // 切高清并触发重下（保持在 waitingWiFi/downloading 窗口内）
        AppSettingsStore.shared.audioQualityTier = .hd
        AppSettingsStore.shared.wifiOnlyDownload = true
        manager.isOnWiFi = false
        let refreshed = manager.refreshStaleQualityItems(bookID: book.id, chapterIDs: [ch.id])
        XCTAssertEqual(refreshed, 1)

        let info = manager.localFileInfo(bookID: book.id, chapterID: ch.id)
        XCTAssertNotNil(info, "重下窗口内旧文件仍应可播")
        XCTAssertEqual(info?.tierRaw, AudioQualityTier.std.rawValue)
        XCTAssertEqual(info?.isStale, true)
        XCTAssertTrue(manager.isReDownloading(bookID: book.id, chapterID: ch.id))
        // P0：重下中不计入 completedCount（与已下载列表口径互斥），但离线占用 totalBytes 仍包含旧文件
        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount, 0)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.totalBytes, 3072)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.activeCount, 1)

        // 全量重建摘要后仍应保持可播与统计口径一致
        manager.rebuildSummariesFromContext()
        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount, 0)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.totalBytes, 3072)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.activeCount, 1)
        XCTAssertTrue(manager.isReDownloading(bookID: book.id, chapterID: ch.id))

        // 重下完成后：completedCount 恢复为 1、activeCount 归 0
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false
        await manager.handleWiFiOnlySettingChanged(false)
        await assertWaitUntil { fakeTransport.startedDescriptors.count >= 2 }
        let stagedNew = FileManager.default.temporaryDirectory.appendingPathComponent("d1_new_\(UUID().uuidString).mp3")
        try Data(repeating: 0x45, count: 4096).write(to: stagedNew)
        fakeTransport.onEvent?(.finished(descriptor: fakeTransport.startedDescriptors[1], tempFileURL: stagedNew, statusCode: 200, mimeType: "audio/mpeg"))
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }
        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount, 1)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.activeCount, 0)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.totalBytes, 4096)
    }

    @MainActor
    func testD1MissingFileDuringReDownloadDoesNotDeleteItem() throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelD1Miss_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = false
        AppSettingsStore.shared.wifiOnlyDownload = true
        AppSettingsStore.shared.audioQualityTier = .hd

        let bookID = "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64::https://e.com/d1miss"
        let chID = "https://e.com/d1miss/ep1"
        let relDir = tempDir.appendingPathComponent(JsHostBridge.md5Hex(bookID), isDirectory: true)
        try FileManager.default.createDirectory(at: relDir, withIntermediateDirectories: true)
        let fileURL = relDir.appendingPathComponent("\(JsHostBridge.md5Hex(chID)).mp3")
        try Data(repeating: 0x55, count: 2048).write(to: fileURL)
        let relPath = "\(JsHostBridge.md5Hex(bookID))/\(JsHostBridge.md5Hex(chID)).mp3"

        let item = DownloadItem(
            id: "\(bookID)::\(chID)",
            bookID: bookID,
            bookTitle: "D1 缺失保护",
            chapterID: chID,
            chapterTitle: "第 1 章",
            sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
            kind: "manual",
            state: "completed",
            localPath: relPath,
            bytes: 2048,
            qualityTierSnapshot: AudioQualityTier.std.rawValue
        )
        ctx.insert(item)
        try ctx.save()

        XCTAssertEqual(manager.refreshStaleQualityItems(bookID: bookID, chapterIDs: [chID]), 1)
        XCTAssertEqual(item.state, "waitingWiFi")

        // 重下进行中磁盘旧文件被移除：localFileInfo 返回 nil，但绝不能删除进行中的记录
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertNil(manager.localFileInfo(bookID: bookID, chapterID: chID))

        let remaining = try ctx.fetch(FetchDescriptor<DownloadItem>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.state, "waitingWiFi")
    }

    // MARK: - b79 D-6a & D-6b 重下窗口旧音质角标与断点续传闭环测试

    @MainActor
    func testD6StaleBadgeSurvivesReDownloadWindow() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelD6Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false
        AppSettingsStore.shared.audioQualityTier = .std
        manager.customStreamResolver = { item in
            PlayStreamInfo(url: "https://cdn.example.com/\(item.chapterID).mp3", headers: [:], kind: .onDemand)
        }

        let book = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/d6", title: "D6 角标书")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/d6/ep1")
        _ = try manager.enqueueChaptersWithCheck([ch], for: book)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 1 }

        let stagedOld = tempDir.appendingPathComponent("d6_old.mp3")
        try Data(repeating: 0x61, count: 2048).write(to: stagedOld)
        fakeTransport.onEvent?(.finished(descriptor: fakeTransport.startedDescriptors[0], tempFileURL: stagedOld, statusCode: 200, mimeType: "audio/mpeg"))
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }

        // 切高清并触发重下
        AppSettingsStore.shared.audioQualityTier = .hd
        XCTAssertEqual(manager.refreshStaleQualityItems(bookID: book.id, chapterIDs: [ch.id]), 1)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 2 }

        let item = try XCTUnwrap(try ctx.fetch(FetchDescriptor<DownloadItem>()).first)
        XCTAssertTrue(manager.isReDownloading(bookID: book.id, chapterID: ch.id))
        XCTAssertEqual(manager.staleCompletedCount(forBookID: book.id), 1)
        XCTAssertTrue(manager.isChapterQualityStale(bookID: book.id, chapterID: ch.id))
        XCTAssertTrue(DownloadsDataHelper.isItemStale(item, currentTierRaw: AudioQualityTier.hd.rawValue))

        // 重下期间暂停再恢复：角标保持可见，且新生成的 resumeData 不应被误丢弃
        await manager.pauseItem(item)
        XCTAssertTrue(manager.isChapterQualityStale(bookID: book.id, chapterID: ch.id))
        XCTAssertNotNil(manager.loadResumeData(for: item.id))

        manager.resumeItem(item)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 3 }
        XCTAssertEqual(fakeTransport.receivedResumeData[item.id], fakeTransport.stubbedPauseData)
        XCTAssertTrue(manager.isChapterQualityStale(bookID: book.id, chapterID: ch.id))

        // 新音质落盘成功后清除旧音质标记
        let stagedNew = tempDir.appendingPathComponent("d6_new.mp3")
        try Data(repeating: 0x62, count: 4096).write(to: stagedNew)
        fakeTransport.onEvent?(.finished(descriptor: fakeTransport.startedDescriptors[2], tempFileURL: stagedNew, statusCode: 200, mimeType: "audio/mpeg"))
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }

        XCTAssertEqual(manager.staleCompletedCount(forBookID: book.id), 0)
        XCTAssertFalse(manager.isChapterQualityStale(bookID: book.id, chapterID: ch.id))
        XCTAssertFalse(DownloadsDataHelper.isItemStale(item, currentTierRaw: AudioQualityTier.hd.rawValue))
    }

    // MARK: - b79 D-8 离线角标按实际链码显示测试

    @MainActor
    func testD8OfflineBadgeUsesActualChainCode() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelD8Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false
        AppSettingsStore.shared.audioQualityTier = .uhd

        let book = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/d8", title: "D8 链码书")
        let chSource = ChapterDTO(index: 0, title: "书源链章", url: "https://e.com/d8/src")
        let chParser = ChapterDTO(index: 1, title: "解析器链章", url: "https://e.com/d8/parser")

        manager.customStreamResolver = { item in
            let resolver = item.chapterID == chParser.id ? BuiltinParserRuntime.resolverTag : "bookSource"
            return PlayStreamInfo(url: "https://cdn.example.com/\(item.chapterID).m4a", headers: [:], kind: .onDemand, resolvedBy: resolver)
        }

        _ = try manager.enqueueChaptersWithCheck([chSource, chParser], for: book)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 2 }

        for (idx, desc) in fakeTransport.startedDescriptors.enumerated() {
            let staged = tempDir.appendingPathComponent("d8_\(idx).m4a")
            try Data(repeating: 0x77, count: 2048).write(to: staged)
            fakeTransport.onEvent?(.finished(descriptor: desc, tempFileURL: staged, statusCode: 200, mimeType: "audio/mp4"))
        }
        await assertWaitUntil {
            manager.downloadState(bookID: book.id, chapterID: chSource.id) == .completed
                && manager.downloadState(bookID: book.id, chapterID: chParser.id) == .completed
        }

        let all = try ctx.fetch(FetchDescriptor<DownloadItem>())
        let srcItem = try XCTUnwrap(all.first(where: { $0.chapterID == chSource.id }))
        let parserItem = try XCTUnwrap(all.first(where: { $0.chapterID == chParser.id }))

        XCTAssertEqual(srcItem.qualityCodeSnapshot, "M4A_128")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forItem: srcItem), "超清")
        XCTAssertFalse(parserItem.qualityCodeSnapshot.isEmpty)
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forItem: parserItem), "超清")
    }

    @MainActor
    func testD8LegacyItemsFallBackToTierLabel() {
        let legacyLossless = DownloadItem(
            id: "s1::b::ep1",
            bookID: "s1::b",
            bookTitle: "老记录书",
            chapterID: "ep1",
            chapterTitle: "第 1 章",
            sourceID: "s1",
            qualityTierSnapshot: AudioQualityTier.uhd.rawValue,
            qualityCodeSnapshot: ""
        )
        let legacySaver = DownloadItem(
            id: "s1::b::ep2",
            bookID: "s1::b",
            bookTitle: "老记录书",
            chapterID: "ep2",
            chapterTitle: "第 2 章",
            sourceID: "s1",
            qualityTierSnapshot: AudioQualityTier.std.rawValue,
            qualityCodeSnapshot: ""
        )

        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forItem: legacyLossless), "超清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forItem: legacySaver), "标准")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "M4A_24"), "标准")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "saver"), "标准")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "M4A_64"), "高清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "standard"), "高清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "M4A_128"), "超清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "high"), "超清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "lossless"), "超清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "std"), "标准")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "hd"), "高清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: "uhd"), "超清")
        XCTAssertEqual(DownloadsDataHelper.qualityLabel(forChainCode: ""), "")
    }

    // MARK: - b79 D-2 孤儿文件安全对账清理测试

    func testD2OrphanFileSweepKeepsWhitelistedAndFreshFiles() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("DSNovelD2Sweep_\(UUID().uuidString)", isDirectory: true)
        let bookDir = tempDir.appendingPathComponent("bookhash", isDirectory: true)
        try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let whitelistedFile = bookDir.appendingPathComponent("keepchap.m4a")
        let freshOrphanFile = bookDir.appendingPathComponent("freshorphan.mp3")
        let oldOrphanFile = bookDir.appendingPathComponent("oldorphan.mp3")

        try Data(repeating: 0x01, count: 128).write(to: whitelistedFile)
        try Data(repeating: 0x02, count: 128).write(to: freshOrphanFile)
        try Data(repeating: 0x03, count: 128).write(to: oldOrphanFile)

        let oldDate = Date().addingTimeInterval(-3600)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: whitelistedFile.path)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldOrphanFile.path)

        let removed = await DownloadFileProcessor.shared.cleanupOrphanFiles(
            root: tempDir,
            whitelistKeys: ["bookhash/keepchap"],
            minAgeSeconds: 600
        )

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(fm.fileExists(atPath: whitelistedFile.path), "白名单内的旧文件不得删除")
        XCTAssertTrue(fm.fileExists(atPath: freshOrphanFile.path), "新写入文件受 minAgeSeconds 保护不得删除")
        XCTAssertFalse(fm.fileExists(atPath: oldOrphanFile.path), "超龄孤儿文件应被清理")
    }

    func testD2SweepSkipsTmpAndFixturePaths() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("DSNovelD2Skip_\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let fixtureDir = tempDir.appendingPathComponent("fixture", isDirectory: true)
        let bookDir = tempDir.appendingPathComponent("bookhash", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // P3-3：真实 staging 在 tmp/DSNovelDownloadStaging，下载根下的非白名单超龄目录应被正常清理
        let stagingFile = stagingDir.appendingPathComponent("staged.mp3")
        let fixtureFile = fixtureDir.appendingPathComponent("sample.mp3")
        let tmpFile = bookDir.appendingPathComponent("part.tmp")
        let dlFile = bookDir.appendingPathComponent("part.download")
        let rootFile = tempDir.appendingPathComponent("root_orphan.mp3")

        let allFiles = [stagingFile, fixtureFile, tmpFile, dlFile, rootFile]
        let oldDate = Date().addingTimeInterval(-3600)
        for file in allFiles {
            try Data(repeating: 0x09, count: 128).write(to: file)
            try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        }

        let removed = await DownloadFileProcessor.shared.cleanupOrphanFiles(
            root: tempDir,
            whitelistKeys: [],
            minAgeSeconds: 600
        )

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: stagingFile.path), "下载根下非白名单超龄文件应被清理")
        for file in [fixtureFile, tmpFile, dlFile, rootFile] {
            XCTAssertTrue(fm.fileExists(atPath: file.path), "应跳过保护路径/后缀：\(file.lastPathComponent)")
        }
    }

    @MainActor
    func testP1StaleBadgeAndRedownloadEntrySurviveReDownloadWindow() throws {
        let ch = ChapterDTO(index: 0, title: "第1章", url: "https://example.com/p1_ch1")
        let reDownloadingSnap = ChapterRowSnapshot(
            chapter: ch,
            displayIndex: 1,
            isCurrentPlayingChapter: false,
            isEnginePlaying: false,
            savedPositionMs: 0,
            isFinished: false,
            isVIP: false,
            downloadState: .downloading(0.35),
            downloadedBytes: 2048,
            hasLocalFile: true
        )
        XCTAssertTrue(
            ChapterRow.isStaleBadgeVisible(for: reDownloadingSnap, isQualityStale: true),
            "重下窗口内磁盘存在旧文件时，旧音质角标与重下入口应保持可见"
        )

        let failedSnap = ChapterRowSnapshot(
            chapter: ch,
            displayIndex: 1,
            isCurrentPlayingChapter: false,
            isEnginePlaying: false,
            savedPositionMs: 0,
            isFinished: false,
            isVIP: false,
            downloadState: .failed,
            downloadedBytes: 2048,
            hasLocalFile: true
        )
        XCTAssertFalse(
            ChapterRow.isStaleBadgeVisible(for: failedSnap, isQualityStale: true),
            "失败态不应再显示旧音质重下角标"
        )

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let item = DownloadItem(
            id: "b_p1::c1",
            bookID: "b_p1",
            bookTitle: "P1 测试书",
            chapterID: "c1",
            chapterTitle: "第1章",
            sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
            kind: "manual",
            state: "downloading",
            localPath: "fixture/p1_old.m4a",
            bytes: 2048,
            qualityTierSnapshot: AudioQualityTier.hd.rawValue,
            qualityIsStale: true
        )
        ctx.insert(item)
        try ctx.save()
        let count = DownloadsDataHelper.staleCount(
            forBookID: "b_p1",
            in: [item],
            currentTierRaw: AudioQualityTier.hd.rawValue
        )
        XCTAssertEqual(count, 1, "下载页与播放面板的 staleCount 在重下窗口内应仍计入有旧文件的条目")
    }

    func testP2ReDownloadKeepsOldInodeReachableViaPrevAndSweptByOrphanCleanup() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("dsnovel_p2_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let bookID = "book_p2"
        let chapterID = "chap_p2"
        let firstSrc = tempRoot.appendingPathComponent("src1.mp3")
        try Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + Array(repeating: UInt8(0xAA), count: 2048)).write(to: firstSrc)

        let r1 = await DownloadFileProcessor.shared.validateAndMove(
            tempFileURL: firstSrc,
            bookID: bookID,
            chapterID: chapterID,
            downloadsRoot: tempRoot,
            mimeType: "audio/mpeg",
            originalURL: URL(string: "https://example.com/a.mp3"),
            suggestedFilename: "a.mp3",
            expectedContentLength: nil
        )
        guard case .success(let relPath1, _) = r1 else {
            return XCTFail("首次落盘应成功")
        }

        // 将首次落盘的旧文件 mtime 设为 1 天前，验证 rename 为 .prev 后会刷新 mtime 并享有 600s 保护期
        let destURL = tempRoot.appendingPathComponent(relPath1)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: destURL.path)

        // 模拟同路径新音质覆盖：旧文件应改名让位到 .prev，且新文件可读
        let secondSrc = tempRoot.appendingPathComponent("src2.mp3")
        try Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + Array(repeating: UInt8(0xBB), count: 4096)).write(to: secondSrc)
        let r2 = await DownloadFileProcessor.shared.validateAndMove(
            tempFileURL: secondSrc,
            bookID: bookID,
            chapterID: chapterID,
            downloadsRoot: tempRoot,
            mimeType: "audio/mpeg",
            originalURL: URL(string: "https://example.com/a.mp3"),
            suggestedFilename: "a.mp3",
            expectedContentLength: nil
        )
        guard case .success(let relPath2, let newSize) = r2 else {
            return XCTFail("覆盖落盘应成功")
        }
        XCTAssertEqual(relPath1, relPath2)
        XCTAssertEqual(newSize, 4106)

        let prevURL = destURL.appendingPathExtension("prev")
        XCTAssertTrue(fm.fileExists(atPath: destURL.path), "新文件应已落盘到目标路径")
        XCTAssertTrue(fm.fileExists(atPath: prevURL.path), "旧文件应先改名让位至 .prev 而非直接 unlink")

        // 刚 rename 的 .prev 应享有 600s 保护期，不会被立即清理
        let whitelist: Set<String> = ["\(JsHostBridge.md5Hex(bookID))/\(JsHostBridge.md5Hex(chapterID))"]
        let immediateRemoved = await DownloadFileProcessor.shared.cleanupOrphanFiles(root: tempRoot, whitelistKeys: whitelist, minAgeSeconds: 600)
        XCTAssertEqual(immediateRemoved, 0, "刚让位的 .prev 应因 mtime 刷新而受 600s 保护")
        XCTAssertTrue(fm.fileExists(atPath: prevURL.path))

        // 将 .prev 修改时间设为 20 分钟前，验证孤儿清理自动清掉 .prev 同时保留目标文件
        let oldDate = Date().addingTimeInterval(-1200)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: prevURL.path)
        let removed = await DownloadFileProcessor.shared.cleanupOrphanFiles(root: tempRoot, whitelistKeys: whitelist, minAgeSeconds: 600)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: prevURL.path), ".prev 过期后应被孤儿清理自动回收")
        XCTAssertTrue(fm.fileExists(atPath: destURL.path), "白名单内的目标文件必须保留")
    }

    // MARK: - 独立码率核算 + 喜马/非喜马隔离 + 单书覆写测试

    @MainActor
    func testNonXimalayaSourceNeverMarkedStaleButShowsBitrateBadge() throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        defer { AppSettingsStore.shared.audioQualityTier = originalTier }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        manager.modelContext = ctx
        manager.isOnWiFi = true

        let nonXimalayaSource = "tingyou_fixed_source"
        let bookID = "\(nonXimalayaSource)::https://e.com/ty_book"
        let chID = "https://e.com/ty_book/ep1"
        let item = DownloadItem(
            id: "\(bookID)::\(chID)",
            bookID: bookID,
            bookTitle: "听友固定码率书",
            chapterID: chID,
            chapterTitle: "第 1 章",
            sourceID: nonXimalayaSource,
            kind: "manual",
            state: "completed",
            localPath: "fixture/ty_ep1.mp3",
            bytes: 960_000,
            qualityTierSnapshot: AudioQualityTier.std.rawValue,
            qualityIsStale: true
        )
        item.actualDurationSec = 120
        item.actualBitrateKbps = 64
        ctx.insert(item)
        try ctx.save()
        manager.rebuildSummariesFromContext()

        AppSettingsStore.shared.audioQualityTier = .uhd
        XCTAssertEqual(manager.staleCompletedCount(forBookID: bookID), 0, "非喜马源绝不可计入旧音质数量")
        XCTAssertFalse(manager.isChapterQualityStale(bookID: bookID, chapterID: chID), "非喜马源单章绝不可标旧音质")
        XCTAssertEqual(manager.refreshStaleQualityItems(bookID: bookID), 0, "非喜马源绝不可触发旧音质重下")
        XCTAssertFalse(DownloadsDataHelper.isItemStale(item, currentTierRaw: AudioQualityTier.uhd.rawValue))
        XCTAssertEqual(manager.localFileInfo(bookID: bookID, chapterID: chID)?.isStale, false)

        // 非喜马源仍展示独立核算的码率角标（R18）
        let badge = DownloadsDataHelper.bitrateBadgeText(forItem: item)
        XCTAssertEqual(badge, AudioQualityTier.badgeText(forDetectedBitrateKbps: 64))
        XCTAssertFalse(badge.isEmpty)
    }

    @MainActor
    func testDownloadCompletionPersistsActualBitrateAndClearsInProgress() async throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelBitrateTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false
        AppSettingsStore.shared.audioQualityTier = .hd

        let book = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/br", title: "码率核算书")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/br/ep1", durationSec: 100)
        // 100s * 64kbps / 8 = 800_000 bytes
        manager.customStreamResolver = { item in
            PlayStreamInfo(
                url: "https://cdn.example.com/\(item.chapterID).m4a",
                headers: [:],
                kind: .onDemand,
                durationSec: 100,
                fileSize: 800_000
            )
        }

        _ = try manager.enqueueChaptersWithCheck([ch], for: book)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 1 }

        let itemID = "\(book.id)::\(ch.id)"
        let inProgressKbps = manager.inProgressBitrateKbpsByItemID[itemID]
        XCTAssertEqual(inProgressKbps, 64, "下载中应按 expectedContentLength 与时长核算码率")

        // 模拟落盘（100s / 1_600_000 bytes ≈ 128kbps）
        let staged = tempDir.appendingPathComponent("br_128k.m4a")
        try Data(repeating: 0x2A, count: 1_600_000).write(to: staged)
        fakeTransport.onEvent?(.finished(
            descriptor: fakeTransport.startedDescriptors[0],
            tempFileURL: staged,
            statusCode: 200,
            mimeType: "audio/mp4"
        ))
        await assertWaitUntil { manager.downloadState(bookID: book.id, chapterID: ch.id) == .completed }

        XCTAssertNil(manager.inProgressBitrateKbpsByItemID[itemID], "下载完成后应清理下载中码率缓存")
        let saved = try XCTUnwrap(try ctx.fetch(FetchDescriptor<DownloadItem>()).first)
        XCTAssertGreaterThan(saved.actualDurationSec, 1)
        XCTAssertEqual(saved.actualBitrateKbps, 128)
        XCTAssertEqual(
            DownloadsDataHelper.bitrateBadgeText(forItem: saved),
            AudioQualityTier.badgeText(forDetectedBitrateKbps: 128)
        )
    }

    @MainActor
    func testBitrateBadgeFallbackToPureFileSizeWhenDurationUnknown() {
        let unknownDurationItem = DownloadItem(
            id: "ty::b::ep_nodur",
            bookID: "ty::b",
            bookTitle: "未知时长书",
            chapterID: "ep_nodur",
            chapterTitle: "第 1 章",
            sourceID: "ty",
            kind: "manual",
            state: "completed",
            localPath: "fixture/nodur.mp3",
            bytes: 5 * 1024 * 1024,
            qualityTierSnapshot: AudioQualityTier.uhd.rawValue
        )
        let fallbackBadge = DownloadsDataHelper.bitrateBadgeText(forItem: unknownDurationItem)
        XCTAssertEqual(
            fallbackBadge,
            AudioQualityTier.formattedSizeFallback(bytes: 5 * 1024 * 1024),
            "时长未知时必须退回纯文件体积，绝不直接显示用户所选档位"
        )
        XCTAssertFalse(fallbackBadge.contains("超清"))

        let emptyItem = DownloadItem(
            id: "ty::b::ep_empty",
            bookID: "ty::b",
            bookTitle: "空体积书",
            chapterID: "ep_empty",
            chapterTitle: "第 2 章",
            sourceID: "ty",
            kind: "manual",
            state: "queued",
            bytes: 0
        )
        XCTAssertEqual(DownloadsDataHelper.bitrateBadgeText(forItem: emptyItem), "")
    }

    @MainActor
    func testXimalayaPerBookQualityOverrideDrivesStaleDetection() throws {
        let originalTier = AppSettingsStore.shared.audioQualityTier
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer {
            AppSettingsStore.shared.audioQualityTier = originalTier
            AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly
        }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        manager.modelContext = ctx
        manager.isOnWiFi = false
        AppSettingsStore.shared.wifiOnlyDownload = true
        AppSettingsStore.shared.audioQualityTier = .hd

        let bookURL = "https://www.ximalaya.com/album/998877"
        let bookID = "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64::\(bookURL)"
        let book = Book(
            id: bookID,
            sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
            bookURL: bookURL,
            title: "喜马单书覆写测试书"
        )
        let chID = "https://www.ximalaya.com/sound/1001"
        let item = DownloadItem(
            id: "\(bookID)::\(chID)",
            bookID: bookID,
            bookTitle: book.title,
            chapterID: chID,
            chapterTitle: "第 1 章",
            sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64",
            kind: "manual",
            state: "completed",
            localPath: "fixture/xm_high.m4a",
            bytes: 4096,
            qualityTierSnapshot: AudioQualityTier.hd.rawValue
        )
        ctx.insert(book)
        ctx.insert(item)
        try ctx.save()
        manager.rebuildSummariesFromContext()

        // 跟随全局 .hd：不标旧音质
        XCTAssertEqual(manager.effectiveQualityTier(forBookID: bookID), .hd)
        XCTAssertEqual(manager.staleCompletedCount(forBookID: bookID), 0)
        XCTAssertFalse(manager.isChapterQualityStale(bookID: bookID, chapterID: chID))

        // 单书覆写为 .uhd（全局仍为 .hd）：触发旧音质判定与重下
        book.preferredAudioQualityRaw = AudioQualityTier.uhd.rawValue
        try ctx.save()
        XCTAssertEqual(manager.effectiveQualityTier(forBookID: bookID), .uhd)
        XCTAssertEqual(manager.staleCompletedCount(forBookID: bookID), 1)
        XCTAssertTrue(manager.isChapterQualityStale(bookID: bookID, chapterID: chID))

        let refreshed = manager.refreshStaleQualityItems(bookID: bookID, chapterIDs: [chID])
        XCTAssertEqual(refreshed, 1)
        XCTAssertEqual(item.qualityTierSnapshot, AudioQualityTier.uhd.rawValue)
    }

    // MARK: - 下载管理单删、失败批删与辅助方法单元测试

    @MainActor
    func testRemoveDownloadItemDeletesFailedAndActiveWithoutTouchingCompleted() async throws {
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer { AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelRemoveItem_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false
        manager.customStreamResolver = { item in
            PlayStreamInfo(
                url: "https://cdn.example.com/\(item.chapterID).mp3",
                headers: [:],
                kind: .onDemand,
                durationSec: 120,
                fileSize: 960_000
            )
        }

        let book = BookRef(sourceID: "s1", bookURL: "https://e.com/rm_single", title: "单删测试书")
        let doneDir = tempDir.appendingPathComponent(JsHostBridge.md5Hex(book.id), isDirectory: true)
        try FileManager.default.createDirectory(at: doneDir, withIntermediateDirectories: true)
        let doneRelPath = "\(JsHostBridge.md5Hex(book.id))/\(JsHostBridge.md5Hex("ep_done")).mp3"
        let doneFileURL = tempDir.appendingPathComponent(doneRelPath)
        try Data(repeating: 0x55, count: 4096).write(to: doneFileURL)

        let completedItem = DownloadItem(
            id: "\(book.id)::ep_done",
            bookID: book.id,
            bookTitle: book.title,
            chapterID: "ep_done",
            chapterTitle: "第 1 章",
            sourceID: book.sourceID,
            kind: "manual",
            state: "completed",
            localPath: doneRelPath,
            bytes: 4096
        )
        let failedItem = DownloadItem(
            id: "\(book.id)::ep_failed",
            bookID: book.id,
            bookTitle: book.title,
            chapterID: "ep_failed",
            chapterTitle: "第 2 章",
            sourceID: book.sourceID,
            kind: "manual",
            state: "failed",
            retryCount: 2
        )
        ctx.insert(completedItem)
        ctx.insert(failedItem)
        try ctx.save()
        manager.rebuildSummariesFromContext()

        let activeChapter = ChapterDTO(index: 2, title: "第 3 章", url: "https://e.com/rm_single/ep_active", durationSec: 120)
        _ = try manager.enqueueChaptersWithCheck([activeChapter], for: book)
        await assertWaitUntil { fakeTransport.startedDescriptors.count == 1 }

        let activeItemID = "\(book.id)::\(activeChapter.id)"
        manager.saveResumeData(Data("resume".utf8), for: activeItemID)
        XCTAssertTrue(fakeTransport.activeIDs.contains(activeItemID))
        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount, 1)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.activeCount, 1)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.failedCount, 1)

        // 1. 删除不存在条目返回 false
        XCTAssertFalse(manager.removeDownloadItem(bookID: book.id, chapterID: "ep_missing"))

        // 2. 单删失败章，不影响已完成与进行中章
        let removedFailed = manager.removeDownloadItem(bookID: book.id, chapterID: "ep_failed")
        XCTAssertTrue(removedFailed)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.failedCount, 0)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.activeCount, 1)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount, 1)

        // 3. 取消并删除进行中章，清理 transport / 进度 / 码率 / resumeData，不触碰已完成章
        let removedActive = manager.removeDownloadItem(bookID: book.id, chapterID: activeChapter.id)
        XCTAssertTrue(removedActive)
        XCTAssertFalse(fakeTransport.activeIDs.contains(activeItemID))
        XCTAssertNil(manager.itemProgress[activeItemID])
        XCTAssertNil(manager.inProgressBitrateKbpsByItemID[activeItemID])
        XCTAssertNil(manager.loadResumeData(for: activeItemID))

        // 4. 已完成章完好保留（SwiftData 记录、磁盘文件、summary 均不受影响）
        let remaining = try ctx.fetch(FetchDescriptor<DownloadItem>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.chapterID, "ep_done")
        XCTAssertTrue(FileManager.default.fileExists(atPath: doneFileURL.path))
        XCTAssertEqual(manager.downloadState(bookID: book.id, chapterID: "ep_done"), .completed)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.completedCount, 1)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.activeCount, 0)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.failedCount, 0)
        XCTAssertEqual(manager.summariesByBookID[book.id]?.totalBytes, 4096)
    }

    @MainActor
    func testRemoveFailedItemsForBookAndAllPreservesCompleted() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelRemoveFailed_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        manager.customDownloadsRootDirectory = tempDir
        manager.modelContext = ctx
        manager.isOnWiFi = true

        let bookA = "s1::https://e.com/book_a"
        let bookB = "s1::https://e.com/book_b"

        let aDone = DownloadItem(
            id: "\(bookA)::a_done",
            bookID: bookA,
            bookTitle: "甲书",
            chapterID: "a_done",
            chapterTitle: "第 1 章",
            sourceID: "s1",
            kind: "manual",
            state: "completed",
            localPath: "fixture/a_done.mp3",
            bytes: 4096
        )
        let aPaused = DownloadItem(
            id: "\(bookA)::a_paused",
            bookID: bookA,
            bookTitle: "甲书",
            chapterID: "a_paused",
            chapterTitle: "第 2 章",
            sourceID: "s1",
            kind: "manual",
            state: "paused"
        )
        let aFail1 = DownloadItem(
            id: "\(bookA)::a_fail1",
            bookID: bookA,
            bookTitle: "甲书",
            chapterID: "a_fail1",
            chapterTitle: "第 3 章",
            sourceID: "s1",
            kind: "manual",
            state: "failed",
            retryCount: 2
        )
        let aFail2 = DownloadItem(
            id: "\(bookA)::a_fail2",
            bookID: bookA,
            bookTitle: "甲书",
            chapterID: "a_fail2",
            chapterTitle: "第 4 章",
            sourceID: "s1",
            kind: "manual",
            state: "failed",
            retryCount: 2
        )
        let bDone = DownloadItem(
            id: "\(bookB)::b_done",
            bookID: bookB,
            bookTitle: "乙书",
            chapterID: "b_done",
            chapterTitle: "第 1 章",
            sourceID: "s1",
            kind: "manual",
            state: "completed",
            localPath: "fixture/b_done.mp3",
            bytes: 2048
        )
        let bFail1 = DownloadItem(
            id: "\(bookB)::b_fail1",
            bookID: bookB,
            bookTitle: "乙书",
            chapterID: "b_fail1",
            chapterTitle: "第 2 章",
            sourceID: "s1",
            kind: "manual",
            state: "failed",
            retryCount: 2
        )
        let bFail2 = DownloadItem(
            id: "\(bookB)::b_fail2",
            bookID: bookB,
            bookTitle: "乙书",
            chapterID: "b_fail2",
            chapterTitle: "第 3 章",
            sourceID: "s1",
            kind: "manual",
            state: "failed",
            retryCount: 2
        )

        for record in [aDone, aPaused, aFail1, aFail2, bDone, bFail1, bFail2] {
            ctx.insert(record)
        }
        try ctx.save()
        manager.rebuildSummariesFromContext()

        XCTAssertEqual(manager.summariesByBookID[bookA]?.failedCount, 2)
        XCTAssertEqual(manager.summariesByBookID[bookB]?.failedCount, 2)

        // 1. 按书清空甲书失败项，不影响甲书已完成/进行中项，也不影响乙书
        let removedA = manager.removeFailedItems(forBookID: bookA)
        XCTAssertEqual(removedA, 2)
        XCTAssertEqual(manager.summariesByBookID[bookA]?.completedCount, 1)
        XCTAssertEqual(manager.summariesByBookID[bookA]?.activeCount, 1)
        XCTAssertEqual(manager.summariesByBookID[bookA]?.failedCount, 0)
        XCTAssertEqual(manager.summariesByBookID[bookA]?.totalBytes, 4096)
        XCTAssertEqual(manager.summariesByBookID[bookB]?.failedCount, 2)
        XCTAssertEqual(manager.summariesByBookID[bookB]?.completedCount, 1)

        // 2. 全局清空剩余失败项（乙书 2 条），保留两书已完成与进行中项
        let removedAll = manager.removeAllFailedItems()
        XCTAssertEqual(removedAll, 2)
        XCTAssertEqual(manager.summariesByBookID[bookB]?.completedCount, 1)
        XCTAssertEqual(manager.summariesByBookID[bookB]?.failedCount, 0)
        XCTAssertEqual(manager.summariesByBookID[bookB]?.totalBytes, 2048)
        XCTAssertEqual(manager.summariesByBookID[bookA]?.completedCount, 1)
        XCTAssertEqual(manager.summariesByBookID[bookA]?.activeCount, 1)

        let remainingIDs = Set((try ctx.fetch(FetchDescriptor<DownloadItem>())).map(\.id))
        XCTAssertEqual(remainingIDs, Set(["\(bookA)::a_done", "\(bookA)::a_paused", "\(bookB)::b_done"]))
        XCTAssertEqual(manager.removeAllFailedItems(), 0)
    }

    @MainActor
    func testSortedCompletedItemsAndClearAllAlertTitle() {
        // 1. activeStateLabel 文案映射
        XCTAssertEqual(DownloadsDataHelper.activeStateLabel(for: "waitingWiFi"), "等待 Wi-Fi")
        XCTAssertEqual(DownloadsDataHelper.activeStateLabel(for: "paused"), "已暂停")
        XCTAssertEqual(DownloadsDataHelper.activeStateLabel(for: "queued"), "排队中")
        XCTAssertEqual(DownloadsDataHelper.activeStateLabel(for: "downloading"), "下载中")
        XCTAssertEqual(DownloadsDataHelper.activeStateLabel(for: "unknown"), "下载中")

        // 2. 无目录缓存时按 localizedStandardCompare 自然排序
        let uncachedBookID = "s1::https://e.com/sort_uncached_\(UUID().uuidString)"
        let item10 = DownloadItem(id: "\(uncachedBookID)::c10", bookID: uncachedBookID, bookTitle: "排序书", chapterID: "c10", chapterTitle: "第 10 章", sourceID: "s1", state: "completed")
        let item2 = DownloadItem(id: "\(uncachedBookID)::c2", bookID: uncachedBookID, bookTitle: "排序书", chapterID: "c2", chapterTitle: "第 2 章", sourceID: "s1", state: "completed")
        let item1 = DownloadItem(id: "\(uncachedBookID)::c1", bookID: uncachedBookID, bookTitle: "排序书", chapterID: "c1", chapterTitle: "第 1 章", sourceID: "s1", state: "completed")
        let sortedUncached = DownloadsDataHelper.sortedCompletedItems([item10, item2, item1], forBookID: uncachedBookID)
        XCTAssertEqual(sortedUncached.map(\.chapterTitle), ["第 1 章", "第 2 章", "第 10 章"])

        // 3. 有目录缓存时目录项按 index 升序优先，目录外条目按自然排序居后
        let cachedBookID = "s1::https://e.com/sort_cached_\(UUID().uuidString)"
        let chFirst = ChapterDTO(index: 0, title: "序章", url: "https://e.com/ch_b")
        let chSecond = ChapterDTO(index: 1, title: "第一章", url: "https://e.com/ch_a")
        ChapterCacheStore.saveChapters([chFirst, chSecond], for: cachedBookID)

        let dlExtra10 = DownloadItem(id: "\(cachedBookID)::extra10", bookID: cachedBookID, bookTitle: "目录书", chapterID: "extra10", chapterTitle: "番外 10", sourceID: "s1", state: "completed")
        let dlSecond = DownloadItem(id: "\(cachedBookID)::\(chSecond.id)", bookID: cachedBookID, bookTitle: "目录书", chapterID: chSecond.id, chapterTitle: "第一章", sourceID: "s1", state: "completed")
        let dlExtra2 = DownloadItem(id: "\(cachedBookID)::extra2", bookID: cachedBookID, bookTitle: "目录书", chapterID: "extra2", chapterTitle: "番外 2", sourceID: "s1", state: "completed")
        let dlFirst = DownloadItem(id: "\(cachedBookID)::\(chFirst.id)", bookID: cachedBookID, bookTitle: "目录书", chapterID: chFirst.id, chapterTitle: "序章", sourceID: "s1", state: "completed")
        let sortedCached = DownloadsDataHelper.sortedCompletedItems([dlExtra10, dlSecond, dlExtra2, dlFirst], forBookID: cachedBookID)
        XCTAssertEqual(sortedCached.map(\.chapterID), [chFirst.id, chSecond.id, "extra2", "extra10"])

        // 4. clearAllAlertTitle 如实拼接非零状态段
        XCTAssertEqual(
            DownloadsDataHelper.clearAllAlertTitle(
                bookTitle: "雪中悍刀行",
                completedCount: 1,
                activeCount: 0,
                failedCount: 1,
                formattedBytes: "2.4 MB"
            ),
            "确认清空《雪中悍刀行》全部下载记录（已下载 1 章 · 2.4 MB、失败 1 章）？"
        )
        XCTAssertEqual(
            DownloadsDataHelper.clearAllAlertTitle(
                bookTitle: "雪中悍刀行",
                completedCount: 2,
                activeCount: 3,
                failedCount: 1,
                formattedBytes: "12.0 MB"
            ),
            "确认清空《雪中悍刀行》全部下载记录（已下载 2 章 · 12.0 MB、进行中 3 章、失败 1 章）？"
        )
        XCTAssertEqual(
            DownloadsDataHelper.clearAllAlertTitle(
                bookTitle: "雪中悍刀行",
                completedCount: 0,
                activeCount: 2,
                failedCount: 0,
                formattedBytes: ""
            ),
            "确认清空《雪中悍刀行》全部下载记录（进行中 2 章）？"
        )
        XCTAssertEqual(
            DownloadsDataHelper.clearAllAlertTitle(
                bookTitle: "雪中悍刀行",
                completedCount: 0,
                activeCount: 0,
                failedCount: 0,
                formattedBytes: ""
            ),
            "确认清空《雪中悍刀行》全部下载记录？"
        )
    }

    @MainActor
    func testRemoveDownloadItemDuringAsyncResolveFailureDoesNotResurrectGhost() async throws {
        let originalWifiOnly = AppSettingsStore.shared.wifiOnlyDownload
        defer { AppSettingsStore.shared.wifiOnlyDownload = originalWifiOnly }

        let container = try TestContainer.make()
        let ctx = container.mainContext
        let fakeTransport = FakeDownloadTransport()
        let manager = DownloadManager(transport: fakeTransport)
        manager.modelContext = ctx
        manager.isOnWiFi = true
        AppSettingsStore.shared.wifiOnlyDownload = false

        var resolveContinuation: CheckedContinuation<PlayStreamInfo, Error>?
        manager.customStreamResolver = { _ in
            try await withCheckedThrowingContinuation { cont in
                resolveContinuation = cont
            }
        }

        let book = BookRef(sourceID: "s1", bookURL: "https://e.com/race_delete", title: "竞态删除测试书")
        let chapter = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/race_delete/ep1", durationSec: 120)
        _ = try manager.enqueueChaptersWithCheck([chapter], for: book)
        await assertWaitUntil { resolveContinuation != nil }

        // 解析挂起期间用户取消并删除该条目
        let removed = manager.removeDownloadItem(bookID: book.id, chapterID: chapter.id)
        XCTAssertTrue(removed)
        XCTAssertNil(manager.summariesByBookID[book.id])

        // 随后挂起的解析抛出网络错误，不应复活幽灵摘要或重新入队
        resolveContinuation?.resume(throwing: URLError(.cancelled))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(manager.summariesByBookID[book.id])
        let remaining = try ctx.fetch(FetchDescriptor<DownloadItem>())
        XCTAssertTrue(remaining.isEmpty)
    }
}
