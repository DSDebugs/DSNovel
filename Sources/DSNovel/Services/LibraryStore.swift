import Foundation
import Observation

/// DSNovel v10.0 书架与收听历史存储
/// 核心准则：
/// 1. `shelfBooks`（我的书籍）：严格仅展示用户主动点击“加入书架”的书籍，不会因单纯播放而自动塞入书架，且不预置失效硬编码假封面书籍。
/// 2. `recentHistory`（最近收听）：纯收听历史记录，只要播放过即自动记录最新收听章节、播放秒数与收听时间。
/// 3. 若某本书已在 `shelfBooks` 中，播放时也会同步更新其在书架中的最新收听章节与时间记录。
@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    var shelfBooks: [BookshelfEntry] = []
    var recentHistory: [BookshelfEntry] = []
    var searchHistory: [String] = ["凡人修仙传", "剑来", "盗墓笔记", "明朝那些事儿", "三体", "郭德纲相声"]

    private let shelfKey = "dsnovel_v10_shelf_books"
    private let recentKey = "dsnovel_v10_recent_history"
    private let historyKey = "dsnovel_v10_search_history"

    private init() {
        loadAll()
    }

    /// 判断是否已主动加入“我的书架”
    func isInBookshelf(_ bookId: String) -> Bool {
        shelfBooks.contains { $0.book.id == bookId }
    }

    /// 获取某本书的收听进度记录（优先查最近收听，其次查书架）
    func entry(for bookId: String) -> BookshelfEntry? {
        recentHistory.first(where: { $0.book.id == bookId }) ??
        shelfBooks.first(where: { $0.book.id == bookId })
    }

    /// 主动加入或移出“我的书籍（书架）”
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

    /// 从“我的书籍（书架）”中删除指定书籍
    func removeFromBookshelf(_ bookId: String) {
        shelfBooks.removeAll { $0.book.id == bookId }
        saveShelf()
    }

    /// 清空“我的书籍（书架）”
    func clearBookshelf() {
        shelfBooks.removeAll()
        saveShelf()
    }

    /// 从“最近收听”记录中删除单条记录
    func removeFromRecentHistory(_ bookId: String) {
        recentHistory.removeAll { $0.book.id == bookId }
        saveRecent()
    }

    /// 清空全部“最近收听”记录
    func clearRecentHistory() {
        recentHistory.removeAll()
        saveRecent()
    }

    /// 播放时更新进度：自动写入 `recentHistory`（最近收听记录），若该书已在 `shelfBooks` 中则同步更新其最新章节与时间戳
    func updateProgress(book: BookItem, episodeIndex: Int, episodeTitle: String, time: Double) {
        let now = Date()
        let updatedEntry = BookshelfEntry(
            book: book,
            lastEpisodeIndex: episodeIndex,
            lastEpisodeTitle: episodeTitle,
            lastPlaybackTime: time,
            updatedAt: now
        )

        // 1. 更新最近收听记录
        recentHistory.removeAll { $0.book.id == book.id }
        recentHistory.insert(updatedEntry, at: 0)
        if recentHistory.count > 50 {
            recentHistory = Array(recentHistory.prefix(50))
        }
        saveRecent()

        // 2. 若用户已将该书加入书架，则同步更新书架中的最新收听章节与时间记录
        if let shelfIdx = shelfBooks.firstIndex(where: { $0.book.id == book.id }) {
            shelfBooks[shelfIdx].book = book
            shelfBooks[shelfIdx].lastEpisodeIndex = episodeIndex
            shelfBooks[shelfIdx].lastEpisodeTitle = episodeTitle
            shelfBooks[shelfIdx].lastPlaybackTime = time
            shelfBooks[shelfIdx].updatedAt = now
            saveShelf()
        }
    }

    /// 当封面自愈修复了书籍的真实 coverURL 时，同步更新书架与历史记录中的封面
    func updateBookCover(bookId: String, newCoverURL: String) {
        var shelfChanged = false
        for i in shelfBooks.indices where shelfBooks[i].book.id == bookId {
            shelfBooks[i].book.coverURL = newCoverURL
            shelfChanged = true
        }
        if shelfChanged { saveShelf() }

        var recentChanged = false
        for i in recentHistory.indices where recentHistory[i].book.id == bookId {
            recentHistory[i].book.coverURL = newCoverURL
            recentChanged = true
        }
        if recentChanged { saveRecent() }
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

    private func saveShelf() {
        if let data = try? JSONEncoder().encode(shelfBooks) {
            UserDefaults.standard.set(data, forKey: shelfKey)
        }
    }

    private func saveRecent() {
        if let data = try? JSONEncoder().encode(recentHistory) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
    }

    private func loadAll() {
        if let data = UserDefaults.standard.data(forKey: shelfKey),
           let decoded = try? JSONDecoder().decode([BookshelfEntry].self, from: data) {
            self.shelfBooks = decoded
        }
        if let data = UserDefaults.standard.data(forKey: recentKey),
           let decoded = try? JSONDecoder().decode([BookshelfEntry].self, from: data) {
            self.recentHistory = decoded
        }
        if let hist = UserDefaults.standard.stringArray(forKey: historyKey), !hist.isEmpty {
            self.searchHistory = hist
        }
    }
}
