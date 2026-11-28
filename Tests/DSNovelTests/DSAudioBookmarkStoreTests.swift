import DSCore
import DSStorage
import Foundation
import XCTest

final class DSAudioBookmarkStoreTests: XCTestCase {
    @MainActor
    func testBookmarkPersistenceSleepCapAndChapterIndexFallback() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ds_bm_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = AudioBookmarkStore(storageDirectory: tmpDir)
        let manual = store.addBookmark(
            bookID: "b1",
            bookTitle: "凡人修仙传",
            chapterID: "old-id-79",
            chapterIndex: 78,
            chapterTitle: "第79章",
            positionMs: 667_000,
            note: "重点剧情",
            kind: .manual
        )
        XCTAssertEqual(manual.formattedPosition, "11:07")

        // 连续写入 7 条睡眠自动打点，每书最多保留 5 条最晚记录
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<7 {
            store.addBookmark(
                bookID: "b1",
                bookTitle: "凡人修仙传",
                chapterID: "c-\(i)",
                chapterIndex: i,
                chapterTitle: "第\(i + 1)章",
                positionMs: 30_000,
                note: "睡眠自动打点",
                kind: .sleepAuto,
                now: base.addingTimeInterval(TimeInterval(i * 60))
            )
        }
        let sleepOnly = store.bookmarks(forBookID: "b1").filter { $0.kind == .sleepAuto }
        XCTAssertEqual(sleepOnly.count, AudioBookmarkStore.maxSleepAutoPerBook)

        // 重载磁盘确认原子 JSON 持久化完整
        let reloaded = AudioBookmarkStore(storageDirectory: tmpDir)
        XCTAssertEqual(reloaded.bookmarks(forBookID: "b1").count, 1 + AudioBookmarkStore.maxSleepAutoPerBook)

        // 换源后 chapterID 变化时按 chapterIndex 兜底匹配
        let newChapters = (0..<80).map { idx in
            ChapterDTO(id: "new-src-\(idx)", index: idx, title: "第\(idx + 1)章", url: "https://example.com/\(idx)")
        }
        XCTAssertEqual(manual.resolveChapterIndex(in: newChapters), 78)
    }
}
