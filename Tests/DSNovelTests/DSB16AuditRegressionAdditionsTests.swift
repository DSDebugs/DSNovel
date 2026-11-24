@testable import DSCore
@testable import DSNovel
@testable import DSPluginKit
@testable import DSStorage
import Foundation
import XCTest

/// 回归测试补齐套件（覆盖 BundledParserLoader、AppContainer 冷启动门控与偏好隔离、CookieVault 淘汰优先级、PersistenceEngine 非空保护）
final class DSB16AuditRegressionAdditionsTests: XCTestCase {

    // MARK: - 1. BundledParserLoader.activateBundledXimalayaParser 资源加载与激活逻辑

    func testBundledParserLoaderActivateFromParametrizedBundleSucceedsAndIsIdempotent() async throws {
        let prelude = try String(contentsOf: Self.resolveResourceURL(name: "prelude_parser", ext: "js", fallbackRelativePath: "App/Resources/prelude_parser.js"), encoding: .utf8)
        let bundledScriptURL = Self.resolveResourceURL(
            name: BundledParserLoader.bundledResourceName,
            ext: BundledParserLoader.bundledResourceExt,
            fallbackRelativePath: "App/Resources/BundledParsers/ximalaya_parser-v1.5.5.js"
        )

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-bundled-activate-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("ParserResources.bundle", isDirectory: true)
        let parserStorageDir = tempRoot.appendingPathComponent("Parsers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parserStorageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.copyItem(
            at: bundledScriptURL,
            to: bundleURL.appendingPathComponent("\(BundledParserLoader.bundledResourceName).\(BundledParserLoader.bundledResourceExt)")
        )
        let testBundle = try XCTUnwrap(Bundle(url: bundleURL))

        let vault = CookieVault(inMemorySecretsOnly: true)
        let engine = BuiltinParserEngine(
            preludeParserScript: prelude,
            storageDir: parserStorageDir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )

        let first = try await BundledParserLoader.activateBundledXimalayaParser(engine: engine, bundle: testBundle)
        XCTAssertEqual(first, .installed(name: "喜马拉雅解析", version: BundledParserLoader.bundledParserVersion))

        let second = try await BundledParserLoader.activateBundledXimalayaParser(engine: engine, bundle: testBundle)
        XCTAssertEqual(second, .alreadyLatest(name: "喜马拉雅解析", version: BundledParserLoader.bundledParserVersion))

        // 验证宿主 Bundle.main 在 App 宿主测试环境中也打包了内置解析脚本资源
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let mainResource = Bundle.main.url(
                forResource: BundledParserLoader.bundledResourceName,
                withExtension: BundledParserLoader.bundledResourceExt
            )
            XCTAssertNotNil(mainResource, "宿主 App Bundle.main 必须包含 ximalaya_parser-v1.5.5.js")
        }
    }

    func testBundledParserLoaderActivateThrowsWhenResourceMissingInBundle() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-bundled-missing-\(UUID().uuidString)", isDirectory: true)
        let emptyBundleURL = tempRoot.appendingPathComponent("Empty.bundle", isDirectory: true)
        let parserStorageDir = tempRoot.appendingPathComponent("Parsers", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parserStorageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let emptyBundle = try XCTUnwrap(Bundle(url: emptyBundleURL))
        let vault = CookieVault(inMemorySecretsOnly: true)
        let engine = BuiltinParserEngine(
            preludeParserScript: "",
            storageDir: parserStorageDir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )

        do {
            _ = try await BundledParserLoader.activateBundledXimalayaParser(engine: engine, bundle: emptyBundle)
            XCTFail("缺少内置解析脚本资源时应抛出 PluginSecurityError.scriptError")
        } catch let error as PluginSecurityError {
            if case .scriptError(let message) = error {
                XCTAssertTrue(message.contains("ximalaya_parser-v1.5.5.js"))
            } else {
                XCTFail("非预期错误类型：\(error)")
            }
        }
    }

    // MARK: - 2. P1-01 & P1-09: AppContainer(inMemoryOnly: true) 冷启动音质门控与 UserDefaults.standard 隔离

    @MainActor
    func testP1_01_P1_09_AppContainerColdStartQualityGatingAndInMemoryDefaultsIsolation() async throws {
        let std = UserDefaults.standard
        let qualityKey = "dsnovel.v3.preferredQuality"
        let rateKey = "dsnovel.v3.playbackRate"
        let unlockKey = "dsnovel.v3.builtinParserUnlocked"

        let prevQuality = std.object(forKey: qualityKey)
        let prevRate = std.object(forKey: rateKey)
        let prevUnlock = std.object(forKey: unlockKey)

        let container = try AppContainer(inMemoryOnly: true)
        defer {
            container.playback.tearDown()
            container.networkMonitor.stop()
        }

        // P1-01：冷启动尚未加载内置解析器列表前，不得覆写用户的 .high 音质偏好，同时引擎侧保持超清门控关闭
        container.settings.preferredQuality = .high
        container.syncSettingsToEngines()
        XCTAssertEqual(container.settings.preferredQuality, .high, "未加载内置解析器前不得覆写用户 .high 偏好")
        XCTAssertFalse(container.playback.allowUltraHighQuality)
        XCTAssertFalse(container.downloads.allowUltraHighQuality)

        // 加载完成后若无已启用的内置解析器，则将超清偏好钳制回高清(.standard)
        await container.refreshBuiltinParserActiveState()
        XCTAssertFalse(container.hasActiveBuiltinParser)
        XCTAssertFalse(container.canUseUltraHighQuality)
        XCTAssertEqual(container.settings.preferredQuality, .standard)
        XCTAssertEqual(container.playback.preferredQuality, .standard)

        // P1-09：inMemoryOnly 模式下修改各项偏好不得污染 UserDefaults.standard
        container.settings.playbackRate = 2.25
        container.settings.builtinParserUnlocked = true
        container.settings.preferredQuality = .saver

        XCTAssertEqual(std.string(forKey: qualityKey), prevQuality as? String)
        XCTAssertEqual(std.object(forKey: rateKey) as? Double, prevRate as? Double)
        XCTAssertEqual(std.object(forKey: unlockKey) as? Bool, prevUnlock as? Bool)
    }

    // MARK: - 3. P2-06: CookieVault 200 条淘汰优先清理过期项与 session 条目、保护长期登录态

    func testP2_06_CookieVaultEvictionPrioritizesExpiredAndSessionCookiesOverLongLivedLogin() async throws {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let now = Date()
        let longLivedExpiry = now.addingTimeInterval(30 * 86_400)
        let shortLivedExpiry = now.addingTimeInterval(3_600)
        let expiredDate = now.addingTimeInterval(-60)

        var batch: [HTTPCookie] = []
        // 1) 5 条长期登录态 Cookie（最先写入，但过期时间最晚，必须受到保护）
        for i in 0..<5 {
            let c = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "login.example.com",
                .path: "/",
                .name: "auth_token_\(i)",
                .value: "vip_\(i)",
                .expires: longLivedExpiry
            ]))
            batch.append(c)
        }
        // 2) 10 条短期持久化 Cookie
        for i in 0..<10 {
            let c = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "login.example.com",
                .path: "/",
                .name: "short_\(i)",
                .value: "sv_\(i)",
                .expires: shortLivedExpiry
            ]))
            batch.append(c)
        }
        // 3) 2 条已过期 Cookie
        for i in 0..<2 {
            let c = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "login.example.com",
                .path: "/",
                .name: "expired_\(i)",
                .value: "ev_\(i)",
                .expires: expiredDate
            ]))
            batch.append(c)
        }
        // 4) 200 条无过期时间的 session Cookie（总有效数 215 > 200，应优先淘汰最旧的 15 条 session）
        for i in 0..<200 {
            let c = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "login.example.com",
                .path: "/",
                .name: "sess_\(i)",
                .value: "v_\(i)"
            ]))
            batch.append(c)
        }

        await vault.setCookies(batch)
        let url = try XCTUnwrap(URL(string: "https://login.example.com/"))
        let remaining = await vault.matchingCookies(for: url)
        let names = Set(remaining.map(\.name))

        XCTAssertEqual(remaining.count, 200)
        XCTAssertFalse(names.contains("expired_0"))
        XCTAssertFalse(names.contains("expired_1"))
        for i in 0..<5 {
            XCTAssertTrue(names.contains("auth_token_\(i)"), "长期登录态 Cookie auth_token_\(i) 不得被 session 挤出")
        }
        for i in 0..<10 {
            XCTAssertTrue(names.contains("short_\(i)"), "持久化 Cookie short_\(i) 应优先于 session 条目保留")
        }
        XCTAssertFalse(names.contains("sess_0"), "最旧的 session Cookie 应优先被淘汰")
        XCTAssertFalse(names.contains("sess_14"), "最旧的 15 条 session Cookie 应优先被淘汰")
        XCTAssertTrue(names.contains("sess_199"), "最新的 session Cookie 应保留")

        // 阶段二：全部为持久化 Cookie 超限时，优先淘汰更早过期的条目、保留长期登录态
        await vault.clearCookies()
        var persistentBatch: [HTTPCookie] = []
        for i in 0..<5 {
            let c = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "login.example.com",
                .path: "/",
                .name: "long_auth_\(i)",
                .value: "vip_\(i)",
                .expires: longLivedExpiry
            ]))
            persistentBatch.append(c)
        }
        for i in 0..<205 {
            let c = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "login.example.com",
                .path: "/",
                .name: "ephemeral_\(i)",
                .value: "v_\(i)",
                .expires: now.addingTimeInterval(Double(600 + i))
            ]))
            persistentBatch.append(c)
        }
        await vault.setCookies(persistentBatch)
        let remaining2 = await vault.matchingCookies(for: url)
        let names2 = Set(remaining2.map(\.name))
        XCTAssertEqual(remaining2.count, 200)
        for i in 0..<5 {
            XCTAssertTrue(names2.contains("long_auth_\(i)"), "长期登录态 Cookie long_auth_\(i) 必须保留")
        }
        XCTAssertFalse(names2.contains("ephemeral_0"), "最早过期的持久化 Cookie 应优先被淘汰")
        XCTAssertTrue(names2.contains("ephemeral_204"))
    }

    // MARK: - 4. P2-01: PersistenceEngine.upsertBookEntity 空字符串不覆盖已有 title/author/narrator

    func testP2_01_PersistenceUpsertBookEmptyStringsDoNotOverwriteExistingMetadata() async throws {
        let container = try StorageContainerFactory.makeInMemory()
        let engine = PersistenceEngine(modelContainer: container)

        let original = BookSummaryDTO(
            id: "book-meta-guard",
            sourceID: "src-1",
            sourceName: "喜马拉雅",
            bookURL: "https://e.com/book/1",
            title: "三体全集",
            author: "刘慈欣",
            narrator: "王明军",
            coverURL: "https://e.com/cover.jpg",
            intro: "地球往事三部曲"
        )
        try await engine.upsertBook(original, addToShelf: true)

        // 模拟部分接口返回空字符串字段的回写
        let sparse = BookSummaryDTO(
            id: "book-meta-guard",
            sourceID: "src-1",
            sourceName: "",
            bookURL: "https://e.com/book/1",
            title: "",
            author: "",
            narrator: "",
            coverURL: "",
            intro: ""
        )
        try await engine.upsertBook(sparse, addToShelf: nil)

        let shelfAfterSparse = try await engine.fetchShelfBooks()
        let afterSparse = try XCTUnwrap(shelfAfterSparse.first(where: { $0.id == "book-meta-guard" }))
        XCTAssertEqual(afterSparse.title, "三体全集", "空 title 不得覆盖已有标题")
        XCTAssertEqual(afterSparse.author, "刘慈欣", "空 author 不得覆盖已有作者")
        XCTAssertEqual(afterSparse.narrator, "王明军", "空 narrator 不得覆盖已有演播")
        XCTAssertEqual(afterSparse.coverURL, "https://e.com/cover.jpg")
        XCTAssertEqual(afterSparse.intro, "地球往事三部曲")
        XCTAssertEqual(afterSparse.sourceName, "喜马拉雅")

        // 非空字段仍可正常更新
        let updated = BookSummaryDTO(
            id: "book-meta-guard",
            sourceID: "src-1",
            sourceName: "",
            bookURL: "https://e.com/book/1",
            title: "三体全集（典藏版）",
            author: "刘慈欣",
            narrator: "王明军（精修）",
            coverURL: "",
            intro: ""
        )
        try await engine.upsertBook(updated, addToShelf: nil)

        let shelfAfterUpdate = try await engine.fetchShelfBooks()
        let afterUpdate = try XCTUnwrap(shelfAfterUpdate.first(where: { $0.id == "book-meta-guard" }))
        XCTAssertEqual(afterUpdate.title, "三体全集（典藏版）")
        XCTAssertEqual(afterUpdate.author, "刘慈欣")
        XCTAssertEqual(afterUpdate.narrator, "王明军（精修）")
        XCTAssertEqual(afterUpdate.coverURL, "https://e.com/cover.jpg")
    }

    private static func resolveResourceURL(name: String, ext: String, fallbackRelativePath: String) -> URL {
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundleURL
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent(fallbackRelativePath)
    }
}
