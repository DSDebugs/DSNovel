import Foundation
import Observation

enum CompliantFeedKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case qxRewriteConf = "QX重写规则"
    case jsonCatalog = "JSON公开书单"

    var id: String { rawValue }
}

struct CompliantDataSourceRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var urlString: String
    var kind: CompliantFeedKind
    var lastUpdatedText: String

    init(
        id: String = UUID().uuidString,
        title: String,
        urlString: String,
        kind: CompliantFeedKind,
        lastUpdatedText: String = "未同步"
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.kind = kind
        self.lastUpdatedText = lastUpdatedText
    }
}

/// 合规数据更新模块（仅限 HTTPS 协议，不预置任何第三方盗版或绕过地址）
@Observable
@MainActor
final class CompliantDataUpdateModule {
    static let shared = CompliantDataUpdateModule()

    var sources: [CompliantDataSourceRecord] = [] {
        didSet { saveSources() }
    }
    var customCatalogBooks: [BookItem] = [] {
        didSet { saveCustomBooks() }
    }
    var isSyncing: Bool = false
    var statusMessage: String = "未添加外部数据源（可在下方添加 HTTPS 合规源）"

    private let sourcesKey = "dsnovel_compliant_sources_v13"
    private let booksKey = "dsnovel_compliant_books_v13"

    private init() {
        loadAll()
    }

    nonisolated static func isValidHTTPSURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    func addSource(title: String, urlString: String, kind: CompliantFeedKind) async -> Bool {
        guard let url = Self.isValidHTTPSURL(urlString) else {
            statusMessage = "仅支持合法有效的 HTTPS 协议地址"
            return false
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (url.host ?? "自定义数据源")
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        let record = CompliantDataSourceRecord(
            title: cleanTitle,
            urlString: url.absoluteString,
            kind: kind
        )
        sources.insert(record, at: 0)
        await syncSource(id: record.id)
        return true
    }

    func removeSource(id: String) {
        sources.removeAll { $0.id == id }
    }

    func syncSource(id: String) async {
        guard let idx = sources.firstIndex(where: { $0.id == id }),
              let url = Self.isValidHTTPSURL(sources[idx].urlString) else {
            statusMessage = "无效的 HTTPS 数据源地址"
            return
        }

        isSyncing = true
        statusMessage = "正在从 \(sources[idx].title) 同步数据..."

        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 12
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "CompliantDataUpdate", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "远程数据源返回异常状态"
                ])
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            let timeStr = "已同步 " + formatter.string(from: Date())

            switch sources[idx].kind {
            case .qxRewriteConf:
                let importedCount = await QXRewriteParserEngine.shared.importRules(from: text)
                sources[idx].lastUpdatedText = "\(timeStr) · \(importedCount)条规则"
                statusMessage = "成功解析并导入 \(importedCount) 条 Quantumult X 重写规则"
            case .jsonCatalog:
                let parsedBooks = Self.parseCompliantJSONCatalog(data: data)
                self.customCatalogBooks = DualSourceEngine.deduplicateBooks(parsedBooks + customCatalogBooks)
                sources[idx].lastUpdatedText = "\(timeStr) · \(parsedBooks.count)本书"
                statusMessage = "成功更新 \(parsedBooks.count) 部公开书单数据"
            }
        } catch {
            statusMessage = "同步失败：\(error.localizedDescription)"
        }

        isSyncing = false
    }

    /// 解析标准合规公开 JSON 书单（要求每本书具备 title 与 albumId）
    nonisolated static func parseCompliantJSONCatalog(data: Data) -> [BookItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (json["books"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) else {
            return []
        }
        return list.compactMap { item -> BookItem? in
            guard let title = item["title"] as? String, !title.isEmpty,
                  let albumId = (item["albumId"] as? String) ?? (item["id"] as? String) else {
                return nil
            }
            return BookItem(
                source: .ximalaya,
                albumId: albumId,
                title: title,
                author: (item["author"] as? String) ?? "",
                coverURL: (item["coverURL"] as? String) ?? "",
                intro: (item["intro"] as? String) ?? "",
                categoryName: (item["categoryName"] as? String) ?? "公开书单",
                isCompletelyFree: (item["isFree"] as? Bool) ?? true
            )
        }
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    private func saveCustomBooks() {
        if let data = try? JSONEncoder().encode(customCatalogBooks) {
            UserDefaults.standard.set(data, forKey: booksKey)
        }
    }

    private func loadAll() {
        if let data = UserDefaults.standard.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([CompliantDataSourceRecord].self, from: data) {
            self.sources = decoded
        }
        if let data = UserDefaults.standard.data(forKey: booksKey),
           let decoded = try? JSONDecoder().decode([BookItem].self, from: data) {
            self.customCatalogBooks = decoded
        }
    }
}
