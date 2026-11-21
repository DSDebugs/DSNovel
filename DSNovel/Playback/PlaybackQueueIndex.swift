import Foundation

/// 章节播放队列 O(1) 下标索引：维护 `[chapterID: index]` 映射，消除高频线性扫描
struct PlaybackQueueIndex: Sendable {
    private(set) var chapters: [ChapterDTO] = []
    private var indexByID: [String: Int] = [:]

    init(chapters: [ChapterDTO] = []) {
        replace(with: chapters)
    }

    var count: Int { chapters.count }
    var isEmpty: Bool { chapters.isEmpty }
    var first: ChapterDTO? { chapters.first }
    var last: ChapterDTO? { chapters.last }

    mutating func replace(with newChapters: [ChapterDTO]) {
        chapters = newChapters
        indexByID = Dictionary(minimumCapacity: newChapters.count)
        for (idx, chapter) in newChapters.enumerated() {
            if indexByID[chapter.id] == nil {
                indexByID[chapter.id] = idx
            }
        }
    }

    func index(of chapterID: String) -> Int? {
        indexByID[chapterID]
    }

    func oneBasedIndex(of chapterID: String?) -> Int {
        guard let chapterID, let idx = indexByID[chapterID] else { return 0 }
        return idx + 1
    }

    func previousChapter(before chapterID: String?) -> ChapterDTO? {
        guard let chapterID, let idx = indexByID[chapterID], idx > 0 else { return nil }
        return chapters[idx - 1]
    }

    func nextChapter(after chapterID: String?) -> ChapterDTO? {
        guard let chapterID, let idx = indexByID[chapterID], idx + 1 < chapters.count else { return nil }
        return chapters[idx + 1]
    }

    func upcomingChapters(after chapterID: String?, limit: Int) -> [ChapterDTO] {
        guard limit > 0, let chapterID, let idx = indexByID[chapterID] else { return [] }
        let start = idx + 1
        let end = min(chapters.count, start + limit)
        guard start < end else { return [] }
        return Array(chapters[start..<end])
    }

    subscript(index: Int) -> ChapterDTO {
        chapters[index]
    }
}
