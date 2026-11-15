import Foundation
import Observation
import os

@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    var shelfBooks: [BookshelfEntry] = []
    var recentHistory: [BookshelfEntry] = []
    var searchHistory: [String] = []

    private let logger = Logger(subsystem: "com.dsnovel.app", category: "LibraryStore")
    private let fileManager = FileManager.default

    private var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("DSNovel", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var shelfFileURL: URL { supportDirectory.appendingPathComponent("shelf_v2.json") }
    private var recentFileURL: URL { supportDirectory.appendingPathComponent("recent_v2.json") }
    private let historyKey = "dsnovel_v12_search_history"

    private init() {
        loadAll()
    }

    func isInBookshelf(_ bookId: String) -> Bool {
        shelfBooks.contains { $0.book.id == bookId }
    }

    func entry(for bookId: String) -> BookshelfEntry? {
        recentHistory.first(where: { $0.book.id == bookId }) ??
        shelfBooks.first(where: { $0.book.id == bookId })
    }

    func toggleBookshelf(_ book: BookItem, currentEpisodeIndex: Int? = nil, currentEpisodeTitle: String? = nil, currentTime: Double? = nil) {
        if let idx = shelfBooks.firstIndex(where: { $0.book.id == book.id }) {
            shelfBooks.remove(at: idx)
        } else {
            let existingRecord = recentHistory.first(where: { $0.book.id == book.id })
            let epIdx = currentEpisodeIndex ?? existingRecord?.lastEpisodeIndex ?? 0
            let epTitle = currentEpisodeTitle ?? existingRecord?.lastEpisodeTitle ?? "第1集"
            let playTime = currentTime ?? existingRecord?.lastPlaybackTime ?? 0
            let entry = BookshelfEntry(
                book: book,
                lastEpisodeIndex: epIdx,
                lastEpisodeTitle: epTitle,
                lastPlaybackTime: playTime,
                updatedAt: Date()
            )
            shelfBooks.insert(entry, at: 0)
        }
        saveShelf()
    }

    func removeFromBookshelf(_ bookId: String) {
        shelfBooks.removeAll { $0.book.id == bookId }
        saveShelf()
    }

    func clearBookshelf() {
        shelfBooks.removeAll()
        saveShelf()
    }

    func removeFromRecentHistory(_ bookId: String) {
        recentHistory.removeAll { $0.book.id == bookId }
        saveRecent()
    }

    func clearRecentHistory() {
        recentHistory.removeAll()
        saveRecent()
    }

    func updateProgress(book: BookItem, episodeIndex: Int, episodeTitle: String, time: Double) {
        let now = Date()
        let updatedEntry = BookshelfEntry(
            book: book,
            lastEpisodeIndex: episodeIndex,
            lastEpisodeTitle: episodeTitle,
            lastPlaybackTime: time,
            updatedAt: now
        )

        recentHistory.removeAll { $0.book.id == book.id }
        recentHistory.insert(updatedEntry, at: 0)
        if recentHistory.count > 50 {
            recentHistory = Array(recentHistory.prefix(50))
        }
        saveRecent()

        if let shelfIdx = shelfBooks.firstIndex(where: { $0.book.id == book.id }) {
            shelfBooks[shelfIdx].book = book
            shelfBooks[shelfIdx].lastEpisodeIndex = episodeIndex
            shelfBooks[shelfIdx].lastEpisodeTitle = episodeTitle
            shelfBooks[shelfIdx].lastPlaybackTime = time
            shelfBooks[shelfIdx].updatedAt = now
            saveShelf()
        }
    }

    func recordSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 12 {
            searchHistory = Array(searchHistory.prefix(12))
        }
        UserDefaults.standard.set(searchHistory, forKey: historyKey)
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        UserDefaults.standard.set([String](), forKey: historyKey)
    }

    private func saveShelf() {
        let archive = LibraryArchive(schemaVersion: 2, entries: shelfBooks)
        let url = shelfFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(archive) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func saveRecent() {
        let archive = LibraryArchive(schemaVersion: 2, entries: recentHistory)
        let url = recentFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(archive) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadAll() {
        self.shelfBooks = loadArchive(from: shelfFileURL)
        self.recentHistory = loadArchive(from: recentFileURL)
        if let hist = UserDefaults.standard.stringArray(forKey: historyKey) {
            self.searchHistory = hist
        }
    }

    private func loadArchive(from url: URL) -> [BookshelfEntry] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            if let archive = try? JSONDecoder().decode(LibraryArchive.self, from: data) {
                return archive.entries
            }
            if let legacy = try? JSONDecoder().decode([BookshelfEntry].self, from: data) {
                return legacy
            }
            // 解码失败时先备份损坏文件，防止静默覆写丢失数据 (H-10)
            let backupURL = url.deletingPathExtension().appendingPathExtension("corrupt.bak")
            try? fileManager.copyItem(at: url, to: backupURL)
            logger.error("Failed to decode archive at \(url.lastPathComponent), backed up to \(backupURL.lastPathComponent)")
        } catch {
            logger.error("Error reading \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return []
    }
}
