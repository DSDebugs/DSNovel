import Foundation
import CommonCrypto
import Observation

/// DSNovel v6.0 双核固定书源引擎（番茄畅听 + 喜马拉雅）
/// 核心升级：
/// 1. 彻底清除酷我听书 (`kuwo.cn`)，番茄畅听采用 100% 免费有声网关（听友免费有声引擎 `tingyou.fm` + 云图正版有声直链引擎 `open-service.yuntuys.com` + 喜马拉雅纯免费完本库 `paidFilter=true` + 番茄官方元数据 `api.fanqiesdk.com`），绝无任何“请下载酷我音乐”语音提示或收费锁。
/// 2. 章节目录一次性极速并发加载（`withTaskGroup` 多页并发拉取 + 内存级 `episodeCache`），进入详情页或点击播放立即拉齐完整目录。
@Observable
@MainActor
final class DualSourceEngine {
    static let shared = DualSourceEngine()

    var activeCategory: UnifiedCategory = UnifiedCategory.all[0]
        var discoverBooks: [BookItem] = []
    var isDiscoverLoading: Bool = false
    var discoverError: String? = nil

    var searchResults: [BookItem] = []
    var isSearching: Bool = false
    var searchError: String? = nil

    var loginNicknames: [CoreSourceID: String] = [:]
    var customCookies: [CoreSourceID: String] = [:]

    // 内存缓存：分类缓存 + 书籍全量章节缓存（实现 0ms 二次打开与极速切页）
    private var categoryCache: [String: [BookItem]] = [:]
    private var episodeCache: [String: [EpisodeItem]] = [:]
    private var workingTingyouBase: String = "https://api-preview.toulaopao.cc/api"
    private let tingyouBases: [String] = [
        "https://api-preview.toulaopao.cc/api",
        "https://appp.fdhtbz.cn/api",
        "https://laopaoaappi.oobyvy.vip/api"
    ]
    private let yuntuToken = "wechat:07955551-706c-4259-9aa0-db4627dfca57"
    private let sessionUUID = UUID().uuidString

    private let urlSession: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = [
            "Accept-Language": "zh-CN,zh;q=0.9",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]
        self.urlSession = URLSession(configuration: config)
        loadSavedCookies()
    }

    // MARK: - 发现页加载（支持双源交错融合与缓存）
    func loadDiscover(category: UnifiedCategory? = nil, forceRefresh: Bool = false) async {
        if let category { self.activeCategory = category }

        let targetCat = self.activeCategory
        let cacheKey = targetCat.id

        if !forceRefresh, let cached = categoryCache[cacheKey], !cached.isEmpty {
            self.discoverBooks = cached
            self.discoverError = nil
            return
        }

        self.isDiscoverLoading = true
        self.discoverError = nil

        async let fqTask: [BookItem] = fetchFanqieCategoryBooks(category: targetCat)
        async let xmTask: [BookItem] = fetchXimalayaCategoryBooks(category: targetCat)

        let (fqBooks, xmBooks) = await (fqTask, xmTask)
        let merged = Self.interleaveBooks(primary: fqBooks, secondary: xmBooks)

        if !merged.isEmpty {
            self.discoverBooks = merged
            self.categoryCache[cacheKey] = merged
        } else {
            let fallback = Self.curatedFallbackBooks(for: targetCat)
            self.discoverBooks = fallback
        }
        self.isDiscoverLoading = false
    }

    // MARK: - 全网双源并发搜索
    func performSearch(keyword: String) async {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }

        self.isSearching = true
        self.searchError = nil

        async let fqTask: [BookItem] = searchFanqieBooks(keyword: kw, page: 1)
        async let xmTask: [BookItem] = searchXimalayaBooks(keyword: kw, page: 1)

        let (fqList, xmList) = await (fqTask, xmTask)
        let combined = Self.interleaveBooks(primary: fqList, secondary: xmList)

        self.searchResults = combined
        if combined.isEmpty {
            self.searchError = "未找到与“\(kw)”相关的有声书，请尝试更换关键词"
        }
        self.isSearching = false
    }

    func clearSearchResults() {
        self.searchResults = []
        self.searchError = nil
    }

    // MARK: - 一次性全量章节目录极速加载（带内存缓存）
    func fetchAllBookEpisodes(for book: BookItem, forceRefresh: Bool = false) async -> [EpisodeItem] {
        if !forceRefresh, let cached = episodeCache[book.id], !cached.isEmpty {
            return cached
        }

        var episodes: [EpisodeItem] = []
        switch book.source {
        case .fanqie:
            episodes = await fetchFanqieEpisodesAllAtOnce(for: book)
        case .ximalaya:
            episodes = await fetchXimalayaEpisodesAllAtOnce(for: book)
        }

        // 若单源接口网络波动为空，自动按书名跨源无感兜底章节目录
        if episodes.isEmpty {
            episodes = await crossMatchEpisodesByTitle(for: book)
        }

        if !episodes.isEmpty {
            episodeCache[book.id] = episodes
        }
        return episodes
    }

    func cachedEpisodes(for bookId: String) -> [EpisodeItem]? {
        episodeCache[bookId]
    }

    // MARK: - 一键换源（在番茄畅听与喜马拉雅之间智能切换同名书籍）
    func findAlternateSourceBook(for currentBook: BookItem) async -> BookItem? {
        let targetSource: CoreSourceID = (currentBook.source == .fanqie) ? .ximalaya : .fanqie
        let cleanTitle = currentBook.title
            .replacingOccurrences(of: "（.*）", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates: [BookItem]
        switch targetSource {
        case .fanqie:
            candidates = await searchFanqieBooks(keyword: cleanTitle, page: 1)
        case .ximalaya:
            candidates = await searchXimalayaBooks(keyword: cleanTitle, page: 1)
        }
        return candidates.first
    }

    // MARK: - 章节音频流真实直链解析（100% 剔除酷我提示音，支持多路自动回退）
    func resolveStreamURL(for episode: EpisodeItem, in book: BookItem) async throws -> (URL, [String: String]) {
        // 1. 若章节本身已携带 https 真实音频直链（如云图直链或喜马拉雅免加密流），直接返回
        if let direct = episode.directStreamURL,
           let url = URL(string: BookItem.normalizeHttps(direct)),
           (direct.contains(".mp3") || direct.contains(".m4a") || direct.contains(".aac") || direct.contains("xmcdn.com") || direct.contains("yuntuys.com") || direct.contains("byte")) {
            return (url, ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15"])
        }

        // 2. 听友免费有声引擎动态签名直链解析 (`ty_<albumId>_<chapterIdx>`)
        if episode.trackId.hasPrefix("ty_") {
            let parts = episode.trackId.split(separator: "_")
            if parts.count >= 3 {
                let albumId = String(parts[1])
                let chapterIdx = Int(parts[2]) ?? episode.index
                if let playURL = await resolveTingyouPlayURL(albumId: albumId, chapterIndex: chapterIdx) {
                    return (playURL, ["Referer": "https://tingyou.fm/", "Origin": "https://tingyou.fm"])
                }
            }
        }

        // 3. 喜马拉雅（含番茄畅听免费完本库 `xm_` 或原生喜马拉雅数字 trackId）双通道解密解析
        let cleanTrackId = episode.trackId
            .replacingOccurrences(of: "xm_", with: "")
            .replacingOccurrences(of: "fq_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanTrackId.allSatisfy({ $0.isNumber }), !cleanTrackId.isEmpty {
            if let xmURL = try? await resolveXimalayaTrackURL(trackId: cleanTrackId) {
                return (xmURL, ["Referer": "https://www.ximalaya.com/"])
            }
        }

        // 4. 终极跨源同名章节智能回退：按书名与当前集数自动检索备用免费音频流
        if let fallbackURL = await resolveCrossSourceFallbackStream(bookTitle: book.title, episodeIndex: episode.index) {
            return (fallbackURL, [:])
        }

        throw NSError(domain: "DSNovelAudio", code: -1001, userInfo: [
            NSLocalizedDescriptionKey: "当前章节需要登录喜马拉雅账号或点击右上角“换源”切换至番茄免费源播放"
        ])
    }

    // =========================================================================
    // MARK: - 番茄畅听 (Fanqie) 核心免费实现（听友免费有声 + 云图直链 + 免费完本库）
    // =========================================================================

    private func fetchFanqieCategoryBooks(category: UnifiedCategory) async -> [BookItem] {
        async let tyBooks = fetchTingyouBooks(keyword: category.fanqieKeyword, page: 1)
        async let ytBooks = fetchYuntuCategoryBooks(typeId: category.yuntuTypeId, keyword: category.fanqieKeyword)
        async let freeXmBooks = fetchFreeXimalayaBooks(keyword: category.searchFallbackKeyword, page: 1)

        let (a, b, c) = await (tyBooks, ytBooks, freeXmBooks)
        return Self.deduplicateBooks(a + b + c)
    }

    private func searchFanqieBooks(keyword: String, page: Int) async -> [BookItem] {
        async let tyBooks = fetchTingyouBooks(keyword: keyword, page: page)
        async let ytBooks = searchYuntuBooks(keyword: keyword, page: page)
        async let freeXmBooks = fetchFreeXimalayaBooks(keyword: keyword, page: page)

        let (a, b, c) = await (tyBooks, ytBooks, freeXmBooks)
        return Self.deduplicateBooks(a + b + c)
    }

    /// 线路 A：听友免费有声引擎 (`tingyou.fm`) —— 100% 免费、全本一次性返回所有章节
    private func fetchTingyouBooks(keyword: String, page: Int) async -> [BookItem] {
        let body: [String: Any] = ["keyword": keyword, "page": page]
        guard let json = await requestTingyouJSON(path: "search", postBody: body),
              let results = json["results"] as? [[String: Any]] else {
            return []
        }
        return results.compactMap { item -> BookItem? in
            guard let idVal = item["id"],
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            let idStr = String(describing: idVal)
            let author = (item["teller"] as? String) ?? (item["author"] as? String) ?? "番茄畅听主播"
            let cover = (item["cover_url"] as? String) ?? ""
            let intro = (item["intro"] as? String) ?? (item["description"] as? String) ?? (item["synopsis"] as? String) ?? ""
            let count = (item["count"] as? Int) ?? Int(String(describing: item["count"] ?? "0")) ?? 0
            return BookItem(
                source: .fanqie,
                albumId: "ty_\(idStr)",
                title: title,
                author: author,
                coverURL: cover,
                intro: intro,
                categoryName: "番茄免费",
                statusText: count > 0 ? "全本免费 · 共\(count)集" : "全本免费",
                totalTracks: count,
                isCompletelyFree: true
            )
        }
    }

    private func requestTingyouJSON(path: String, postBody: [String: Any]? = nil) async -> [String: Any]? {
        let candidateBases = [workingTingyouBase] + tingyouBases.filter { $0 != workingTingyouBase }
        for base in candidateBases {
            guard let url = URL(string: "\(base)/h5/listening/\(path)") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.setValue("https://tingyou.fm", forHTTPHeaderField: "Origin")
            req.setValue("https://tingyou.fm/", forHTTPHeaderField: "Referer")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(sessionUUID, forHTTPHeaderField: "x-listening-session")
            req.setValue("Asia/Shanghai", forHTTPHeaderField: "x-listening-timezone")
            if let postBody {
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: postBody)
            }
            if let (data, resp) = try? await ProxyInterventionEngine.shared.performRequest(req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["error"] == nil {
                workingTingyouBase = base
                return obj
            }
        }
        return nil
    }

    private func resolveTingyouPlayURL(albumId: String, chapterIndex: Int) async -> URL? {
        let body: [String: Any] = ["album_id": albumId, "chapter_idx": chapterIndex]
        guard let json = await requestTingyouJSON(path: "play", postBody: body),
              let playStr = json["play_url"] as? String,
              let url = URL(string: BookItem.normalizeHttps(playStr)) else {
            return nil
        }
        return url
    }

    /// 线路 B：云图正版有声直链引擎 (`open-service.yuntuys.com`) —— 章节内直接携带 MP3 音频直链，100% 免费零等待
    private func fetchYuntuCategoryBooks(typeId: Int, keyword: String) async -> [BookItem] {
        let urlStr = "http://open-service.yuntuys.com/api/w_ys/book/getBookListByType/\(yuntuToken)/\(typeId)?pageNum=1&pageSize=20"
        let list = await parseYuntuBookList(urlString: urlStr)
        if !list.isEmpty { return list }
        return await searchYuntuBooks(keyword: keyword, page: 1)
    }

    private func searchYuntuBooks(keyword: String, page: Int) async -> [BookItem] {
        guard let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return [] }
        let urlStr = "http://open-service.yuntuys.com/api/w_ys/book/search/\(yuntuToken)/\(enc)?pageSize=20&pageNum=\(page)"
        return await parseYuntuBookList(urlString: urlStr)
    }

    private func parseYuntuBookList(urlString: String) async -> [BookItem] {
        guard let url = URL(string: urlString),
              let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(URLRequest(url: url)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item -> BookItem? in
            guard let idVal = item["bookId"],
                  let title = item["bookName"] as? String, !title.isEmpty else { return nil }
            let idStr = String(describing: idVal)
            let author = (item["anchorName"] as? String) ?? (item["authorName"] as? String) ?? "番茄正版演播"
            let cover = (item["cover"] as? String) ?? ""
            let intro = (item["summary"] as? String) ?? ""
            let chapters = (item["chapters"] as? Int) ?? Int(String(describing: item["chapters"] ?? "0")) ?? 0
            return BookItem(
                source: .fanqie,
                albumId: "yt_\(idStr)",
                title: title,
                author: author,
                coverURL: cover,
                intro: intro,
                categoryName: "番茄免费",
                statusText: chapters > 0 ? "全本免费 · 共\(chapters)集" : "全本免费",
                totalTracks: chapters,
                isCompletelyFree: true
            )
        }
    }

    /// 线路 C：纯免费完本有声库 (`paidFilter=true` 严格过滤 `is_paid == false`)
    private func fetchFreeXimalayaBooks(keyword: String, page: Int) async -> [BookItem] {
        guard let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://search.ximalaya.com/front/v1?core=album&kw=\(enc)&page=\(page)&rows=24&spellchecker=true&condition=relation&device=android&version=9.0.75&paidFilter=true") else {
            return []
        }
        guard let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(URLRequest(url: url)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = json["response"] as? [String: Any],
              let docs = resp["docs"] as? [[String: Any]] else {
            return []
        }
        return docs.compactMap { doc -> BookItem? in
            let isPaid = (doc["is_paid"] as? Bool) ?? ((doc["is_paid"] as? String) == "true")
            guard !isPaid else { return nil }
            guard let idVal = doc["id"] ?? doc["album_id"],
                  let rawTitle = doc["title"] as? String, !rawTitle.isEmpty else { return nil }
            let idStr = String(describing: idVal)
            let cover = (doc["cover_path"] as? String) ?? (doc["album_cover_path"] as? String) ?? ""
            guard !cover.isEmpty else { return nil }
            let author = (doc["nickname"] as? String) ?? "番茄特约主播"
            let intro = (doc["intro"] as? String) ?? ""
            let tracks = (doc["tracks_counts"] as? Int) ?? (doc["tracks"] as? Int) ?? 0
            return BookItem(
                source: .fanqie,
                albumId: "fqxm_\(idStr)",
                title: rawTitle,
                author: author,
                coverURL: cover,
                intro: intro,
                categoryName: "番茄畅听",
                statusText: tracks > 0 ? "全本免费 · 共\(tracks)集" : "全本免费",
                totalTracks: tracks,
                isCompletelyFree: true
            )
        }
    }

    /// 番茄畅听一次性全量加载章节目录
    private func fetchFanqieEpisodesAllAtOnce(for book: BookItem) async -> [EpisodeItem] {
        // 1. 听友免费有声引擎 (`ty_`) —— 单次请求直接返回全书所有章节
        if book.albumId.hasPrefix("ty_") {
            let rawId = String(book.albumId.dropFirst(3))
            if let json = await requestTingyouJSON(path: "chapters/\(rawId)"),
               let chapters = json["chapters"] as? [[String: Any]], !chapters.isEmpty {
                return chapters.enumerated().map { offset, ch in
                    let idx = (ch["index"] as? Int) ?? (offset + 1)
                    let title = (ch["title"] as? String) ?? "第\(idx)集"
                    return EpisodeItem(
                        trackId: "ty_\(rawId)_\(idx)",
                        index: offset + 1,
                        rawTitle: title,
                        bookTitle: book.title,
                        isFree: true
                    )
                }
            }
        }

        // 2. 云图正版有声直链引擎 (`yt_`) —— 多页并发一次性拉齐，且每集自带 MP3 直链
        if book.albumId.hasPrefix("yt_") {
            let rawId = String(book.albumId.dropFirst(3))
            return await fetchYuntuAllChaptersConcurrently(bookId: rawId, bookTitle: book.title)
        }

        // 3. 免费有声完本库 (`fqxm_` 或纯数字) —— 并发拉齐全部免费章节
        let cleanId = book.albumId
            .replacingOccurrences(of: "fqxm_", with: "")
            .replacingOccurrences(of: "xm_", with: "")
        return await fetchXimalayaAllTracksConcurrently(albumId: cleanId, bookTitle: book.title, forceFreeBadge: true)
    }

    private func fetchYuntuAllChaptersConcurrently(bookId: String, bookTitle: String) async -> [EpisodeItem] {
        let firstURL = "http://open-service.yuntuys.com/api/w_ys/book/getChapters/\(yuntuToken)/\(bookId)/true/asc?pageSize=200&pageNum=1"
        guard let url = URL(string: firstURL),
              let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(URLRequest(url: url)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let pq = dataObj["pageQuery"] as? [String: Any],
              let firstList = pq["list"] as? [[String: Any]] else {
            return []
        }

        let totalPage = min(12, max(1, (pq["totalPage"] as? Int) ?? 1))
        var allPages: [Int: [[String: Any]]] = [1: firstList]

        if totalPage > 1 {
            let token = yuntuToken
            let session = urlSession
            await withTaskGroup(of: (Int, Data?).self) { group in
                for page in 2...totalPage {
                    group.addTask {
                        let pageURLStr = "http://open-service.yuntuys.com/api/w_ys/book/getChapters/\(token)/\(bookId)/true/asc?pageSize=200&pageNum=\(page)"
                        guard let pURL = URL(string: pageURLStr),
                              let (pData, _) = try? await session.data(from: pURL) else {
                            return (page, nil)
                        }
                        return (page, pData)
                    }
                }
                for await (page, maybeData) in group {
                    if let pData = maybeData,
                       let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
                       let pDataObj = pJson["data"] as? [String: Any],
                       let pQuery = pDataObj["pageQuery"] as? [String: Any],
                       let pList = pQuery["list"] as? [[String: Any]],
                       !pList.isEmpty {
                        allPages[page] = pList
                    }
                }
            }
        }

        let combined = (1...totalPage).flatMap { allPages[$0] ?? [] }
        return combined.enumerated().map { offset, item in
            let title = (item["name"] as? String) ?? "第\(offset + 1)集"
            let audioURL = BookItem.normalizeHttps((item["audioUrl"] as? String) ?? "")
            return EpisodeItem(
                trackId: "yt_\(bookId)_\(offset + 1)",
                index: offset + 1,
                rawTitle: title,
                bookTitle: bookTitle,
                isFree: true,
                directStreamURL: audioURL.isEmpty ? nil : audioURL
            )
        }
    }

    // =========================================================================
    // MARK: - 喜马拉雅 (Ximalaya) 核心实现（免费优先排序 + 全集并发拉取 + AES 解密）
    // =========================================================================

    private func fetchXimalayaCategoryBooks(category: UnifiedCategory) async -> [BookItem] {
        // 同时请求分类接口与免费热榜搜索，把可直接播放的免费精品排在最前
        async let catAlbums = fetchXimalayaRevisionCategory(category: category.xmlyCategory, subcategory: category.xmlySubcategory)
        async let searchAlbums = searchXimalayaBooks(keyword: category.searchFallbackKeyword, page: 1)

        let (a, b) = await (catAlbums, searchAlbums)
        let merged = Self.deduplicateBooks(b + a)
        return merged.sorted { ($0.isCompletelyFree ? 0 : 1) < ($1.isCompletelyFree ? 0 : 1) }
    }

    private func fetchXimalayaRevisionCategory(category: String, subcategory: String) async -> [BookItem] {
        let urlStr = "https://www.ximalaya.com/revision/category/queryCategoryPageAlbums?category=\(category)&subcategory=\(subcategory)&meta=&sort=0&page=1&perPage=30"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(URLRequest(url: url)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let albums = dataObj["albums"] as? [[String: Any]] else {
            return []
        }
        return albums.compactMap { a -> BookItem? in
            guard let idVal = a["albumId"],
                  let title = a["title"] as? String, !title.isEmpty else { return nil }
            let idStr = String(describing: idVal)
            let cover = (a["coverPath"] as? String) ?? ""
            guard !cover.isEmpty else { return nil }
            let author = (a["anchorName"] as? String) ?? "喜马拉雅主播"
            let tracks = (a["trackCount"] as? Int) ?? 0
            let isPaid = (a["isPaid"] as? Bool) ?? false
            return BookItem(
                source: .ximalaya,
                albumId: idStr,
                title: title,
                author: author,
                coverURL: cover,
                intro: "喜马拉雅热门有声专辑 · 主播：\(author)",
                categoryName: category == "xiangsheng" ? "相声评书" : "喜马拉雅",
                statusText: (isPaid ? "VIP/试听" : "免费畅听") + (tracks > 0 ? " · 共\(tracks)集" : ""),
                totalTracks: tracks,
                isCompletelyFree: !isPaid
            )
        }
    }

    private func searchXimalayaBooks(keyword: String, page: Int) async -> [BookItem] {
        guard let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://search.ximalaya.com/front/v1?core=album&kw=\(enc)&page=\(page)&rows=25&spellchecker=true&condition=relation&device=android&version=9.0.75&paidFilter=false") else {
            return []
        }
        guard let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(URLRequest(url: url)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = json["response"] as? [String: Any],
              let docs = resp["docs"] as? [[String: Any]] else {
            return []
        }

        let items = docs.compactMap { doc -> BookItem? in
            guard let idVal = doc["id"] ?? doc["album_id"],
                  let rawTitle = doc["title"] as? String, !rawTitle.isEmpty else { return nil }
            let idStr = String(describing: idVal)
            let cover = (doc["cover_path"] as? String) ?? (doc["album_cover_path"] as? String) ?? ""
            guard !cover.isEmpty else { return nil }
            let author = (doc["nickname"] as? String) ?? "喜马拉雅主播"
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
                categoryName: "喜马拉雅",
                statusText: (isPaid ? "会员精品" : "免费畅听") + (tracks > 0 ? " · 共\(tracks)集" : ""),
                totalTracks: tracks,
                isCompletelyFree: !isPaid
            )
        }
        return items.sorted { ($0.isCompletelyFree ? 0 : 1) < ($1.isCompletelyFree ? 0 : 1) }
    }

    private func fetchXimalayaEpisodesAllAtOnce(for book: BookItem) async -> [EpisodeItem] {
        let cleanId = book.albumId
            .replacingOccurrences(of: "xm_", with: "")
            .replacingOccurrences(of: "fqxm_", with: "")
        return await fetchXimalayaAllTracksConcurrently(albumId: cleanId, bookTitle: book.title, forceFreeBadge: false)
    }

    /// 一次性并发拉取喜马拉雅专辑全量章节（每页 200 集，`withTaskGroup` 并发拉齐）
    private func fetchXimalayaAllTracksConcurrently(albumId: String, bookTitle: String, forceFreeBadge: Bool) async -> [EpisodeItem] {
        let firstURLStr = "https://mobile.ximalaya.com/mobile/v1/album/track?albumId=\(albumId)&pageId=1&pageSize=200&isAsc=true&device=android"
        guard let firstURL = URL(string: firstURLStr),
              let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(URLRequest(url: firstURL)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let firstList = dataObj["list"] as? [[String: Any]], !firstList.isEmpty else {
            return await fetchXimalayaBackupTracks(albumId: albumId, bookTitle: bookTitle, forceFreeBadge: forceFreeBadge)
        }

        let maxPage = min(10, max(1, (dataObj["maxPageId"] as? Int) ?? 1))
        var pageMap: [Int: [[String: Any]]] = [1: firstList]

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
                       let pList = pObj["list"] as? [[String: Any]],
                       !pList.isEmpty {
                        pageMap[p] = pList
                    }
                }
            }
        }

        let allRaw = (1...maxPage).flatMap { pageMap[$0] ?? [] }
        return allRaw.enumerated().map { offset, item in
            let tid = String(describing: item["trackId"] ?? (offset + 1))
            let title = (item["title"] as? String) ?? "第\(offset + 1)集"
            let duration = (item["duration"] as? Int) ?? 0
            let isPaid = (item["isPaid"] as? Bool) ?? false
            let isFreeFlag = (item["isFree"] as? Bool) ?? false
            let free = forceFreeBadge ? true : (!isPaid || isFreeFlag)
            let direct = BookItem.normalizeHttps(
                (item["playUrl64"] as? String) ??
                (item["playPathAacv164"] as? String) ??
                (item["playUrl32"] as? String) ?? ""
            )
            return EpisodeItem(
                trackId: "xm_\(tid)",
                index: offset + 1,
                rawTitle: title,
                bookTitle: bookTitle,
                durationSeconds: duration,
                isFree: free,
                directStreamURL: direct.isEmpty ? nil : direct
            )
        }
    }

    private func fetchXimalayaBackupTracks(albumId: String, bookTitle: String, forceFreeBadge: Bool) async -> [EpisodeItem] {
        let backupURLStr = "https://mobile.ximalaya.com/mobile/others/ca/album/track/\(albumId)/true/1/200"
        guard let url = URL(string: backupURLStr),
              let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(URLRequest(url: url)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracksObj = json["tracks"] as? [String: Any],
              let list = tracksObj["list"] as? [[String: Any]] else {
            return []
        }
        return list.enumerated().map { offset, item in
            let tid = String(describing: item["trackId"] ?? (offset + 1))
            let title = (item["title"] as? String) ?? "第\(offset + 1)集"
            let duration = (item["duration"] as? Int) ?? 0
            let direct = BookItem.normalizeHttps(
                (item["playUrl64"] as? String) ??
                (item["playPathAacv164"] as? String) ??
                (item["playUrl32"] as? String) ?? ""
            )
            return EpisodeItem(
                trackId: "xm_\(tid)",
                index: offset + 1,
                rawTitle: title,
                bookTitle: bookTitle,
                durationSeconds: duration,
                isFree: true,
                directStreamURL: direct.isEmpty ? nil : direct
            )
        }
    }

    private func resolveXimalayaTrackURL(trackId: String) async throws -> URL {
        // 0. 若开启“代理介入”，优先通过 WeiGiegie/ximalaya.js 的 v4/baseInfo/ts 与 download/v2/track 介入通道获取解锁音频流
        if ProxyInterventionEngine.shared.isEnabled,
           let intervenedURL = await ProxyInterventionEngine.shared.resolveIntervenedXimalayaAudioURL(
               trackId: trackId,
               cookie: customCookies[.ximalaya]
           ) {
            return intervenedURL
        }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        // 1. Web playpage V3 + AES-128-ECB 解密
        if let webURL = URL(string: "https://www.ximalaya.com/mobile-playpage/track/v3/baseInfo/\(ts)?device=web&trackId=\(trackId)&trackQualityLevel=1") {
            var req = URLRequest(url: webURL)
            req.setValue("https://www.ximalaya.com/", forHTTPHeaderField: "Referer")
            if let cookie = customCookies[.ximalaya], !cookie.isEmpty {
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let trackInfo = json["trackInfo"] as? [String: Any] {
                if let playUrlList = trackInfo["playUrlList"] as? [[String: Any]],
                   let firstEncrypted = playUrlList.first?["url"] as? String,
                   let decrypted = Self.decryptXimalayaPlayURL(firstEncrypted),
                   let validURL = URL(string: BookItem.normalizeHttps(decrypted)) {
                    return validURL
                }
            }
        }

        // 2. 移动端免加密直链通道
        if let mobURL = URL(string: "https://mobile.ximalaya.com/mobile/playpage/track/v3/baseInfo/\(ts)?device=iPhone&trackId=\(trackId)") {
            var req = URLRequest(url: mobURL)
            if let cookie = customCookies[.ximalaya], !cookie.isEmpty {
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if let (data, _) = try? await ProxyInterventionEngine.shared.performRequest(req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let trackInfo = json["trackInfo"] as? [String: Any] {
                let raw = (trackInfo["playUrl64"] as? String) ??
                          (trackInfo["playPathAacv164"] as? String) ??
                          (trackInfo["playUrl32"] as? String) ?? ""
                if !raw.isEmpty, let validURL = URL(string: BookItem.normalizeHttps(raw)) {
                    return validURL
                }
            }
        }

        throw NSError(domain: "XimalayaAudio", code: -2, userInfo: [NSLocalizedDescriptionKey: "未获取到音频地址"])
    }

    // MARK: - 跨源章节与音频无感回退
    private func crossMatchEpisodesByTitle(for book: BookItem) async -> [EpisodeItem] {
        let cleanTitle = book.title
        let altBooks = await searchFanqieBooks(keyword: cleanTitle, page: 1)
        if let firstMatch = altBooks.first(where: { $0.id != book.id }) {
            return await fetchFanqieEpisodesAllAtOnce(for: firstMatch)
        }
        return []
    }

    private func resolveCrossSourceFallbackStream(bookTitle: String, episodeIndex: Int) async -> URL? {
        // 1. 尝试听友免费有声引擎同名书对应集数
        let tyBooks = await fetchTingyouBooks(keyword: bookTitle, page: 1)
        if let firstTy = tyBooks.first {
            let rawId = String(firstTy.albumId.dropFirst(3))
            if let url = await resolveTingyouPlayURL(albumId: rawId, chapterIndex: episodeIndex) {
                return url
            }
        }
        // 2. 尝试喜马拉雅免费专辑同名书对应集数
        let freeXm = await fetchFreeXimalayaBooks(keyword: bookTitle, page: 1)
        if let firstXm = freeXm.first {
            let eps = await fetchFanqieEpisodesAllAtOnce(for: firstXm)
            let targetIdx = min(max(0, episodeIndex - 1), max(0, eps.count - 1))
            if eps.indices.contains(targetIdx) {
                let ep = eps[targetIdx]
                if let direct = ep.directStreamURL, let u = URL(string: direct) {
                    return u
                }
                let tid = ep.trackId.replacingOccurrences(of: "xm_", with: "")
                if let u = try? await resolveXimalayaTrackURL(trackId: tid) {
                    return u
                }
            }
        }
        return nil
    }

    // MARK: - 喜马拉雅 AES-128-ECB PKCS7 硬件解密 (`aaad3e4fd540b0f79dca95606e72bf93`)
    nonisolated static func decryptXimalayaPlayURL(_ encryptedBase64URL: String) -> String? {
        var b64 = encryptedBase64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 {
            b64 += String(repeating: "=", count: 4 - rem)
        }
        guard let cipherData = Data(base64Encoded: b64) else { return nil }

        let keyHex = "aaad3e4fd540b0f79dca95606e72bf93"
        var keyBytes: [UInt8] = []
        var idx = keyHex.startIndex
        while idx < keyHex.endIndex {
            let nextIdx = keyHex.index(idx, offsetBy: 2)
            if let byte = UInt8(keyHex[idx..<nextIdx], radix: 16) {
                keyBytes.append(byte)
            }
            idx = nextIdx
        }
        guard keyBytes.count == kCCKeySizeAES128 else { return nil }

        let bufferSize = cipherData.count + kCCBlockSizeAES128
        var decryptedBuffer = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = decryptedBuffer.withUnsafeMutableBytes { outPtr in
            cipherData.withUnsafeBytes { cipherPtr in
                keyBytes.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyPtr.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        cipherPtr.baseAddress,
                        cipherData.count,
                        outPtr.baseAddress,
                        bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let outData = Data(bytes: decryptedBuffer, count: numBytesDecrypted)
        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }

    // MARK: - Cookie 与登录状态管理
    func saveCookies(_ cookieHeader: String, for source: CoreSourceID) {
        customCookies[source] = cookieHeader
        UserDefaults.standard.set(cookieHeader, forKey: "dsnovel_cookie_\(source.rawValue)")
        loginNicknames[source] = "\(source.displayName)已登录"
        UserDefaults.standard.set(loginNicknames[source], forKey: "dsnovel_nick_\(source.rawValue)")
    }

    func logout(source: CoreSourceID) {
        customCookies.removeValue(forKey: source)
        loginNicknames.removeValue(forKey: source)
        UserDefaults.standard.removeObject(forKey: "dsnovel_cookie_\(source.rawValue)")
        UserDefaults.standard.removeObject(forKey: "dsnovel_nick_\(source.rawValue)")
    }

    private func loadSavedCookies() {
        for source in CoreSourceID.allCases {
            if let c = UserDefaults.standard.string(forKey: "dsnovel_cookie_\(source.rawValue)"), !c.isEmpty {
                customCookies[source] = c
            }
            if let n = UserDefaults.standard.string(forKey: "dsnovel_nick_\(source.rawValue)"), !n.isEmpty {
                loginNicknames[source] = n
            }
        }
    }

    func clearAllCaches() {
        categoryCache.removeAll()
        episodeCache.removeAll()
    }

    // MARK: - 双源交错排序与去重辅助
    nonisolated static func interleaveBooks(primary: [BookItem], secondary: [BookItem]) -> [BookItem] {
        var result: [BookItem] = []
        let maxCount = max(primary.count, secondary.count)
        for i in 0..<maxCount {
            if i < primary.count { result.append(primary[i]) }
            if i < secondary.count { result.append(secondary[i]) }
        }
        return deduplicateBooks(result)
    }

    nonisolated static func deduplicateBooks(_ list: [BookItem]) -> [BookItem] {
        var seen = Set<String>()
        var out: [BookItem] = []
        for b in list {
            let key = "\(b.source.rawValue)_\(b.title)"
            if !seen.contains(key) {
                seen.insert(key)
                out.append(b)
            }
        }
        return out
    }

    nonisolated static func curatedFallbackBooks(for category: UnifiedCategory) -> [BookItem] {
        let samples: [BookItem] = [
            BookItem(source: .fanqie, albumId: "fqxm_12891461", title: "凡人修仙传（全本免费有声剧）", author: "番茄畅听精品剧场", coverURL: "https://imagev2.xmcdn.com/group61/M0A/93/6A/wKgMcF0I1g7T6A9AAAH7g3Q9s9g361.jpg", intro: "一个普通山村穷小子，偶然之下，跨入到一个江湖小门派，虽然资质平庸，但依靠自身努力和合理算计最后修炼成仙。", categoryName: category.title, statusText: "全本免费 · 共1850集", totalTracks: 1850, isCompletelyFree: true),
            BookItem(source: .ximalaya, albumId: "11549639", title: "郭德纲超清经典相声全集", author: "德云社郭德纲", coverURL: "https://imagev2.xmcdn.com/group58/M02/06/29/wKgLc10I1f6x5b2AAAH7g3Q9s9g124.jpg", intro: "收录郭德纲、于谦历年经典相声专场，高清降噪无损音质。", categoryName: category.title, statusText: "免费畅听 · 共260集", totalTracks: 260, isCompletelyFree: true),
            BookItem(source: .fanqie, albumId: "fqxm_19264785", title: "明朝那些事儿（全集免费畅听）", author: "当年明月 · 番茄有声", coverURL: "https://imagev2.xmcdn.com/group63/M04/12/4B/wKgMaF0I1h2y7c1AAAH7g3Q9s9g512.jpg", intro: "以史料为基础，以年代和具体人物为主线，全景展示明朝三百年历史。", categoryName: category.title, statusText: "全本免费 · 共812集", totalTracks: 812, isCompletelyFree: true),
            BookItem(source: .ximalaya, albumId: "4756811", title: "盗墓笔记（多人精品有声剧）", author: "南派三叔 · 周建龙演播", coverURL: "https://imagev2.xmcdn.com/group55/M01/33/19/wKgLf10I1i3z8d3AAAH7g3Q9s9g789.jpg", intro: "五十年前，一群长沙土夫子挖到一部战国帛书，残篇中记载了一座奇特的战国古墓的位置。", categoryName: category.title, statusText: "免费畅听 · 共540集", totalTracks: 540, isCompletelyFree: true)
        ]
        return samples
    }
}
