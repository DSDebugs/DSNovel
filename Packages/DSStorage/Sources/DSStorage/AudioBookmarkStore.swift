import DSCore
import Foundation
import Observation

/// 音频时间戳书签类型（手动打点 vs 睡眠定时自动打点）
public enum AudioBookmarkKind: String, Codable, Sendable, Equatable {
    case manual
    case sleepAuto
}

/// 音频时间戳书签值模型（零 SwiftData Schema 侵入，独立原子 JSON 持久化）
public struct AudioBookmarkDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let bookID: String
    public let bookTitle: String
    public let chapterID: String
    public let chapterIndex: Int
    public let chapterTitle: String
    public let positionMs: Int
    public var note: String
    public let kind: AudioBookmarkKind
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        bookID: String,
        bookTitle: String,
        chapterID: String,
        chapterIndex: Int,
        chapterTitle: String,
        positionMs: Int,
        note: String = "",
        kind: AudioBookmarkKind = .manual,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.chapterID = chapterID
        self.chapterIndex = max(0, chapterIndex)
        self.chapterTitle = chapterTitle
        self.positionMs = max(0, positionMs)
        self.note = note
        self.kind = kind
        self.createdAt = createdAt
    }

    public var formattedPosition: String {
        let totalSeconds = max(0, positionMs / 1000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// 换书源或目录重拉导致 chapterID 漂移时，优先按 ID 匹配并按 chapterIndex 兜底定位
    public func resolveChapterIndex(in chapters: [ChapterDTO]) -> Int? {
        if let exact = chapters.firstIndex(where: { $0.id == chapterID }) {
            return exact
        }
        if chapters.indices.contains(chapterIndex) {
            return chapterIndex
        }
        return nil
    }
}

/// 音频书签持久化存储（原子 JSON 写入，不改动 DSNovelSchemaV1 保证老用户 100% 零迁移风险）
@Observable
@MainActor
public final class AudioBookmarkStore {
    public static let maxSleepAutoPerBook = 5

    public private(set) var allBookmarks: [AudioBookmarkDTO] = []
    private let fileURL: URL?

    public init(storageDirectory: URL?) {
        if let storageDirectory {
            self.fileURL = storageDirectory.appendingPathComponent("audio_bookmarks.json")
        } else {
            self.fileURL = nil
        }
        loadFromDisk()
    }

    public func bookmarks(forBookID bookID: String) -> [AudioBookmarkDTO] {
        guard !bookID.isEmpty else { return [] }
        return allBookmarks
            .filter { $0.bookID == bookID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func addBookmark(
        bookID: String,
        bookTitle: String,
        chapterID: String,
        chapterIndex: Int,
        chapterTitle: String,
        positionMs: Int,
        note: String = "",
        kind: AudioBookmarkKind = .manual,
        now: Date = Date()
    ) -> AudioBookmarkDTO {
        let entry = AudioBookmarkDTO(
            bookID: bookID,
            bookTitle: bookTitle,
            chapterID: chapterID,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            positionMs: max(0, positionMs),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            createdAt: now
        )
        allBookmarks.insert(entry, at: 0)
        if kind == .sleepAuto {
            pruneSleepAutoBookmarks(forBookID: bookID)
        }
        persistToDisk()
        return entry
    }

    public func updateNote(id: String, note: String) {
        guard let idx = allBookmarks.firstIndex(where: { $0.id == id }) else { return }
        allBookmarks[idx].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        persistToDisk()
    }

    public func deleteBookmark(id: String) {
        let before = allBookmarks.count
        allBookmarks.removeAll { $0.id == id }
        if allBookmarks.count != before {
            persistToDisk()
        }
    }

    public func deleteBookmarks(forBookID bookID: String) {
        let before = allBookmarks.count
        allBookmarks.removeAll { $0.bookID == bookID }
        if allBookmarks.count != before {
            persistToDisk()
        }
    }

    private func pruneSleepAutoBookmarks(forBookID bookID: String) {
        let sleepIDs = allBookmarks
            .filter { $0.bookID == bookID && $0.kind == .sleepAuto }
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.id)
        guard sleepIDs.count > Self.maxSleepAutoPerBook else { return }
        let removeSet = Set(sleepIDs.dropFirst(Self.maxSleepAutoPerBook))
        allBookmarks.removeAll { removeSet.contains($0.id) }
    }

    private func loadFromDisk() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            allBookmarks = try decoder.decode([AudioBookmarkDTO].self, from: data)
        } catch {
            allBookmarks = []
        }
    }

    private func persistToDisk() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(allBookmarks)
            try data.write(to: fileURL, options: [.atomic])
            var mutableURL = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
        } catch {
            // 写入失败时保持内存态可用，不崩溃
        }
    }
}
