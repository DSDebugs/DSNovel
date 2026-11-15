import Foundation
import Observation
import os

@Observable
@MainActor
final class DualSourceEngine {
    static let shared = DualSourceEngine()

    var discoverBooks: [BookItem] = []
    var activeCategory: UnifiedCategory = UnifiedCategory.all[0]
    var isDiscoverLoading: Bool = false
    var discoverError: String? = nil

    var searchResults: [BookItem] = []
    var isSearching: Bool = false
    var searchError: String? = nil

    var loginNicknames: [CoreSourceID: String] = [:]
    var customCookies: [CoreSourceID: String] = [:]

    private struct CachedCategory {
        let books: [BookItem]
        let fetchedAt: Date
    }

    private var categoryCache: [String: CachedCategory] = [:]
    private var categoryPageCursors: [String: Int] = [:]
    private var episodeCache: [String: [EpisodeItem]] = [:]
    private var episodeCacheOrder: [String] = []
    private let maxCachedBooks = 20

    private var discoverToken = 0
    private var searchToken = 0

    private let logger = Logger(subsystem: "com.dsnovel.app", category: "DualSourceEngine")
    private let urlSession: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = [
            "Accept-Language": "zh-CN,zh;q=0.9",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]
        self.urlSession = URLSession(configuration: config)
        loadSavedCookies()
    }

    // MARK: - 发现页加载（带过期保护、30分钟缓存 TTL 与真实换一批翻页，M-01/M-03/H-06）
    func loadDiscover(category: UnifiedCategory? = nil, forceRefresh: Bool = false) async {
        if let category { self.activeCategory = category }
        let targetCat = self.activeCategory

        discoverToken += 1
        let myToken = discoverToken

        let nextPage: Int
        if forceRefresh {
            nextPage = (categoryPageCursors[targetCat.id] ?? 1) + 1
            categoryPageCursors[targetCat.id] = nextPage
        } else {
            nextPage = categoryPageCursors[targetCat.id] ?? 1
        }

        let cacheKey = "\(targetCat.id)_p\(nextPage)"
        if !forceRefresh,
           let cached = categoryCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < 1800,
           !cached.books.isEmpty {
            self.discoverBooks = cached.books
            self.discoverError = nil
            return
        }

        self.isDiscoverLoading = true
        self.discoverError = nil

        do {
            let books = try await fetchCategoryAlbums(category: targetCat, page: nextPage)
            guard myToken == discoverToken else { return }
            if books.isEmpty {
                self.discoverError = "当前分类暂无更多内容，请点击重试"
            } else {
                self.discoverBooks = books
                self.categoryCache[cacheKey] = CachedCategory(books: books, fetchedAt: Date())
            }
        } catch {
            guard myToken == discoverToken else { return }
            self.discoverError = "网络请求失败：\(error.localizedDescription)"
            logger.error("Discover load failed: \(error.localizedDescription)")
        }

        if myToken == discoverToken {
            self.isDiscoverLoading = false
        }
    }

    // MARK: - 搜索（带过期保护与错误提示，H-06）
    func performSearch(keyword: String) async {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }

        searchToken += 1
        let myToken = searchToken

        self.isSearching = true
        self.searchError = nil

        do {
            let results = try await searchAlbums(keyword: kw, page: 1)
            guard myToken == searchToken else { return }
            self.searchResults = results
            if results.isEmpty {
                self.searchError = "未找到与“\(kw)”相关的有声书，请尝试更换关键词"
            }
        } catch {
            guard myToken == searchToken else { return }
            self.searchError = "搜索失败：\(error.localizedDescription)"
        }

        if myToken == searchToken {
            self.isSearching = false
        }
    }

    func clearSearchResults() {
        searchToken += 1
        self.searchResults = []
        self.searchError = nil
        self.isSearching = false
    }

    // MARK: - 章节目录并发加载（严格校验完整性，缺页不入缓存且保留真实序号，H-04/M-06）
    func fetchAllBookEpisodes(for book: BookItem, forceRefresh: Bool = false) async -> EpisodeListResult {
        if !forceRefresh, let cached = episodeCache[book.id], !cached.isEmpty {
            return EpisodeListResult(episodes: cached, isComplete: true, failedPages: [])
        }

        let result = await fetchAlbumTracksConcurrently(albumId: book.albumId, bookTitle: book.title)
        if result.isComplete && !result.episodes.isEmpty {
            cacheEpisodes(result.episodes, for: book.id)
        }
        return result
    }

    private func cacheEpisodes(_ list: [EpisodeItem], for bookId: String) {
        episodeCache[bookId] = list
        episodeCacheOrder.removeAll { $0 == bookId }
        episodeCacheOrder.append(bookId)
        while episodeCacheOrder.count > maxCachedBooks {
            let oldest = episodeCacheOrder.removeFirst()
            episodeCache.removeValue(forKey: oldest)
        }
    }

    // MARK: - 合法公开音频流解析（严格检查 isFree，绝不绕过付费鉴权，M-05）
    func resolveStreamURL(for episode: EpisodeItem, in book: BookItem) async throws -> URL {
        guard episode.isFree || isAuthenticated(for: book.source) else {
            throw NSError(domain: "DSNovelAudio", code: -403, userInfo: [
                NSLocalizedDescriptionKey: "该章节为付费/会员专享内容，请先登录官方账号或选择免费章节收听"
            ])
        }

        if let direct = episode.directStreamURL,
           let url = URL(string: BookItem.normalizeHttps(direct)),
           Self.isLikelyAudioURL(url) {
            return url
        }

        let cleanTrackId = episode.trackId.hasPrefix("xm_") ? String(episode.trackId.dropFirst(3)) : episode.trackId
        guard cleanTrackId.allSatisfy({ $0.isASCII && $0.isNumber }), !cleanTrackId.isEmpty else {
            throw NSError(domain: "DSNovelAudio", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "无效的章节标识"
            ])
        }

        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let mobURL = URL(string: "https://mobile.ximalaya.com/mobile/playpage/track/v3/baseInfo/\(ts)?device=iPhone&trackId=\(cleanTrackId)") else {
            throw NSError(domain: "DSNovelAudio", code: -400, userInfo: [NSLocalizedDescriptionKey: "无效的请求地址"])
        }

        var req = URLRequest(url: mobURL)
        if let host = mobURL.host, Self.isOfficialXimalayaHost(host),
           let cookie = customCookies[.ximalaya], !cookie.isEmpty {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, resp) = try await performCompliantRequest(req)
        if !(200..<300).contains(resp.statusCode) {
            throw NSError(domain: "DSNovelAudio", code: resp.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "音频接口返回状态 \(resp.statusCode)"
            ])
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let trackInfo = json["trackInfo"] as? [String: Any] {
            let raw = (trackInfo["playUrl64"] as? String) ??
                      (trackInfo["playPathAacv164"] as? String) ??
                      (trackInfo["playUrl32"] as? String) ?? ""
            if !raw.isEmpty, let validURL = URL(string: BookItem.normalizeHttps(raw)) {
                return validURL
            }
        }

        throw NSError(domain: "DSNovelAudio", code: -404, userInfo: [
            NSLocalizedDescriptionKey: "未获取到可用音频流地址，可能需要登录或购买后收听"
        ])
    }

    // MARK: - 后台解析接口数据（非主线程执行 JSON 解析，M-06）

    private func performCompliantRequest(_ originalRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch QXRewriteParserEngine.shared.preprocessRequest(originalRequest) {
        case .localResponse(let localData, let localResp):
            return (localData, localResp)
        case .proceed(let preparedReq):
            let (rawData, rawResp) = try await urlSession.data(for: preparedReq)
            let httpResp = (rawResp as? HTTPURLResponse) ?? HTTPURLResponse(url: preparedReq.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return QXRewriteParserEngine.shared.processResponse(request: preparedReq, response: httpResp, data: rawData)
        }
    }

    private func fetchCategoryAlbums(category: UnifiedCategory, page: Int) async throws -> [BookItem] {
        guard let enc = category.keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://search.ximalaya.com/front/v1?core=album&kw=\(enc)&page=\(page)&rows=25&spellchecker=true&condition=relation&device=android&version=9.0.75&paidFilter=false") else {
            return []
        }
        let (data, _) = try await performCompliantRequest(URLRequest(url: url))
        return await Task.detached(priority: .userInitiated) {
            Self.parseSearchDocs(data: data, categoryName: category.title)
        }.value
    }

    private func searchAlbums(keyword: String, page: Int) async throws -> [BookItem] {
        guard let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://search.ximalaya.com/front/v1?core=album&kw=\(enc)&page=\(page)&rows=25&spellchecker=true&condition=relation&device=android&version=9.0.75&paidFilter=false") else {
            return []
        }
        let (data, _) = try await performCompliantRequest(URLRequest(url: url))
        return await Task.detached(priority: .userInitiated) {
            Self.parseSearchDocs(data: data, categoryName: "搜索结果")
        }.value
    }

    nonisolated private static func parseSearchDocs(data: Data, categoryName: String) -> [BookItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = json["response"] as? [String: Any],
              let docs = resp["docs"] as? [[String: Any]] else {
            return []
        }
        let items = docs.compactMap { doc -> BookItem? in
            guard let idVal = doc["id"] ?? doc["album_id"],
                  let rawTitle = doc["title"] as? String, !rawTitle.isEmpty else { return nil }
            let idStr = String(describing: idVal)
            let cover = (doc["cover_path"] as? String) ?? (doc["album_cover_path"] as? String) ?? ""
            let author = (doc["nickname"] as? String) ?? ""
            let intro = (doc["intro"] as? String) ?? ""
            let tracks = (doc["tracks_counts"] as? Int) ?? (doc["tracks"] as? Int) ?? 0
            let isPaid = (doc["is_paid"] as? Bool) ?? ((doc["is_paid"] as? String) == "true")
            return BookItem(
                source: .ximalaya,
                albumId: idStr,
                title: rawTitle,
                author: author,
                coverURL: cover,
                intro: intro,
                categoryName: categoryName,
                statusText: (isPaid ? "VIP/付费" : "免费公开") + (tracks > 0 ? " · 共\(tracks)集" : ""),
                totalTracks: tracks,
                isCompletelyFree: !isPaid
            )
        }
        return deduplicateBooks(items).sorted { ($0.isCompletelyFree ? 0 : 1) < ($1.isCompletelyFree ? 0 : 1) }
    }

    private func fetchAlbumTracksConcurrently(albumId: String, bookTitle: String) async -> EpisodeListResult {
        let firstURLStr = "https://mobile.ximalaya.com/mobile/v1/album/track?albumId=\(albumId)&pageId=1&pageSize=200&isAsc=true&device=android"
        guard let firstURL = URL(string: firstURLStr),
              let (data, _) = try? await performCompliantRequest(URLRequest(url: firstURL)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let firstList = dataObj["list"] as? [[String: Any]] else {
            return EpisodeListResult(episodes: [], isComplete: false, failedPages: [1])
        }

        let maxPage = max(1, (dataObj["maxPageId"] as? Int) ?? 1)
        var pageMap: [Int: [[String: Any]]] = [1: firstList]
        var failedPages: [Int] = []

        if maxPage > 1 {
            let session = urlSession
            await withTaskGroup(of: (Int, Data?).self) { group in
                for p in 2...maxPage {
                    group.addTask {
                        let uStr = "https://mobile.ximalaya.com/mobile/v1/album/track?albumId=\(albumId)&pageId=\(p)&pageSize=200&isAsc=true&device=android"
                        guard let u = URL(string: uStr),
                              let (pData, _) = try? await session.data(from: u) else {
                            return (p, nil)
                        }
                        return (p, pData)
                    }
                }
                for await (p, maybeData) in group {
                    if let pData = maybeData,
                       let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
                       let pObj = pJson["data"] as? [String: Any],
                       let pList = pObj["list"] as? [[String: Any]] {
                        pageMap[p] = pList
                    } else {
                        failedPages.append(p)
                    }
                }
            }
        }

        // 在后台解析与清洗标题，同时保留原始顺序号（H-04）
        let capturedMap = pageMap
        let episodes = await Task.detached(priority: .userInitiated) {
            var out: [EpisodeItem] = []
            for p in 1...maxPage {
                guard let list = capturedMap[p] else { continue }
                let pageOffset = (p - 1) * 200
                for (idxInPage, item) in list.enumerated() {
                    let originalIndex = (item["orderNum"] as? Int).map { $0 + 1 } ?? (pageOffset + idxInPage + 1)
                    let tid = String(describing: item["trackId"] ?? originalIndex)
                    let title = (item["title"] as? String) ?? "第\(originalIndex)集"
                    let duration = (item["duration"] as? Int) ?? 0
                    let isPaid = (item["isPaid"] as? Bool) ?? false
                    let isFreeFlag = (item["isFree"] as? Bool) ?? false
                    let free = !isPaid || isFreeFlag
                    let direct = BookItem.normalizeHttps(
                        (item["playUrl64"] as? String) ??
                        (item["playPathAacv164"] as? String) ??
                        (item["playUrl32"] as? String) ?? ""
                    )
                    out.append(EpisodeItem(
                        trackId: "xm_\(tid)",
                        index: originalIndex,
                        rawTitle: title,
                        bookTitle: bookTitle,
                        durationSeconds: duration,
                        isFree: free,
                        directStreamURL: direct.isEmpty ? nil : direct
                    ))
                }
            }
            return out
        }.value

        return EpisodeListResult(
            episodes: episodes,
            isComplete: failedPages.isEmpty,
            failedPages: failedPages.sorted()
        )
    }

    // MARK: - 安全域名与音频直链校验 (H-07, M-05)
    nonisolated static func isOfficialXimalayaHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "ximalaya.com" || lower.hasSuffix(".ximalaya.com") || lower == "xmcdn.com" || lower.hasSuffix(".xmcdn.com")
    }

    nonisolated static func isLikelyAudioURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "flac"].contains(ext) {
            return true
        }
        if let host = url.host?.lowercased(), host.hasSuffix(".xmcdn.com") {
            return true
        }
        return false
    }

    // MARK: - Keychain 凭证管理 (H-07)
    func isAuthenticated(for source: CoreSourceID) -> Bool {
        guard let c = customCookies[source], !c.isEmpty else { return false }
        return true
    }

    func saveCookies(_ cookieHeader: String, for source: CoreSourceID) {
        customCookies[source] = cookieHeader
        KeychainHelper.save(cookieHeader, forKey: "cookie_\(source.rawValue)")
        loginNicknames[source] = "\(source.displayName)已登录"
        KeychainHelper.save("\(source.displayName)已登录", forKey: "nick_\(source.rawValue)")
    }

    func logout(source: CoreSourceID) {
        customCookies.removeValue(forKey: source)
        loginNicknames.removeValue(forKey: source)
        KeychainHelper.delete(forKey: "cookie_\(source.rawValue)")
        KeychainHelper.delete(forKey: "nick_\(source.rawValue)")
    }

    private func loadSavedCookies() {
        for source in CoreSourceID.allCases {
            if let c = KeychainHelper.load(forKey: "cookie_\(source.rawValue)"), !c.isEmpty {
                customCookies[source] = c
            }
            if let n = KeychainHelper.load(forKey: "nick_\(source.rawValue)"), !n.isEmpty {
                loginNicknames[source] = n
            }
        }
    }

    func clearAllCaches() {
        categoryCache.removeAll()
        categoryPageCursors.removeAll()
        episodeCache.removeAll()
        episodeCacheOrder.removeAll()
    }

    // MARK: - 保留同书不同演播版本去重 (M-02)
    nonisolated static func deduplicateBooks(_ list: [BookItem]) -> [BookItem] {
        var seen = Set<String>()
        var out: [BookItem] = []
        for b in list {
            let key = "\(b.source.rawValue)_\(b.title)_\(b.author)"
            if !seen.contains(key) {
                seen.insert(key)
                out.append(b)
            }
        }
        return out
    }

    nonisolated static func interleaveBooks(primary: [BookItem], secondary: [BookItem]) -> [BookItem] {
        var result: [BookItem] = []
        let maxCount = max(primary.count, secondary.count)
        for i in 0..<maxCount {
            if i < primary.count { result.append(primary[i]) }
            if i < secondary.count { result.append(secondary[i]) }
        }
        return deduplicateBooks(result)
    }
}
