import DSCore
import DSPlayback
import DSStorage
import Foundation
import Testing

@Suite("第五轮审计回归测试（目录缓存解耦/保护、睡眠定时持久化/墙钟延长、加密 ZIP 语义）")
struct DSAuditFifthRoundTests {
    @Test("F-01：ChapterCacheStore 读取续期 mtime 不篡改数据新鲜度 updatedAt")
    func chapterCacheUpdatedAtDecoupledFromMtimeTouch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_cache_f01_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ChapterCacheStore(baseDirectory: dir, maxEntries: 50)
        let chapters = [ChapterDTO(id: "c1", index: 0, title: "第一章", url: "https://example.com/1.mp3")]
        try await store.saveChapters(chapters, bookID: "book-f01")

        let first = try #require(await store.loadChaptersWithTimestamp(bookID: "book-f01"))
        let originalSavedAt = first.updatedAt

        // 模拟 3 天前 mtime，使用新实例冷读触发 mtime 续期，校验 updatedAt 仍为原 savedAt
        let cacheFile = dir
            .appendingPathComponent("ChapterCache", isDirectory: true)
            .appendingPathComponent("\(DSCrypto.sha256Hex("book-f01")).dscache")
        let threeDaysAgo = Date().addingTimeInterval(-72 * 3600)
        try FileManager.default.setAttributes([.modificationDate: threeDaysAgo], ofItemAtPath: cacheFile.path)

        let freshStore = ChapterCacheStore(baseDirectory: dir, maxEntries: 50)
        let second = try #require(await freshStore.loadChaptersWithTimestamp(bookID: "book-f01"))
        #expect(abs(second.updatedAt.timeIntervalSince(originalSavedAt)) < 1.0)
    }

    @Test("F-05：ChapterCacheStore 超过条数上限裁剪时不删除受保护的离线书籍目录")
    func chapterCacheTrimPreservesProtectedBooks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_cache_f05_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ChapterCacheStore(baseDirectory: dir, maxEntries: 20)
        let sample = [ChapterDTO(id: "c1", index: 0, title: "第一章", url: "https://example.com/1.mp3")]
        await store.updateProtectedBookIDs(["protected-book"])
        try await store.saveChapters(sample, bookID: "protected-book")

        let protectedURL = dir
            .appendingPathComponent("ChapterCache", isDirectory: true)
            .appendingPathComponent("\(DSCrypto.sha256Hex("protected-book")).dscache")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10_000)],
            ofItemAtPath: protectedURL.path
        )

        for idx in 1...25 {
            try await store.saveChapters(sample, bookID: "normal-book-\(idx)")
        }

        let reloaded = await store.loadChapters(bookID: "protected-book")
        #expect(reloaded?.count == 1)
    }

    @Test("F-02/F-03：SleepTimerEngine 越界钳制后正确持久化，且延长倒计时以墙钟 deadline 为基数")
    @MainActor
    func sleepTimerClampedPersistenceAndWallClockExtend() throws {
        let suiteName = "ds_sleep_f02_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = SleepTimerEngine(tickIntervalNanoseconds: 60_000_000_000)
        engine.bindPersistence(defaults)
        engine.fadeOutLastSeconds = 999
        engine.autoRewindOnSleepSeconds = 999
        engine.lastCustomMinutes = 999

        let restored = SleepTimerEngine(tickIntervalNanoseconds: 60_000_000_000)
        restored.bindPersistence(defaults)
        #expect(restored.fadeOutLastSeconds == 120)
        #expect(restored.autoRewindOnSleepSeconds == 60)
        #expect(restored.lastCustomMinutes == 180)

        // 关闭态调用 extendMinutes 不应静默开启倒计时
        engine.extendMinutes(by: 10, onFadeFactor: { _ in }, onFire: {})
        #expect(engine.mode == .off)

        // 使用相对未来时间避免绝对年份漂移
        let t0 = Date().addingTimeInterval(3600)
        engine.startCountdown(minutes: 20, now: t0, onFadeFactor: { _ in }, onFire: {})
        // 模拟已过去 15 分钟（挂起未刷新 remainingSeconds），此时延长 10 分钟应约剩 15 分钟而非 30 分钟
        let tLater = t0.addingTimeInterval(15 * 60)
        engine.extendMinutes(by: 10, now: tLater, onFadeFactor: { _ in }, onFire: {})
        if case .countdown(let newDeadline) = engine.mode {
            let mins = Int(round(newDeadline.timeIntervalSince(tLater) / 60.0))
            #expect(mins == 15)
        } else {
            Issue.record("Expected countdown mode after extendMinutes")
        }
        engine.cancel()
    }

    @Test("F-04：ZIPArchiveError.encryptedArchive 返回明确加密提示")
    func zipEncryptedErrorDescriptionIsExplicit() {
        let desc = ZIPArchiveError.encryptedArchive.errorDescription ?? ""
        #expect(desc.contains("加密"))
    }
}
