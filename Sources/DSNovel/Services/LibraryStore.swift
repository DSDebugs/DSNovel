import Foundation
import Observation

@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    var bookshelf: [BookshelfEntry] = []
    var bookmarks: [AudioBookmark] = []
    var searchHistory: [String] = ["凡人修仙传", "剑来", "盗墓笔记", "明朝那些事儿", "三体", "郭德纲相声"]

    private let shelfKey = "dsnovel_v7_bookshelf"
    private let bookmarkKey = "dsnovel_v7_bookmarks"
    private let historyKey = "dsnovel_v7_search_history"

    private init() {
        loadAll()
        if bookshelf.isEmpty {
            seedStarterShelf()
        }
    }

    var favoriteEntries: [BookshelfEntry] {
        bookshelf.filter { $0.isFavorite }
    }

    var recentEntries: [BookshelfEntry] {
        bookshelf.sorted { $0.updatedAt > $1.updatedAt }
    }

    var mostRecentEntry: BookshelfEntry? {
        recentEntries.first
    }

    func isInBookshelf(_ bookId: String) -> Bool {
        bookshelf.contains { $0.book.id == bookId && $0.isFavorite }
    }

    func entry(for bookId: String) -> BookshelfEntry? {
        bookshelf.first { $0.book.id == bookId }
    }

    func toggleBookshelf(_ book: BookItem) {
        if let idx = bookshelf.firstIndex(where: { $0.book.id == book.id }) {
            bookshelf[idx].isFavorite.toggle()
            bookshelf[idx].updatedAt = Date()
            if !bookshelf[idx].isFavorite && bookshelf[idx].lastPlaybackTime <= 0 {
                bookshelf.remove(at: idx)
            }
        } else {
            let entry = BookshelfEntry(
                book: book,
                isFavorite: true,
                lastEpisodeIndex: 0,
                lastEpisodeTitle: "第1集",
                lastPlaybackTime: 0,
                updatedAt: Date()
            )
            bookshelf.insert(entry, at: 0)
        }
        saveShelf()
    }

    func removeFromBookshelf(_ bookId: String) {
        bookshelf.removeAll { $0.book.id == bookId }
        saveShelf()
    }

    func updateProgress(book: BookItem, episodeIndex: Int, episodeTitle: String, time: Double) {
        if let idx = bookshelf.firstIndex(where: { $0.book.id == book.id }) {
            var updated = bookshelf[idx]
            updated.lastEpisodeIndex = episodeIndex
            updated.lastEpisodeTitle = episodeTitle
            updated.lastPlaybackTime = time
            updated.updatedAt = Date()
            bookshelf.remove(at: idx)
            bookshelf.insert(updated, at: 0)
        } else {
            let entry = BookshelfEntry(
                book: book,
                isFavorite: true,
                lastEpisodeIndex: episodeIndex,
                lastEpisodeTitle: episodeTitle,
                lastPlaybackTime: time,
                updatedAt: Date()
            )
            bookshelf.insert(entry, at: 0)
        }
        saveShelf()
    }

    func addBookmark(book: BookItem, episodeIndex: Int, episodeTitle: String, timestamp: Double) {
        let bm = AudioBookmark(
            id: UUID().uuidString,
            bookId: book.id,
            bookTitle: book.title,
            episodeIndex: episodeIndex,
            episodeTitle: episodeTitle,
            timestamp: timestamp,
            note: "\(episodeTitle) · 书签标记",
            createdAt: Date()
        )
        bookmarks.insert(bm, at: 0)
        saveBookmarks()
    }

    func bookmarks(for bookId: String) -> [AudioBookmark] {
        bookmarks.filter { $0.bookId == bookId }
    }

    func removeBookmark(_ id: String) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
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
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    func seedStarterShelf() {
        let samples = DualSourceEngine.curatedFallbackBooks(for: UnifiedCategory.all[0])
        self.bookshelf = samples.map {
            BookshelfEntry(book: $0, isFavorite: true, lastEpisodeIndex: 0, lastEpisodeTitle: "第1集", lastPlaybackTime: 0, updatedAt: Date())
        }
        saveShelf()
    }

    private func saveShelf() {
        if let data = try? JSONEncoder().encode(bookshelf) {
            UserDefaults.standard.set(data, forKey: shelfKey)
        }
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    private func loadAll() {
        if let data = UserDefaults.standard.data(forKey: shelfKey),
           let decoded = try? JSONDecoder().decode([BookshelfEntry].self, from: data) {
            self.bookshelf = decoded
        }
        if let data = UserDefaults.standard.data(forKey: bookmarkKey),
           let decoded = try? JSONDecoder().decode([AudioBookmark].self, from: data) {
            self.bookmarks = decoded
        }
        if let hist = UserDefaults.standard.stringArray(forKey: historyKey), !hist.isEmpty {
            self.searchHistory = hist
        }
    }
}
