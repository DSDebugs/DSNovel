import XCTest
import SwiftData
@testable import DSNovel

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
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fakeTransport.startedDescriptors.isEmpty)

        // 4. 模拟后台下载完成（有效二进制音频 >= 1024 字节）
        let firstDesc = fakeTransport.startedDescriptors[0]
        let stagedFile = tempDir.appendingPathComponent("staged_ok.mp3")
        try Data(repeating: 0xAB, count: 4096).write(to: stagedFile)
        fakeTransport.onEvent?(.finished(descriptor: firstDesc, tempFileURL: stagedFile, statusCode: 200, mimeType: "audio/mpeg"))
        try? await Task.sleep(for: .milliseconds(50))

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
        XCTAssertEqual(store.currentDiscoverSourceID, "")
        XCTAssertFalse(store.nightDimEnabled)
        XCTAssertFalse(store.reduceMotionOverride)
        XCTAssertEqual(store.launchBehavior, .restorePaused)
        XCTAssertEqual(AppSettingsStore.allResettablePropertyNames.count, 18)

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
        XCTAssertTrue(activeSnap?.subtitleText.contains("00:33") == true)

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
}
