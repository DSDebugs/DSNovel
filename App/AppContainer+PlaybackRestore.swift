import DSCore
import DSStorage
import Foundation

extension AppContainer {
    /// 冷启动优先从本地章节缓存秒恢复上次播放的书籍、章节与进度；返回是否需要联网补拉目录
    func restoreLastPlaybackFromCache() async -> Bool {
        guard playback.currentBook == nil,
              let session = await persistence.fetchLatestPlaybackSession() else { return false }
        if let cached = await chapterCache.loadChapters(bookID: session.book.id), !cached.isEmpty {
            let idx = Self.resolveRestoredChapterIndex(chapters: cached, session: session)
            playback.restoreSession(
                book: session.book,
                chapters: cached,
                chapterIndex: idx,
                positionMs: session.positionMs,
                durationMs: session.durationMs
            )
            return false
        }
        return true
    }

    /// 本地章节缓存缺失时，书源注册完成后联网补拉目录并恢复播放会话（若用户已主动开播则不覆盖）
    func restoreLastPlaybackFromSourceIfNeeded() async {
        guard playback.currentBook == nil,
              let session = await persistence.fetchLatestPlaybackSession() else { return }
        guard let detail = try? await pluginRuntime.bookDetail(
            sourceID: session.book.sourceID,
            book: session.book,
            loadFullPages: false
        ), !detail.chapters.isEmpty else { return }
        try? await chapterCache.saveChapters(detail.chapters, bookID: session.book.id)
        let idx = Self.resolveRestoredChapterIndex(chapters: detail.chapters, session: session)
        playback.restoreSession(
            book: session.book,
            chapters: detail.chapters,
            chapterIndex: idx,
            positionMs: session.positionMs,
            durationMs: session.durationMs
        )
    }

    private static func resolveRestoredChapterIndex(
        chapters: [ChapterDTO],
        session: PersistenceEngine.LastPlaybackSessionSnapshot
    ) -> Int {
        if !session.chapterID.isEmpty,
           let matched = chapters.firstIndex(where: { $0.id == session.chapterID }) {
            return matched
        }
        return min(max(0, session.chapterIndex), max(0, chapters.count - 1))
    }

    public func isXimalayaBook(_ book: BookSummaryDTO?) -> Bool {
        guard let book else { return false }
        if book.sourceID == Self.ximalayaSourceID { return true }
        if book.bookURL.localizedCaseInsensitiveContains("ximalaya.com") { return true }
        return book.sourceName.contains("喜马拉雅")
    }

    public var isCurrentBookFromXimalaya: Bool {
        isXimalayaBook(playback.currentBook)
    }

    public func resolvedQuality(for book: BookSummaryDTO) -> AudioQualityTier {
        guard isXimalayaBook(book) else { return .auto }
        let saved = settings.quality(forBookID: book.id)
        let allowUltraHigh = hasLoadedBuiltinParsers && canUseUltraHighQuality
        return (!allowUltraHigh && saved == .high) ? .standard : saved
    }

    public var isXimalayaQualityPreferenceAvailable: Bool {
        isCurrentBookFromXimalaya
    }
}
