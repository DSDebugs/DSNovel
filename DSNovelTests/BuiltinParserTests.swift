import XCTest
import JavaScriptCore
@testable import DSNovel

/// 内置解析（喜马拉雅 VIP 章节）相关测试
///
/// 全部使用离线 fixture：
///  - 解析器 fixture 只返回固定 URL，不做任何网络请求
///  - 书源 fixture 只抛「需会员」错误，用来验证 VIP → 内置解析的回退链
final class BuiltinParserTests: XCTestCase {

    // MARK: 1. 路径白名单（修复既有的包名路径穿越隐患）

    func testSanitizeRejectsPathTraversal() {
        XCTAssertEqual(BuiltinParserStore.sanitize(".."), "parser")
        XCTAssertEqual(BuiltinParserStore.sanitize("../evil"), "evil")
        XCTAssertFalse(BuiltinParserStore.sanitize("a/../../b").contains("/"))
        XCTAssertFalse(BuiltinParserStore.sanitize("a\\b").contains("\\"))
        XCTAssertEqual(BuiltinParserStore.sanitize("ximalaya-vip"), "ximalaya-vip")
        XCTAssertEqual(BuiltinParserStore.sanitize("   "), "parser")
        XCTAssertFalse(BuiltinParserStore.sanitize(String(repeating: "a", count: 200)).count > 64)
    }

    // MARK: 2. 绑定规则：host 优先 + sourceID 兜底

    func testTargetsHostFirstThenSourceID() {
        let targets = BuiltinParserTargets(hosts: ["ximalaya.com", "xmcdn.com"],
                                           sourceIDs: ["6e2b9c4d8a1f4d37b5c0e73a9f1d2b64"])
        // host 命中（含子域）
        XCTAssertTrue(targets.matches(sourceID: "other_source", sourceURL: "https://mobile.ximalaya.com/x"))
        XCTAssertTrue(targets.matches(sourceID: "other_source", sourceURL: "https://ximalaya.com/x"))
        // sourceID 兜底命中（host 不匹配时）
        XCTAssertTrue(targets.matches(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", sourceURL: "https://unknown.example.com"))
        // 都不命中
        XCTAssertFalse(targets.matches(sourceID: "fanqie", sourceURL: "https://fanqie.example.com"))
    }

    // MARK: 3. 错误文案与跳转标题（全 App 唯一提示出口的口径）

    func testVIPErrorCopyAndJumpTitle() {
        let missing = PluginError.builtinParserMissing(sourceID: "s1")
        XCTAssertTrue(missing.isVIPRelated)
        XCTAssertEqual(missing.builtinParserJumpTitle, BuiltinParserStrings.jumpToImport)
        XCTAssertEqual(missing.localizedDescription, BuiltinParserStrings.vipNeedsParser)

        let failed = PluginError.builtinParserFailed(sourceID: "s1", reason: "付费直链接口解析失败")
        XCTAssertTrue(failed.isVIPRelated)
        XCTAssertEqual(failed.builtinParserJumpTitle, BuiltinParserStrings.jumpToInspect)
        XCTAssertTrue(failed.localizedDescription.contains("付费直链接口解析失败"))

        // 非 VIP 类错误不显示跳转按钮
        XCTAssertNil(PluginError.needLogin(sourceID: "s1", loginURL: "").builtinParserJumpTitle)
        XCTAssertNil(PluginError.timeout.builtinParserJumpTitle)
    }

    // MARK: 4. 策略默认值

    func testDefaultStrategyIsFallback() async {
        let parserID = "test_strategy_\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: BuiltinParserRuntime.strategyKey(parserID))
        let strategy = await BuiltinParserRuntime.shared.strategy(for: parserID)
        XCTAssertEqual(strategy, .fallback)
    }

    // MARK: 5. 干跑校验：书源脚本必须被识别并给出清晰原因

    func testAnalyzeRejectsSourceScript() async {
        let sourceScript = "registerSource({ id: 'x', name: 'x', url: 'https://example.com' });"
        do {
            _ = try await BuiltinParserRuntime.shared.analyze(scriptText: sourceScript, fileName: "source.js")
            XCTFail("书源脚本不应被当作内置解析脚本接受")
        } catch let error as BuiltinParserError {
            guard case .scriptInvalid(let why) = error else {
                return XCTFail("错误类型应为 scriptInvalid，实际：\(error)")
            }
            XCTAssertTrue(why.contains("书源脚本"))
        } catch {
            XCTFail("未预期的错误：\(error)")
        }
    }

    func testAnalyzeRejectsUnrelatedScript() async {
        do {
            _ = try await BuiltinParserRuntime.shared.analyze(scriptText: "var a = 1;", fileName: "noop.js")
            XCTFail("未注册解析器的脚本不应通过校验")
        } catch let error as BuiltinParserError {
            guard case .scriptInvalid = error else {
                return XCTFail("错误类型应为 scriptInvalid，实际：\(error)")
            }
        } catch {
            XCTFail("未预期的错误：\(error)")
        }
    }

    // MARK: 6. 端到端：analyze → install → 绑定 → 解析 → 缓存命中

    func testInstallResolveAndCacheHit() async throws {
        let parserID = "test-xmly-\(UUID().uuidString.prefix(8))"
        let fixture = Self.fixtureParserScript(id: parserID)
        let preview = try await BuiltinParserRuntime.shared.analyze(scriptText: fixture, fileName: "ximalaya_vip_parser.js")
        XCTAssertEqual(preview.meta.id, parserID)
        XCTAssertTrue(preview.meta.targets.hosts.contains("ximalaya.com"))
        XCTAssertFalse(preview.isUpdate)

        let installed = try await BuiltinParserRuntime.shared.install(preview: preview)
        defer { Task { try? await BuiltinParserRuntime.shared.uninstall(parserID: installed.id) } }

        // 绑定：host 优先
        let matched = await BuiltinParserRuntime.shared.parser(forSourceID: "some_xmly_source",
                                                              sourceURL: "https://mobile.ximalaya.com/x")
        XCTAssertEqual(matched?.id, parserID)

        // 绑定：无关书源不命中
        let notMatched = await BuiltinParserRuntime.shared.parser(forSourceID: "fanqie",
                                                                  sourceURL: "https://fanqie.example.com")
        XCTAssertNil(notMatched)

        // 解析（fixture 计数自增，用于验证第二次命中缓存）
        await BuiltinParserRuntime.shared.setConfigValue(parserID: parserID, key: "linkTTL", value: "900")
        let first = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: false
        )
        XCTAssertEqual(first.resolvedBy, BuiltinParserRuntime.resolverTag)
        XCTAssertTrue(first.url.contains("https://example.invalid/audio/"), "实际 URL：\(first.url)")
        XCTAssertEqual(first.kind, .onDemand)
        XCTAssertNotNil(first.expiresAt)

        let second = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: false
        )
        // 缓存命中：URL 内的自增计数不再变化
        XCTAssertEqual(first.url, second.url, "同一章节在 TTL 内应命中解析缓存")

        // 下载模式请求的是 downloadUrl
        let download = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: true
        )
        XCTAssertTrue(download.url.contains("/download/"))

        // 作废缓存后应重新解析
        await BuiltinParserRuntime.shared.invalidateCache(parserID: parserID, episodeURL: "xm:123456")
        let third = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: false
        )
        XCTAssertNotEqual(first.url, third.url, "作废缓存后应拿到新解析结果")
    }

    // MARK: 7. 未安装解析器时，VIP 章节报错必须是「去导入」而不是网络错误

    func testVipChapterWithoutParserThrowsMissing() async throws {
        let sourceID = "tmp_xmly_\(UUID().uuidString.prefix(8))"
        let script = """
        registerSource({
          id: '\(sourceID)',
          name: '临时喜马测试源',
          url: 'https://ximalaya.com/',
          audio: function (url) {
            throw new Error('这一集需要喜马拉雅会员或购买后才能收听：请在书源管理中登录已开通会员或已购该专辑的账号');
          }
        });
        """
        let preview = try await PluginRuntime.shared.prepareImportPreview(from: Data(script.utf8))
        let metas = try await PluginRuntime.shared.installPackage(preview)
        let installedID = try XCTUnwrap(metas.first?.id)
        defer {
            Task { await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: installedID, packageID: preview.packageID) }
        }
        await PluginRuntime.shared.reloadInstalledPackages()

        // 模拟「已登录的非会员账号」：书源已登录 → 会员受限错误会被归类为 VIP 受限（而非未登录）
        CookieSync.setVerifiedLogin(sourceID: installedID, nickname: "tester")
        defer { CookieSync.setVerifiedLogin(sourceID: installedID, nickname: nil) }

        do {
            _ = try await PluginRuntime.shared.resolvePlayStream(sourceID: installedID, episodeURL: "https://ximalaya.com/ep/1")
            XCTFail("VIP 章节在未安装内置解析时应抛出错误")
        } catch let error as PluginError {
            switch error {
            case .builtinParserMissing:
                XCTAssertEqual(error.builtinParserJumpTitle, BuiltinParserStrings.jumpToImport)
            case .vipRequired:
                XCTFail("应已转换为 builtinParserMissing（提示去导入）")
            default:
                XCTFail("错误类型不符：\(error)")
            }
        }
    }

    // MARK: fixtures

    /// 离线解析器 fixture：不做网络请求，返回固定 URL；用 pref 计数验证缓存是否命中
    static func fixtureParserScript(id: String) -> String {
        """
        registerBuiltinParser({
          id: '\(id)',
          name: '离线测试解析器',
          version: '0.0.1',
          author: 'tests',
          description: '仅用于单元测试，不做任何网络请求',
          targets: { hosts: ['ximalaya.com', 'xmcdn.com'], sourceIDs: ['\(id)_source'] },
          capabilities: { playback: true, download: true, needsCookie: false },
          config: [
            { key: 'quality', title: '音质', defaultValue: 'M4A_128', kind: 'enum', options: ['M4A_128', 'M4A_64'] },
            { key: 'linkTTL', title: '直链缓存秒数', defaultValue: '900', kind: 'number' },
            { key: 'allowRemoteCookie', title: '允许远端共享 Cookie', defaultValue: 'false', kind: 'bool' }
          ],
          checkStatus: function () {
            return { ok: true, message: 'fixture ok', latencyMs: 1, nickname: 'fixture', vipExpireAt: '2026-01-01' };
          },
          resolveAudio: function (request) {
            var count = parseInt(this.host.getPref('counter', '0'), 10) + 1;
            this.host.setPref('counter', String(count));
            if (request.forDownload) {
              return {
                url: 'https://example.invalid/download/' + request.trackId + '?n=' + count,
                headers: { 'User-Agent': 'fixture' },
                kind: 'onDemand',
                isPaid: true,
                expiresAt: Math.floor(Date.now() / 1000) + 600
              };
            }
            return {
              url: 'https://example.invalid/audio/' + request.trackId + '?n=' + count,
              headers: { 'User-Agent': 'fixture' },
              kind: 'onDemand',
              isPaid: true,
              expiresAt: Math.floor(Date.now() / 1000) + 600
            };
          }
        });
        """
    }
}
