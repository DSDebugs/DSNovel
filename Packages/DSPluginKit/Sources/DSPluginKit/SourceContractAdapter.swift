import DSCore
import Foundation

/// 书源多版本契约适配层（P0-1 / P0-2 / P0-3：同时兼容 Shun v5.6 与 DSNovel v3 契约，并提供真超时一次性 Continuation）
public enum SourceContractAdapter {
    /// 方法名双向别名表（优先命中书源实际导出方法）
    public static func resolveMethodName(requested: String, available: [String]) -> String {
        let aliases: [String: [String]] = [
            "discoverCategories": ["discoverCategories", "categoryMenus"],
            "discover": ["discover", "categoryPage"],
            "detail": ["detail", "bookDetail"],
            "search": ["search"],
            "audio": ["audio"],
        ]
        guard let candidates = aliases[requested] else { return requested }
        for name in candidates where available.contains(name) {
            return name
        }
        return requested
    }

    /// 将内部音质档位映射为书源脚本普遍识别的音质参数
    public static func qualityArgument(for tier: AudioQualityTier) -> String {
        switch tier {
        case .high: return "M4A_128"
        case .standard: return "M4A_64"
        case .saver: return "M4A_24"
        case .auto: return "M4A_64"
        }
    }

    /// 识别 prelude.js 返回的方法缺失哨兵与安全序列化异常哨兵，转为显式可读错误
    public static func checkMissingMethodSentinel(_ raw: String) throws {
        guard raw.contains("__dsMissingMethod") || raw.contains("__dsError"),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let missing = dict["__dsMissingMethod"] as? String {
            throw PluginSecurityError.scriptError("书源未实现 \(missing) 方法")
        }
        if let err = dict["__dsError"] as? String {
            if (dict["__dsCancelled"] as? Bool) == true {
                throw CancellationError()
            }
            throw PluginSecurityError.scriptError(err)
        }
    }

    /// 归一化分类列表（兼容扁平数组、categoryMenus 分组菜单及嵌套 items）
    public static func decodeCategories(_ json: String, sourceID: String) -> [DiscoverCategoryDTO] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawList: [[String: Any]]
        if let arr = obj as? [[String: Any]] {
            rawList = arr
        } else if let dict = obj as? [String: Any] {
            rawList = (dict["categories"] as? [[String: Any]])
                ?? (dict["menus"] as? [[String: Any]])
                ?? (dict["list"] as? [[String: Any]])
                ?? []
        } else {
            rawList = []
        }
        var out: [DiscoverCategoryDTO] = []
        var seen: Set<String> = []
        for item in rawList {
            let groupPrefix = (item["title"] as? String) ?? (item["name"] as? String) ?? ""
            if let groups = (item["groups"] as? [[String: Any]]) ?? (item["channels"] as? [[String: Any]]) ?? (item["submenus"] as? [[String: Any]]), !groups.isEmpty {
                for sub in groups {
                    let subPrefix = (sub["title"] as? String) ?? (sub["name"] as? String) ?? ""
                    let subTabs = (sub["tabs"] as? [[String: Any]]) ?? (sub["items"] as? [[String: Any]]) ?? []
                    for child in subTabs {
                        guard let cTitle = (child["title"] as? String) ?? (child["name"] as? String) else { continue }
                        let url = (child["url"] as? String) ?? (child["id"] as? String) ?? cTitle
                        let display = [groupPrefix, subPrefix, cTitle].filter { !$0.isEmpty }.joined(separator: "·")
                        let cid = "\(sourceID)::\(url)"
                        if seen.insert(cid).inserted {
                            out.append(DiscoverCategoryDTO(id: cid, title: display, url: url, groupTitle: groupPrefix, subGroupTitle: subPrefix))
                        }
                    }
                }
            } else if let children = (item["tabs"] as? [[String: Any]]) ?? (item["items"] as? [[String: Any]]) ?? (item["subcategories"] as? [[String: Any]]), !children.isEmpty {
                for child in children {
                    guard let cTitle = (child["title"] as? String) ?? (child["name"] as? String) else { continue }
                    let url = (child["url"] as? String) ?? (child["id"] as? String) ?? cTitle
                    let display = groupPrefix.isEmpty ? cTitle : "\(groupPrefix)·\(cTitle)"
                    let cid = "\(sourceID)::\(url)"
                    if seen.insert(cid).inserted {
                        out.append(DiscoverCategoryDTO(id: cid, title: display, url: url, groupTitle: groupPrefix))
                    }
                }
            } else if let title = (item["title"] as? String) ?? (item["name"] as? String) {
                let url = (item["url"] as? String) ?? (item["id"] as? String) ?? title
                let cid = "\(sourceID)::\(url)"
                if seen.insert(cid).inserted {
                    out.append(DiscoverCategoryDTO(id: cid, title: title, url: url))
                }
            }
        }
        return out
    }

    /// 发现页分页结果（B12-02：保留真实 nextUrl 与 hasMore 供链式翻页）
    public struct DiscoverPageResult: Sendable, Equatable {
        public let books: [BookSummaryDTO]
        public let nextURL: String?
        public let hasMore: Bool

        public init(books: [BookSummaryDTO], nextURL: String?, hasMore: Bool) {
            self.books = books
            self.nextURL = nextURL
            self.hasMore = hasMore
        }
    }

    /// 归一化发现页分页结果（兼容 nextUrl / currentPage / totalPage 及 #page 尾标自增）
    public static func decodeDiscoverPage(
        _ json: String,
        sourceID: String,
        sourceName: String,
        requestedURL: String,
        requestedPage: Int
    ) -> DiscoverPageResult {
        let books = decodeBooks(json, sourceID: sourceID, sourceName: sourceName)
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DiscoverPageResult(books: books, nextURL: nil, hasMore: !books.isEmpty)
        }
        let explicitNext = (dict["nextUrl"] as? String) ?? (dict["nextPageUrl"] as? String)
        if let next = explicitNext, !next.isEmpty {
            return DiscoverPageResult(books: books, nextURL: next, hasMore: !books.isEmpty)
        }
        let current = (dict["currentPage"] as? Int) ?? requestedPage
        let total = dict["totalPage"] as? Int
        if let total {
            guard current < total, !books.isEmpty else {
                return DiscoverPageResult(books: books, nextURL: nil, hasMore: false)
            }
            let synthesized = incrementHashPage(in: requestedURL, nextPage: current + 1)
            return DiscoverPageResult(books: books, nextURL: synthesized, hasMore: true)
        }
        if dict.keys.contains("nextUrl") || dict.keys.contains("nextPageUrl") {
            return DiscoverPageResult(books: books, nextURL: nil, hasMore: false)
        }
        return DiscoverPageResult(books: books, nextURL: nil, hasMore: !books.isEmpty)
    }

    private static func incrementHashPage(in url: String, nextPage: Int) -> String? {
        guard let hashIdx = url.lastIndex(of: "#") else { return nil }
        let tail = url[url.index(after: hashIdx)...]
        guard !tail.isEmpty, Int(tail) != nil else { return nil }
        return String(url[..<hashIdx]) + "#\(nextPage)"
    }

    private static func nonEmpty(_ candidates: Any?...) -> String? {
        for item in candidates {
            if let str = item as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// 归一化书籍列表（兼容顶层数组与 { books: [...], totalPage } / { list: [...] } 包装结构）
    public static func decodeBooks(_ json: String, sourceID: String, sourceName: String) -> [BookSummaryDTO] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let arr: [[String: Any]]
        if let direct = obj as? [[String: Any]] {
            arr = direct
        } else if let dict = obj as? [String: Any] {
            arr = (dict["books"] as? [[String: Any]])
                ?? (dict["list"] as? [[String: Any]])
                ?? (dict["items"] as? [[String: Any]])
                ?? (dict["data"] as? [[String: Any]])
                ?? []
        } else {
            arr = []
        }
        return arr.compactMap { d in
            guard let title = nonEmpty(d["title"], d["name"]),
                  let url = nonEmpty(d["url"], d["bookUrl"]) else { return nil }
            let id = "\(sourceID)::\(DSCrypto.md5Hex(url))"
            let author = nonEmpty(d["author"], d["artist"]) ?? ""
            let narrator = nonEmpty(d["narrator"], d["announcer"], d["anchor"], d["artist"]) ?? ""
            let cover = nonEmpty(d["cover"], d["coverUrl"], d["img"]) ?? ""
            let intro = nonEmpty(d["intro"], d["description"]) ?? ""
            let latest = nonEmpty(d["latestChapter"], d["lastChapter"], d["status"]) ?? ""
            return BookSummaryDTO(
                id: id,
                sourceID: sourceID,
                sourceName: sourceName,
                bookURL: url,
                title: title,
                author: author,
                narrator: narrator,
                coverURL: cover,
                intro: intro,
                latestChapter: latest
            )
        }
    }

    /// 归一化书籍详情（兼容 chapters 与 episodes 字段；P0-13：过滤脏章节后重新分配连续 0..<chapters.count）
    public static func decodeBookDetail(_ json: String, fallback: BookSummaryDTO) -> BookDetailDTO {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BookDetailDTO(summary: fallback, chapters: [])
        }
        let rawChapters = (dict["chapters"] as? [[String: Any]])
            ?? (dict["episodes"] as? [[String: Any]])
            ?? (dict["tracks"] as? [[String: Any]])
            ?? []
        var chapters: [ChapterDTO] = []
        chapters.reserveCapacity(rawChapters.count)
        for c in rawChapters {
            guard let title = nonEmpty(c["title"], c["name"]),
                  let url = nonEmpty(c["url"], c["playUrl"]) else { continue }
            let contiguousIndex = chapters.count
            let cid = nonEmpty(c["id"]) ?? DSCrypto.md5Hex("\(contiguousIndex):\(url)")
            let dur = (c["durationMs"] as? Int) ?? ((c["duration"] as? Int).map { $0 * 1000 }) ?? 0
            let vip = (c["isVip"] as? Bool)
                ?? (c["isVIP"] as? Bool)
                ?? (c["vip"] as? Bool)
                ?? (c["isFree"] as? Bool).map { !$0 }
                ?? false
            chapters.append(ChapterDTO(id: cid, index: contiguousIndex, title: title, url: url, durationMs: dur, isVIP: vip))
        }
        let updatedSummary = BookSummaryDTO(
            id: fallback.id,
            sourceID: fallback.sourceID,
            sourceName: fallback.sourceName,
            bookURL: fallback.bookURL,
            title: nonEmpty(dict["title"], dict["name"]) ?? fallback.title,
            author: nonEmpty(dict["author"], dict["artist"]) ?? fallback.author,
            narrator: nonEmpty(dict["narrator"], dict["announcer"], dict["anchor"], dict["artist"]) ?? fallback.narrator,
            coverURL: nonEmpty(dict["cover"], dict["coverUrl"], dict["img"]) ?? fallback.coverURL,
            intro: nonEmpty(dict["intro"], dict["description"]) ?? fallback.intro,
            latestChapter: nonEmpty(chapters.last?.title, dict["status"]) ?? fallback.latestChapter,
            totalChapters: chapters.count
        )
        return BookDetailDTO(summary: updatedSummary, chapters: chapters)
    }

    /// 归一化音频流解析结果（AUD-03 强制 SSRF 校验 url/downloadUrl；AUD-49 逐项安全转字符串 headers）
    public static func decodeAudioStream(_ json: String, fallbackQuality: AudioQualityTier) throws -> AudioStreamDTO {
        let trimmed = json.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if let directURL = URL(string: trimmed), directURL.scheme?.hasPrefix("http") == true {
            try SSRFGuard.validatePublicURL(directURL)
            let isHLS = directURL.pathExtension.lowercased() == "m3u8"
            return AudioStreamDTO(url: directURL, qualityTier: fallbackQuality, isHLS: isHLS)
        }
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = nonEmpty(dict["url"], dict["playUrl"]),
              let url = URL(string: urlStr) else {
            throw PluginSecurityError.scriptError("音频地址解析失败")
        }
        try SSRFGuard.validatePublicURL(url)
        if let dlRaw = (dict["downloadUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !dlRaw.isEmpty {
            guard let dlURL = URL(string: dlRaw) else {
                throw PluginSecurityError.invalidURL(dlRaw)
            }
            try SSRFGuard.validatePublicURL(dlURL)
        }
        var headers: [String: String] = [:]
        if let rawHeaders = dict["headers"] as? [String: Any] {
            for (k, v) in rawHeaders where !(v is NSNull) {
                if let s = v as? String {
                    headers[k] = s
                } else if let n = v as? NSNumber {
                    headers[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
                } else {
                    headers[k] = "\(v)"
                }
            }
        }
        let bitrate = (dict["bitrate"] as? NSNumber)?.intValue
        let isTrial = (dict["isTrial"] as? Bool) ?? false
        let isCapped = (dict["capped"] as? Bool) ?? (bitrate == 24)
        let mime = dict["mimeType"] as? String
        let isHLS = (dict["isHLS"] as? Bool)
            ?? ((url.pathExtension.lowercased() == "m3u8")
                || (mime?.lowercased().contains("mpegurl") == true))
        return AudioStreamDTO(
            url: url,
            headers: headers,
            qualityTier: fallbackQuality,
            bitrateKbps: bitrate,
            isHLS: isHLS,
            isTrial: isTrial,
            isCappedFallback: isCapped,
            mimeType: mime
        )
    }
}

/// P0-3：先到先得的一次性超时竞态封装（不依赖 withThrowingTaskGroup 等待阻塞 JSContext，超时即刻返回）
public final class OneShotTimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    public init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    public func resume(returning value: T) {
        let cont = lock.withLock { () -> CheckedContinuation<T, Error>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(returning: value)
    }

    public func resume(throwing error: Error) {
        let cont = lock.withLock { () -> CheckedContinuation<T, Error>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(throwing: error)
    }
}

/// P1-19：线程安全共享取消令牌（用于取消/超时后立即唤醒并中止 HostHandleJS 同步阻塞操作）
public final class SandboxCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [(id: UUID, fn: @Sendable () -> Void)] = []

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        let toRun: [@Sendable () -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            let list = handlers.map(\.fn)
            handlers.removeAll()
            return list
        }
        for fn in toRun { fn() }
    }

    @discardableResult
    public func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            handlers.append((id: id, fn: handler))
            return false
        }
        if alreadyCancelled {
            handler()
        }
        return id
    }

    public func removeCancelHandler(_ id: UUID) {
        lock.withLock {
            handlers.removeAll { $0.id == id }
        }
    }
}
