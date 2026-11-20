import XCTest
import SwiftData
import UIKit
@testable import DSNovel

enum PerfFixtures {
    @MainActor
    static func makeMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Book.self,
            ShelfCategory.self,
            DownloadItem.self,
            PluginRecord.self,
            PluginGroup.self,
            SearchHistory.self,
            BuiltinParserRecord.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func makeBooks(count: Int = 500) -> [Book] {
        (0..<count).map { idx in
            Book(
                id: "src_\(idx % 5)::https://example.invalid/book/\(idx)",
                sourceID: "src_\(idx % 5)",
                bookURL: "https://example.invalid/book/\(idx)",
                title: "性能基线测试有声书_\(idx)",
                author: "演播者_\(idx % 20)",
                cover: "https://example.invalid/cover/\(idx).jpg",
                intro: "用于测量 500 本书架派生排序与分组性能的离线夹具数据。",
                inShelf: idx % 2 == 0,
                addedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + idx * 60)),
                lastChapterID: "ep_\(idx % 50 + 1)",
                lastChapterTitle: "第 \(idx % 50 + 1) 章",
                lastChapterIndex: idx % 50 + 1,
                totalChapters: 200,
                lastPositionMs: (idx % 600) * 1000,
                lastPlayedAt: idx % 3 == 0 ? Date(timeIntervalSince1970: TimeInterval(1_700_100_000 + idx * 30)) : nil,
                isPinned: idx < 8
            )
        }
    }

    static func makeChapters(count: Int = 2000) -> [ChapterDTO] {
        (0..<count).map { idx in
            ChapterDTO(
                index: idx,
                title: "第 \(idx + 1) 章 章节性能测试",
                url: "https://example.invalid/audio/\(idx + 1).m4a",
                durationSec: 600 + (idx % 300)
            )
        }
    }

    static func makeDiscoverItems(count: Int = 200) -> [BookRef] {
        (0..<count).map { idx in
            BookRef(
                sourceID: "src_discover",
                bookURL: "https://example.invalid/discover/\(idx)",
                title: "发现项_\(idx)",
                author: "作者_\(idx % 30)",
                cover: "https://example.invalid/discover/\(idx).jpg",
                intro: "共 \(50 + idx) 章",
                chapterCount: 50 + idx
            )
        }
    }
}

final class BaselinePerfTests: XCTestCase {

    func testShelfDerivationPerformance500Books() {
        let books = PerfFixtures.makeBooks(count: 500)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let shelf = books.filter(\.inShelf).sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
                return (a.lastPlayedAt ?? a.addedAt) > (b.lastPlayedAt ?? b.addedAt)
            }
            let recent = books.filter { $0.lastPlayedAt != nil }.sorted {
                ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
            }
            XCTAssertFalse(shelf.isEmpty)
            XCTAssertFalse(recent.isEmpty)
        }
    }

    func testChapterSegmentBuilding2000Chapters() {
        let chapters = PerfFixtures.makeChapters(count: 2000)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let segments = BookDetailViewModel.buildSegments(totalCount: chapters.count, pageSize: 50)
            XCTAssertEqual(segments.count, 40)
        }
    }

    func testDiscoverSubtitleDerivation200Items() {
        let items = PerfFixtures.makeDiscoverItems(count: 200)
        measure(metrics: [XCTClockMetric()]) {
            let subtitles = items.map(\.discoverSubtitle)
            XCTAssertEqual(subtitles.count, 200)
        }
    }
}
