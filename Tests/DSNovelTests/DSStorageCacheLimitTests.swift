import DSCore
import DSDesignSystem
import DSStorage
import Foundation
import Testing
import UIKit

@Suite("存储管理缓存上限自动清理与持久化回归测试")
struct DSStorageCacheLimitTests {
    @Test("AppSettingsStore 持久化并钳制 autoCacheCleanupEnabled 与 cacheLimitMB (200...2000)")
    @MainActor
    func cacheLimitSettingsPersistenceAndClamping() {
        let suite = "com.dsnovel.app.test.cachelimit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }

        let s1 = AppSettingsStore(defaults: defaults)
        #expect(s1.autoCacheCleanupEnabled == true)
        #expect(s1.cacheLimitMB == 500)

        s1.autoCacheCleanupEnabled = false
        s1.cacheLimitMB = 50
        #expect(s1.cacheLimitMB == 200)

        s1.cacheLimitMB = 4096
        #expect(s1.cacheLimitMB == 2000)

        s1.cacheLimitMB = 800
        let s2 = AppSettingsStore(defaults: defaults)
        #expect(s2.autoCacheCleanupEnabled == false)
        #expect(s2.cacheLimitMB == 800)
    }

    @Test("ChapterCacheStore 按最久未用裁剪并严格保护受保护书籍目录")
    func chapterCacheTrimPreservesProtectedBooks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ds_trim_chap_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ChapterCacheStore(baseDirectory: dir)
        let chapters = (0..<80).map { i in
            ChapterDTO(id: "c_\(i)", index: i, title: "第\(i)章", url: "https://example.com/\(i)")
        }
        try await store.saveChapters(chapters, bookID: "book_old")
        try await Task.sleep(for: .milliseconds(30))
        try await store.saveChapters(chapters, bookID: "book_protected")

        let beforeBytes = await store.diskUsageBytes()
        #expect(beforeBytes > 0)

        await store.trimOldestCaches(toMaxBytes: beforeBytes / 2, preservingBookIDs: ["book_protected"])

        let protectedLoaded = await store.loadChapters(bookID: "book_protected")
        let oldLoaded = await store.loadChapters(bookID: "book_old")
        #expect(protectedLoaded?.count == 80)
        #expect(oldLoaded == nil)
    }

    @Test("CoverImagePipeline 磁盘缓存裁剪将占用压回上限以内")
    func coverPipelineTrimReducesDiskUsage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ds_trim_cover_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let coversDir = dir.appendingPathComponent("DSNovelV3Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        for idx in 0..<4 {
            let file = coversDir.appendingPathComponent("cover_\(idx).img")
            try Data(repeating: UInt8(idx + 1), count: 2048).write(to: file)
        }

        let pipeline = CoverImagePipeline(diskDirectory: dir)
        #expect(await pipeline.diskUsageBytes() == 8192)

        await pipeline.trimDiskCache(toMaxBytes: 4096)
        #expect(await pipeline.diskUsageBytes() <= 4096)
    }
}
