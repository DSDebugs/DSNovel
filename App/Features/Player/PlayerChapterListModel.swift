import DSCore
import Foundation
import Observation

struct IndexedChapterRow: Identifiable {
    let physicalIndex: Int
    let chapter: ChapterDTO
    var id: String { chapter.id }
}

struct ChapterSegmentRange: Identifiable, Equatable {
    let index: Int
    let start: Int
    let end: Int
    var id: Int { index }
    var label: String { "\(start + 1)–\(end)" }
}

/// 目录弹窗状态模型（保留 displayedRows(from:) 测试签名，支持 100 章分段、已下载筛选、正倒序与关键词搜索）
@Observable
@MainActor
final class PlayerChapterListModel {
    private struct CacheKey: Equatable {
        let keyword: String
        let isDescending: Bool
        let onlyDownloaded: Bool
        let segmentIndex: Int
        let useSegments: Bool
        let count: Int
        let firstID: String?
        let lastID: String?
        let downloadedCount: Int
    }

    static let pageSize: Int = 100

    var keyword: String = ""
    var isDescending: Bool = false
    var onlyDownloaded: Bool = false
    var selectedSegmentIndex: Int = 0

    @ObservationIgnored private var cachedKey: CacheKey?
    @ObservationIgnored private var cachedRows: [IndexedChapterRow] = []

    static func segments(for totalCount: Int, pageSize: Int = pageSize) -> [ChapterSegmentRange] {
        guard totalCount > 0, pageSize > 0 else { return [] }
        var list: [ChapterSegmentRange] = []
        var start = 0
        var idx = 0
        while start < totalCount {
            let end = min(totalCount, start + pageSize)
            list.append(ChapterSegmentRange(index: idx, start: start, end: end))
            start = end
            idx += 1
        }
        return list
    }

    static func segmentIndex(for chapterID: String?, in chapters: [ChapterDTO], pageSize: Int = pageSize) -> Int? {
        guard let chapterID, pageSize > 0,
              let idx = chapters.firstIndex(where: { $0.id == chapterID }) else { return nil }
        return idx / pageSize
    }

    /// 兼容现有单元测试签名（按关键词与正/倒序返回全量行）
    func displayedRows(from source: [ChapterDTO]) -> [IndexedChapterRow] {
        displayedRows(from: source, downloadedChapterIDs: nil, useSegments: false)
    }

    /// 目录弹窗完整筛选入口（100 章分段 + 已下载筛选 + 关键词搜索 + 正/倒序，全移出 View body）
    func displayedRows(
        from source: [ChapterDTO],
        downloadedChapterIDs: Set<String>?,
        useSegments: Bool
    ) -> [IndexedChapterRow] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = CacheKey(
            keyword: trimmed,
            isDescending: isDescending,
            onlyDownloaded: onlyDownloaded,
            segmentIndex: selectedSegmentIndex,
            useSegments: useSegments,
            count: source.count,
            firstID: source.first?.id,
            lastID: source.last?.id,
            downloadedCount: downloadedChapterIDs?.count ?? -1
        )
        if cachedKey == key {
            return cachedRows
        }

        let range: Range<Int>
        if useSegments && trimmed.isEmpty && !onlyDownloaded && source.count > Self.pageSize {
            let start = max(0, selectedSegmentIndex * Self.pageSize)
            let end = min(source.count, start + Self.pageSize)
            range = start < end ? start..<end : 0..<source.count
        } else {
            range = 0..<source.count
        }

        var rows: [IndexedChapterRow] = []
        rows.reserveCapacity(range.count)
        for idx in range {
            let ch = source[idx]
            if onlyDownloaded, let ids = downloadedChapterIDs, !ids.contains(ch.id) {
                continue
            }
            if !trimmed.isEmpty && !ch.title.localizedCaseInsensitiveContains(trimmed) {
                continue
            }
            rows.append(IndexedChapterRow(physicalIndex: idx, chapter: ch))
        }
        let result = isDescending ? Array(rows.reversed()) : rows
        cachedKey = key
        cachedRows = result
        return result
    }
}
