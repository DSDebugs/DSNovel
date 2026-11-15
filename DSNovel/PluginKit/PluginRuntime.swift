import Foundation
import JavaScriptCore

enum PluginError: LocalizedError, Equatable, Sendable {
    case needLogin(sourceID: String, loginURL: String)
    case needVerify(sourceID: String, verifyURL: String)
    case rateLimited
    case parseFailed(String)
    case timeout
    case network(String)

    var errorDescription: String? {
        switch self {
        case .needLogin: return "该听书源需要登录账号后才能访问"
        case .needVerify: return "该听书源触发了安全验证，请完成验证后重试"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .parseFailed(let detail): return "解析内容失败：\(detail)"
        case .timeout: return "插件响应超时（超过 15 秒）"
        case .network(let msg): return "网络请求异常：\(msg)"
        }
    }
}

struct PluginPackageManifest: Codable, Sendable {
    var name: String
    var version: String
    var author: String?
    var description: String?
    var scripts: [String]
}

struct ParsedSourceMeta: Hashable, Sendable {
    var index: Int
    var id: String
    var name: String
    var url: String
    var summary: String
    var group: String
    var searchable: Bool
    var discoverable: Bool
    var enabledByDefault: Bool
    var loginURL: String
    var methods: Set<String>
    var config: [SourceConfigItem]
}

struct PluginImportPreview: Identifiable, Sendable {
    var id: String { packageID }
    var packageID: String
    var name: String
    var version: String
    var author: String
    var description: String
    var sources: [ParsedSourceMeta]
    var domains: [String]
    var extractedFiles: [String: Data]
}

protocol BookSource: Sendable {
    var sourceID: String { get }
    var sourceName: String { get }
    func search(keyword: String, page: Int) async throws -> DiscoverPageDTO
    func discoverSections() async throws -> [DiscoverSectionDTO]
    func discoverList(tabURL: String) async throws -> DiscoverPageDTO
    func bookDetail(bookURL: String) async throws -> BookDetailDTO
    func resolvePlayURL(episodeURL: String) async throws -> PlayStreamInfo
}

/// 插件运行时 Actor：管理每个插件包独立的 JSContext、15 秒调用超时重建、5 分钟空闲回收与统一源协议适配
actor PluginRuntime {
    static let shared = PluginRuntime()

    private final class ContextHolder {
        let packageID: String
        let context: JSContext
        let sources: [ParsedSourceMeta]
        var lastUsedAt: Date

        init(packageID: String, context: JSContext, sources: [ParsedSourceMeta]) {
            self.packageID = packageID
            self.context = context
            self.sources = sources
            self.lastUsedAt = .now
        }
    }

    private var activeContexts: [String: ContextHolder] = [:]
    private var sourceRouting: [String: (packageID: String, sourceIndex: Int, meta: ParsedSourceMeta)] = [:]
    private let idleLimitSeconds: TimeInterval = 300 // 空闲 5 分钟回收

    var pluginsRootDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 插件包解析与导入预览（4.2.1 & 4.2.7）

    func prepareImportPreview(from zipData: Data) throws -> PluginImportPreview {
        let files = try ZIPArchiveReader.extractAll(from: zipData)
        guard let manifestData = files["manifest.json"],
              let manifest = try? JSONDecoder().decode(PluginPackageManifest.self, from: manifestData) else {
            throw PluginError.parseFailed("ZIP 包缺少合法的 manifest.json")
        }
        let packageID = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, metas) = try buildContext(packageID: packageID, manifest: manifest, scriptFiles: files)

        let domains = Array(
            Set(
                metas.compactMap { URL(string: $0.url)?.host }.filter { !$0.isEmpty }
            )
        ).sorted()

        return PluginImportPreview(
            packageID: packageID,
            name: manifest.name,
            version: manifest.version,
            author: manifest.author ?? "",
            description: manifest.description ?? "",
            sources: metas,
            domains: domains,
            extractedFiles: files
        )
    }

    func installPackage(_ preview: PluginImportPreview) throws -> [ParsedSourceMeta] {
        let pkgDir = pluginsRootDirectory.appendingPathComponent(preview.packageID, isDirectory: true)
        try? FileManager.default.removeItem(at: pkgDir)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        for (fileName, data) in preview.extractedFiles {
            let fileURL = pkgDir.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)
        }

        activeContexts.removeValue(forKey: preview.packageID)
        for meta in preview.sources {
            sourceRouting[meta.id] = (preview.packageID, meta.index, meta)
        }
        return preview.sources
    }

    func removeSourceFilesAndCache(sourceID: String, packageID: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = caches.appendingPathComponent("PluginCache/\(sourceID)", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        sourceRouting.removeValue(forKey: sourceID)
        activeContexts.removeValue(forKey: packageID)
    }

    func reloadInstalledPackages() {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: pluginsRootDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for dir in dirs where dir.hasDirectoryPath {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PluginPackageManifest.self, from: manifestData) else {
                continue
            }
            var files: [String: Data] = ["manifest.json": manifestData]
            for script in manifest.scripts {
                let sURL = dir.appendingPathComponent(script)
                if let d = try? Data(contentsOf: sURL) {
                    files[script] = d
                }
            }
            let pkgID = dir.lastPathComponent
            if let (ctx, metas) = try? buildContext(packageID: pkgID, manifest: manifest, scriptFiles: files) {
                activeContexts[pkgID] = ContextHolder(packageID: pkgID, context: ctx, sources: metas)
                for m in metas {
                    sourceRouting[m.id] = (pkgID, m.index, m)
                }
            }
        }
    }

    // MARK: - 统一源协议调用（15 秒超时保护 + 超时重建 Context）

    func search(sourceID: String, keyword: String, page: Int) async throws -> DiscoverPageDTO {
        let jsonStr = try await invokeMethod(sourceID: sourceID, method: "search", args: [keyword, page])
        return try decodeDiscoverPage(from: jsonStr, sourceID: sourceID)
    }

    func discoverSections(sourceID: String) async throws -> [DiscoverSectionDTO] {
        guard let route = try ensureRoute(for: sourceID) else {
            return []
        }
        if !route.meta.methods.contains("categoryMenus") {
            return []
        }
        let jsonStr = try await invokeMethod(sourceID: sourceID, method: "categoryMenus", args: [])
        guard let data = jsonStr.data(using: .utf8),
              let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rawArray.compactMap { dict in
            let title = (dict["title"] as? String) ?? "分类"
            let rawTabs = (dict["tabs"] as? [[String: Any]]) ?? []
            let tabs = rawTabs.compactMap { t -> DiscoverTabDTO? in
                guard let tTitle = t["title"] as? String, let tURL = t["url"] as? String else { return nil }
                return DiscoverTabDTO(title: tTitle, url: tURL)
            }
            return tabs.isEmpty ? nil : DiscoverSectionDTO(title: title, tabs: tabs)
        }
    }

    func discoverList(sourceID: String, tabURL: String) async throws -> DiscoverPageDTO {
        let jsonStr = try await invokeMethod(sourceID: sourceID, method: "categoryPage", args: [tabURL])
        return try decodeDiscoverPage(from: jsonStr, sourceID: sourceID)
    }

    func bookDetail(sourceID: String, bookURL: String) async throws -> BookDetailDTO {
        let jsonStr = try await invokeMethod(sourceID: sourceID, method: "bookDetail", args: [bookURL])
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.parseFailed("书籍详情数据格式无效")
        }
        let title = (dict["title"] as? String) ?? ""
        let author = (dict["author"] as? String) ?? ""
        let coverURL = (dict["coverUrl"] as? String) ?? (dict["cover"] as? String) ?? ""
        let intro = (dict["intro"] as? String) ?? (dict["description"] as? String) ?? ""
        let status = (dict["status"] as? String) ?? ""
        let rawEpisodes = (dict["episodes"] as? [[String: Any]]) ?? []

        let chapters: [ChapterDTO] = rawEpisodes.enumerated().compactMap { idx, ep in
            let epTitle = (ep["title"] as? String) ?? "第 \(idx + 1) 章"
            let epURL = (ep["url"] as? String) ?? ""
            guard !epURL.isEmpty else { return nil }
            let duration = ep["duration"] as? Int
            return ChapterDTO(index: idx, title: epTitle, url: epURL, durationSec: duration)
        }
        return BookDetailDTO(
            title: title,
            author: author,
            coverURL: coverURL,
            intro: intro,
            status: status,
            chapters: chapters
        )
    }

    func resolvePlayURL(sourceID: String, episodeURL: String) async throws -> PlayStreamInfo {
        let jsonStr = try await invokeMethod(sourceID: sourceID, method: "audio", args: [episodeURL])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw PluginError.parseFailed("未能解析音频播放地址")
        }
        var urlString = ""
        var headers: [String: String] = [:]

        if let str = obj as? String {
            urlString = str
        } else if let dict = obj as? [String: Any] {
            urlString = (dict["url"] as? String) ?? ""
            if let h = dict["headers"] as? [String: String] {
                headers = h
            }
        }
        guard !urlString.isEmpty else {
            throw PluginError.parseFailed("插件返回的音频地址为空")
        }
        let lower = urlString.lowercased()
        let kind: StreamKind = lower.contains(".m3u8") ? .hls : .onDemand
        return PlayStreamInfo(url: urlString, headers: headers, kind: kind)
    }

    // MARK: - 内部 JSContext 构建与调用管理

    private func invokeMethod(sourceID: String, method: String, args: [Any], timeoutSec: Double = 15.0) async throws -> String {
        reclaimIdleContexts()
        guard let route = try ensureRoute(for: sourceID) else {
            throw PluginError.parseFailed("未找到听书源: \(sourceID)")
        }
        let holder = try ensureContextHolder(for: route.packageID)
        holder.lastUsedAt = .now

        let argsData = try JSONSerialization.data(withJSONObject: args)
        let argsJson = String(data: argsData, encoding: .utf8) ?? "[]"
        let ctx = holder.context
        let sourceIdx = route.sourceIndex
        let loginURL = route.meta.loginURL
        let siteURL = route.meta.url

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Task.detached(priority: .userInitiated) {
                    guard let invokeFn = ctx.objectForKeyedSubscript("__invoke"),
                          let res = invokeFn.call(withArguments: [sourceIdx, method, argsJson]) else {
                        throw PluginError.parseFailed("调用插件方法 \(method) 失败")
                    }
                    if let exc = ctx.exception {
                        let excMsg = exc.toString() ?? "JS Exception"
                        ctx.exception = nil
                        if excMsg.contains("401") || excMsg.contains("登录") {
                            throw PluginError.needLogin(sourceID: sourceID, loginURL: loginURL.isEmpty ? siteURL : loginURL)
                        }
                        if excMsg.contains("403") || excMsg.contains("验证") || excMsg.contains("captcha") {
                            throw PluginError.needVerify(sourceID: sourceID, verifyURL: siteURL)
                        }
                        if excMsg.contains("429") {
                            throw PluginError.rateLimited
                        }
                        throw PluginError.network(excMsg)
                    }
                    guard !res.isNull && !res.isUndefined, let str = res.toString() else {
                        throw PluginError.parseFailed("插件返回空数据")
                    }
                    return str
                }.value
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSec))
                throw PluginError.timeout
            }

            do {
                let first = try await group.next()!
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                if let pErr = error as? PluginError, pErr == .timeout {
                    // JSC 超时无法强杀，销毁并将在下次调用时重建 Context
                    self.activeContexts.removeValue(forKey: route.packageID)
                }
                throw error
            }
        }
    }

    private func decodeDiscoverPage(from jsonStr: String, sourceID: String) throws -> DiscoverPageDTO {
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.parseFailed("列表数据格式错误")
        }
        let rawBooks = (dict["books"] as? [[String: Any]]) ?? []
        let books: [BookRef] = rawBooks.compactMap { b in
            let title = (b["title"] as? String) ?? ""
            let bookURL = (b["bookUrl"] as? String) ?? (b["url"] as? String) ?? ""
            guard !title.isEmpty && !bookURL.isEmpty else { return nil }
            let author = (b["author"] as? String) ?? ""
            let cover = (b["coverUrl"] as? String) ?? (b["cover"] as? String) ?? ""
            let intro = (b["intro"] as? String) ?? (b["description"] as? String) ?? ""
            let chapterCount = (b["chapterCount"] as? Int) ?? 0
            return BookRef(
                sourceID: sourceID,
                bookURL: bookURL,
                title: title,
                author: author,
                cover: cover,
                intro: intro,
                chapterCount: chapterCount
            )
        }
        let nextPageURL = dict["nextPageUrl"] as? String
        let totalPage = dict["totalPage"] as? Int
        return DiscoverPageDTO(books: books, nextPageURL: nextPageURL, totalPage: totalPage)
    }

    private func ensureRoute(for sourceID: String) throws -> (packageID: String, sourceIndex: Int, meta: ParsedSourceMeta)? {
        if let route = sourceRouting[sourceID] {
            return route
        }
        reloadInstalledPackages()
        return sourceRouting[sourceID]
    }

    private func ensureContextHolder(for packageID: String) throws -> ContextHolder {
        if let existing = activeContexts[packageID] {
            return existing
        }
        let pkgDir = pluginsRootDirectory.appendingPathComponent(packageID, isDirectory: true)
        let manifestURL = pkgDir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: manifestData)

        var files: [String: Data] = ["manifest.json": manifestData]
        for script in manifest.scripts {
            let sURL = pkgDir.appendingPathComponent(script)
            if let d = try? Data(contentsOf: sURL) {
                files[script] = d
            }
        }
        let (ctx, metas) = try buildContext(packageID: packageID, manifest: manifest, scriptFiles: files)
        let holder = ContextHolder(packageID: packageID, context: ctx, sources: metas)
        activeContexts[packageID] = holder
        return holder
    }

    private func buildContext(
        packageID: String,
        manifest: PluginPackageManifest,
        scriptFiles: [String: Data]
    ) throws -> (JSContext, [ParsedSourceMeta]) {
        guard let ctx = JSContext() else {
            throw PluginError.parseFailed("无法初始化 JavaScriptCore 引擎")
        }
        let rootBridge = JsRootBridge(packageID: packageID)
        ctx.setObject(rootBridge, forKeyedSubscript: "__bridge" as NSString)

        let preludeCode = Self.loadPreludeScript()
        ctx.evaluateScript(preludeCode)

        for scriptName in manifest.scripts {
            let cleanName = (scriptName as NSString).lastPathComponent
            guard let scriptData = scriptFiles[scriptName] ?? scriptFiles[cleanName],
                  let scriptText = String(data: scriptData, encoding: .utf8) else {
                continue
            }
            ctx.evaluateScript(scriptText, withSourceURL: URL(string: "plugin://\(packageID)/\(cleanName)"))
            if let exc = ctx.exception {
                let msg = exc.toString() ?? "Unknown JS Error"
                ctx.exception = nil
                throw PluginError.parseFailed("脚本 \(cleanName) 执行错误: \(msg)")
            }
        }

        guard let metaFn = ctx.objectForKeyedSubscript("__meta"),
              let metaVal = metaFn.call(withArguments: []),
              let metaJson = metaVal.toString(),
              let metaData = metaJson.data(using: .utf8),
              let rawMetas = try? JSONSerialization.jsonObject(with: metaData) as? [[String: Any]] else {
            throw PluginError.parseFailed("无法读取插件注册的源元数据")
        }

        let parsed: [ParsedSourceMeta] = rawMetas.enumerated().compactMap { idx, dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            let url = (dict["url"] as? String) ?? ""
            let summary = (dict["summary"] as? String) ?? ""
            let group = (dict["group"] as? String) ?? ""
            let searchable = (dict["searchable"] as? Bool) ?? true
            let discoverable = (dict["discoverable"] as? Bool) ?? true
            let enabledByDefault = (dict["enabledByDefault"] as? Bool) ?? true
            let loginURL = (dict["loginUrl"] as? String) ?? ""
            let methods = Set((dict["methods"] as? [String]) ?? [])
            var configItems: [SourceConfigItem] = []
            if let rawConfig = dict["config"] as? [[String: Any]] {
                configItems = rawConfig.compactMap { c in
                    guard let k = c["key"] as? String, let t = c["title"] as? String else { return nil }
                    return SourceConfigItem(
                        key: k,
                        title: t,
                        defaultValue: (c["default"] as? String) ?? "",
                        summary: (c["summary"] as? String) ?? ""
                    )
                }
            }
            return ParsedSourceMeta(
                index: idx,
                id: id,
                name: name,
                url: url,
                summary: summary,
                group: group,
                searchable: searchable,
                discoverable: discoverable,
                enabledByDefault: enabledByDefault,
                loginURL: loginURL,
                methods: methods,
                config: configItems
            )
        }
        return (ctx, parsed)
    }

    private func reclaimIdleContexts() {
        let now = Date()
        for (pkgID, holder) in activeContexts {
            if now.timeIntervalSince(holder.lastUsedAt) > idleLimitSeconds {
                activeContexts.removeValue(forKey: pkgID)
            }
        }
    }

    static func loadPreludeScript() -> String {
        if let url = Bundle.main.url(forResource: "prelude", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // 单元测试回退内联引导脚本
        return """
        var __sources = [];
        function at(obj, path) {
          if (obj === null || obj === undefined) return null;
          var parts = String(path).split('.');
          for (var i = 0; i < parts.length; i++) {
            var k = parts[i];
            if (k === '') continue;
            if (obj === null || obj === undefined) return null;
            if (Array.isArray(obj)) {
              var n = parseInt(k, 10);
              if (isNaN(n)) return null;
              if (n < 0) n += obj.length;
              obj = obj[n];
            } else if (typeof obj === 'object') {
              obj = obj[k];
            } else { return null; }
          }
          return obj === undefined ? null : obj;
        }
        function str(obj, path) {
          var v = (path === undefined || path === null) ? obj : at(obj, path);
          if (v === null || v === undefined) return '';
          return typeof v === 'object' ? JSON.stringify(v) : String(v);
        }
        function int(obj, path, def) {
          var n = parseInt(str(obj, path), 10);
          return isNaN(n) ? (def === undefined ? 0 : def) : n;
        }
        function items(obj, path) {
          var v = (path === undefined || path === null) ? obj : at(obj, path);
          return Array.isArray(v) ? v.filter(function (x) { return x !== null && x !== undefined; }) : [];
        }
        function parseJson(text) { return JSON.parse(String(text).trim()); }
        function __makeHost(j) {
          function un(s) {
            var r = JSON.parse(s);
            if (r.e !== undefined) { throw new Error(r.e); }
            return r.v;
          }
          function opt(o) { return o ? JSON.stringify(o) : null; }
          var h = {
            sourceId: String(j.getSourceId()),
            getString: function (url, o) { return un(j.request(String(url), opt(o))); },
            getHtml: function (url, o) { return j.parseHtml(h.getString(url, o), String(url)); },
            getJson: function (url, o) { return parseJson(h.getString(url, o)); },
            parseHtml: function (html, baseUrl) { return j.parseHtml(String(html), baseUrl ? String(baseUrl) : null); },
            aesEcbDecrypt: function (data, key) { return j.aesEcbDecrypt(String(data), String(key)); },
            md5: function (v) { return j.md5(String(v)); },
            sha256: function (v) { return j.sha256(String(v)); }
          };
          return h;
        }
        function registerSource(source) {
          if (!source || !source.id || !source.name) throw new Error('registerSource：缺少 id 或 name');
          source.host = __makeHost(__bridge.host(String(source.id), String(source.name)));
          __sources.push(source);
          return source;
        }
        function __meta() {
          return JSON.stringify(__sources.map(function (src) {
            var meta = { methods: [] };
            for (var k in src) {
              if (k === 'host') continue;
              if (typeof src[k] === 'function') meta.methods.push(k);
              else meta[k] = src[k];
            }
            return meta;
          }));
        }
        function __invoke(index, name, argsJson) {
          var src = __sources[index];
          if (!src || typeof src[name] !== 'function') return null;
          var r = src[name].apply(src, JSON.parse(argsJson));
          return (r === undefined || r === null) ? null : JSON.stringify(r);
        }
        """
    }
}
