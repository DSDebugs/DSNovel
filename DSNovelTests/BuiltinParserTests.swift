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
        // 都不命中（用中性示例，避免与被移除的番茄源混淆）
        XCTAssertFalse(targets.matches(sourceID: "other_source", sourceURL: "https://other.example.com"))
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

    // MARK: 4. 域名边界防护（H-05）、并发槽位不变量（H-01）、脱敏导出（⑦）与向后兼容解码（L-01）

    func testTargetsRejectsDomainSpoofing() {
        let targets = BuiltinParserTargets(hosts: ["ximalaya.com", "xmcdn.com"], sourceIDs: [])
        XCTAssertTrue(targets.matches(sourceID: "s", sourceURL: "https://ximalaya.com/a"))
        XCTAssertTrue(targets.matches(sourceID: "s", sourceURL: "https://mobile.ximalaya.com/a"))
        XCTAssertFalse(targets.matches(sourceID: "s", sourceURL: "https://evilximalaya.com/a"),
                       "H-05：evilximalaya.com 绝不可命中 ximalaya.com")
        XCTAssertFalse(targets.matches(sourceID: "s", sourceURL: "https://notxmcdn.com/a"),
                       "H-05：notxmcdn.com 绝不可命中 xmcdn.com")
        XCTAssertFalse(targets.matches(sourceID: "s", sourceURL: "https://xmcdn.com.evil.net/a"),
                       "H-05：xmcdn.com.evil.net 绝不可命中 xmcdn.com")
        XCTAssertFalse(targets.matches(sourceID: "s", sourceURL: "not-a-valid-url"))
    }

    func testConcurrentResolvesDoNotLeakSlots() async throws {
        let parserID = "test-slots-\(UUID().uuidString.prefix(8))"
        let preview = try await BuiltinParserRuntime.shared.analyze(
            scriptText: Self.fixtureParserScript(id: parserID),
            fileName: "slots_fixture.js"
        )
        let installed = try await BuiltinParserRuntime.shared.install(preview: preview)
        addTeardownBlock { _ = try? await BuiltinParserRuntime.shared.uninstall(parserID: parserID) }

        try await withThrowingTaskGroup(of: PlayStreamInfo.self) { group in
            for idx in 0..<10 {
                group.addTask {
                    try await BuiltinParserRuntime.shared.resolve(
                        parser: installed,
                        sourceID: "some_xmly_source",
                        episodeURL: "xm:slot_\(idx)",
                        forDownload: false,
                        qualityCode: "high"
                    )
                }
            }
            var count = 0
            for try await _ in group { count += 1 }
            XCTAssertEqual(count, 10)
        }
        let active = await BuiltinParserRuntime.shared.debugActiveSlotCount()
        XCTAssertEqual(active, 0, "H-01：10 个并发解析全部结束后 activeSlots 必须归零，实际：\(active)")
    }

    func testLegacyConfigItemDecodesWithoutOptionsField() throws {
        let json = #"{"key":"sampleTrackId","title":"样本章节"}"#
        let item = try JSONDecoder().decode(BuiltinParserConfigItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.key, "sampleTrackId")
        XCTAssertEqual(item.kind, "text")
        XCTAssertEqual(item.options, [])
    }

    func testLogDesensitizationMasksSecrets() {
        let raw = "Cookie=1&_token=secret123; buy_key=BK99&sign=SG88&token=TK77"
        let masked = BuiltinParserLogStore.desensitize(raw)
        XCTAssertFalse(masked.contains("secret123"))
        XCTAssertFalse(masked.contains("BK99"))
        XCTAssertFalse(masked.contains("SG88"))
        XCTAssertFalse(masked.contains("TK77"))
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

    // MARK: 6. 端到端：analyze → install → 绑定 → 解析 → 缓存命中（新签名含 qualityCode）

    func testInstallResolveAndCacheHit() async throws {
        let parserID = "test-xmly-\(UUID().uuidString.prefix(8))"
        // 使用独立离线域名，避免模拟器宿主 App 启动阶段后台访问 ximalaya.com 写入 Cookie 导致缓存指纹中途变化
        let fixture = Self.fixtureParserScript(id: parserID, hosts: ["\(parserID).invalid", "ximalaya.com"])
        let preview = try await BuiltinParserRuntime.shared.analyze(scriptText: fixture, fileName: "ximalaya_vip_parser.js")
        XCTAssertEqual(preview.meta.id, parserID)
        XCTAssertTrue(preview.meta.targets.hosts.contains("ximalaya.com"))
        XCTAssertFalse(preview.isUpdate)

        let installed = try await BuiltinParserRuntime.shared.install(preview: preview)
        // 用 `addTeardownBlock`（而非 `defer { Task { ... } }`）保证清理在下一个用例开始前完成：
        // 本 fixture 以 ximalaya.com 为目标，若残留会影响后续「无解析器 → builtinParserMissing」用例。
        addTeardownBlock { _ = try? await BuiltinParserRuntime.shared.uninstall(parserID: parserID) }

        // 绑定：host 优先
        let matched = await BuiltinParserRuntime.shared.parser(forSourceID: "some_xmly_source",
                                                              sourceURL: "https://mobile.ximalaya.com/x")
        XCTAssertEqual(matched?.id, parserID)

        // 绑定：无关书源不命中（用中性示例，避免与被移除的番茄源混淆）
        let notMatched = await BuiltinParserRuntime.shared.parser(forSourceID: "other_source",
                                                                  sourceURL: "https://other.example.com")
        XCTAssertNil(notMatched)

        // 注：`linkTTL` 已不再从解析器配置读取（2.5：界面删除、默认 900s、上限 1800s），
        // 这里也不再 `setConfigValue("linkTTL", ...)`；直链有效期以脚本 `expiresAt` 优先。
        // 解析（新签名：qualityCode 由 QualityPolicy 算好后透传；fixture 计数自增，用于验证缓存）
        let first = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: false,
            qualityCode: "high"
        )
        XCTAssertEqual(first.resolvedBy, BuiltinParserRuntime.resolverTag)
        XCTAssertTrue(first.url.contains("https://example.invalid/audio/"), "实际 URL：\(first.url)")
        XCTAssertEqual(first.kind, .onDemand)
        XCTAssertNotNil(first.expiresAt)

        let second = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: false,
            qualityCode: "high"
        )
        // 缓存命中：URL 内的自增计数不再变化
        XCTAssertEqual(first.url, second.url, "同一章节 + 同一音质档在 TTL 内应命中解析缓存")

        // 下载模式请求的是 downloadUrl（同档位，但缓存键含 play/dl 维度）
        let download = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: true,
            qualityCode: "high"
        )
        XCTAssertTrue(download.url.contains("/download/"))

        // 作废缓存后应重新解析
        await BuiltinParserRuntime.shared.invalidateCache(parserID: parserID, episodeURL: "xm:123456")
        let third = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:123456",
            forDownload: false,
            qualityCode: "high"
        )
        XCTAssertNotEqual(first.url, third.url, "作废缓存后应拿到新解析结果")
    }

    /// 缓存键含音质档：同章节不同 `qualityCode` 各自解析一次；相同档位第二次命中缓存。
    ///
    /// 对应 2.2 的「换档自动重新解析」+ T3 的「音质作为调用参数透传（不再写配置）」。
    func testCacheKeyIncludesQualityCode() async throws {
        let parserID = "test-quality-\(UUID().uuidString.prefix(8))"
        // 使用独立离线域名，避免模拟器宿主 App 启动阶段后台访问 ximalaya.com 写入 Cookie 导致缓存指纹中途变化
        let preview = try await BuiltinParserRuntime.shared.analyze(
            scriptText: Self.fixtureParserScript(id: parserID, hosts: ["\(parserID).invalid"]),
            fileName: "quality_cache_fixture.js"
        )
        let installed = try await BuiltinParserRuntime.shared.install(preview: preview)
        // 用 `addTeardownBlock`（而非 `defer { Task { ... } }`）保证清理在下一个用例开始前完成：
        // 本 fixture 以 ximalaya.com 为目标，若残留会影响后续「无解析器 → builtinParserMissing」用例。
        addTeardownBlock { _ = try? await BuiltinParserRuntime.shared.uninstall(parserID: parserID) }

        let highFirst = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:999001",
            forDownload: false,
            qualityCode: "high"
        )
        let lossless = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:999001",
            forDownload: false,
            qualityCode: "lossless"
        )
        XCTAssertNotEqual(highFirst.url, lossless.url,
                          "换音质档应重新解析（缓存键含 qualityCode），实际两者相同：\(highFirst.url)")

        let highSecond = try await BuiltinParserRuntime.shared.resolve(
            parser: installed,
            sourceID: "some_xmly_source",
            episodeURL: "xm:999001",
            forDownload: false,
            qualityCode: "high"
        )
        XCTAssertEqual(highFirst.url, highSecond.url, "同一档位第二次应命中缓存（不再自增计数）")

        // 缓存命中会写一条带档位的日志，便于用户自查「为什么没重新解析」
        let logs = BuiltinParserLogStore.shared.lines(for: parserID)
        XCTAssertTrue(logs.contains { $0.contains("命中解析缓存") && $0.contains("high") },
                      "缓存命中应留痕并带档位，实际日志：\(logs.suffix(4))")
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
        let packageID = preview.packageID
        addTeardownBlock {
            await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: installedID, packageID: packageID)
        }
        await PluginRuntime.shared.reloadInstalledPackages()

        // 模拟「已登录的非会员账号」：书源已登录 → 会员受限错误会被归类为 VIP 受限（而非未登录）
        CookieSync.setVerifiedLogin(sourceID: installedID, nickname: "tester")
        defer { CookieSync.setVerifiedLogin(sourceID: installedID, nickname: nil) }

        do {
            // 新签名：forDownload / tier 均有默认值；这里显式传 tier 避免依赖 AppSettingsStore 的全局默认档
            _ = try await PluginRuntime.shared.resolvePlayStream(
                sourceID: installedID,
                episodeURL: "https://ximalaya.com/ep/1",
                forDownload: false,
                tier: .high
            )
            XCTFail("VIP 章节在未安装内置解析时应抛出错误")
        } catch let error as PluginError {
            switch error {
            case .builtinParserMissing:
                XCTAssertEqual(error.builtinParserJumpTitle, BuiltinParserStrings.jumpToImport)
            case .builtinParserFailed:
                XCTFail("没有可用解析器时应抛 builtinParserMissing（提示去导入），而不是 builtinParserFailed")
            case .vipRequired:
                XCTFail("应已转换为 builtinParserMissing（提示去导入）")
            default:
                XCTFail("错误类型不符：\(error)")
            }
        }
    }

    // MARK: 8. 日志：写入后 `lines(for:)` 能读到最后一条

    /// 内存路径断言。**落盘路径需真机确认**：`lines(for:)` 在内存为空时会尝试从
    /// `Application Support/BuiltinParsers/<id>/parser.log` 恢复（重启后场景），
    /// 该行为依赖宿主的 Application Support 可写性，本条用例不做跨进程验证
    /// （内存未清空时不会走磁盘分支，见 `BuiltinParserLogStore.lines(for:)`）。
    func testLogStoreAppendAndReadBackLastLine() {
        let parserID = "test-log-\(UUID().uuidString.prefix(8))"
        let store = BuiltinParserLogStore.shared
        store.clear(parserID)
        defer { store.clear(parserID) }

        XCTAssertTrue(store.lines(for: parserID).isEmpty, "清空后应为空")

        store.append(parserID, "第一条：resolve xm:1（播放，音质 high）")
        store.append(parserID, "第二条：解析成功")

        let lines = store.lines(for: parserID)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last?.hasSuffix("第二条：解析成功"), true,
                       "最后一条应为最新写入，实际：\(lines.last ?? "nil")")
        XCTAssertEqual(lines.first?.hasPrefix("["), true, "日志行应带时间戳前缀")
    }

    // MARK: 9. 系统托管配置键：脚本声明了也不进解析器界面

    func testManagedConfigKeysAreFilteredOutOfParserUI() async throws {
        let parserID = "test-managed-\(UUID().uuidString.prefix(8))"
        let preview = try await BuiltinParserRuntime.shared.analyze(
            scriptText: Self.fixtureParserScript(id: parserID),
            fileName: "managed_config_fixture.js"
        )
        let declaredKeys = Set(preview.meta.config.map(\.key))
        XCTAssertEqual(declaredKeys, ["quality", "linkTTL", "allowRemoteCookie"],
                       "fixture 声明了 3 个系统托管键，用于验证界面过滤")

        // 界面渲染条件：`parser.meta.config.filter { !QualityPolicy.managedParserConfigKeys.contains($0.key) }`
        // （`BuiltinParserSection.swift`）——托管键必须全部被过滤掉。
        let renderedKeys = declaredKeys.subtracting(QualityPolicy.managedParserConfigKeys)
        XCTAssertTrue(renderedKeys.isEmpty, "托管键不应出现在解析器界面的可配置项里：\(renderedKeys)")
    }

    // MARK: 10. 链路固定为「解析器优先」：官方通道尚未被调用，解析器结果直接返回

    /// 书源 fixture 的 `audio()` 一律抛 VIP 错误（等价于官方通道必然失败）。
    /// 一旦匹配到已启用的解析器，`resolvePlayStream` 必须直接返回解析器结果
    /// （`resolvedBy == builtinParser`），证明「解析器优先」已取代旧的 `.rejected` 短路与策略分支。
    func testParserFirstChainReturnsParserStreamBeforeBookSource() async throws {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let sourceID = "tmp_parser_first_\(suffix)"
        // 用专属 host/IP 命名空间，避免与其它用例的解析器目标（ximalaya.com）互相干扰
        let fixtureHost = "parser-first-\(suffix).example"

        let sourceScript = """
        registerSource({
          id: '\(sourceID)',
          name: '解析器优先链测试源',
          url: 'https://\(fixtureHost)/',
          audio: function (url) {
            throw new Error('这一集需要喜马拉雅会员或购买后才能收听：请在书源管理中登录已开通会员或已购该专辑的账号');
          }
        });
        """
        let sourcePreview = try await PluginRuntime.shared.prepareImportPreview(from: Data(sourceScript.utf8))
        let sourceMetas = try await PluginRuntime.shared.installPackage(sourcePreview)
        let installedSourceID = try XCTUnwrap(sourceMetas.first?.id)
        let sourcePackageID = sourcePreview.packageID
        addTeardownBlock {
            await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: installedSourceID, packageID: sourcePackageID)
        }
        await PluginRuntime.shared.reloadInstalledPackages()

        let parserID = "test-parser-first-\(suffix)"
        let parserPreview = try await BuiltinParserRuntime.shared.analyze(
            scriptText: Self.fixtureParserScript(id: parserID, hosts: [fixtureHost], sourceIDs: [installedSourceID]),
            fileName: "parser_first_fixture.js"
        )
        let installedParser = try await BuiltinParserRuntime.shared.install(preview: parserPreview)
        addTeardownBlock { _ = try? await BuiltinParserRuntime.shared.uninstall(parserID: installedParser.id) }

        // 解析器已启用（默认 true）且与 sourceID 绑定 → 应直接命中解析器
        let matched = await BuiltinParserRuntime.shared.parser(forSourceID: installedSourceID,
                                                              sourceURL: "https://\(fixtureHost)/")
        XCTAssertEqual(matched?.id, parserID, "解析器应已绑定到该测试书源")

        let stream = try await PluginRuntime.shared.resolvePlayStream(
            sourceID: installedSourceID,
            episodeURL: "xm:654321",
            forDownload: false,
            tier: .high
        )
        XCTAssertEqual(stream.resolvedBy, BuiltinParserRuntime.resolverTag,
                       "解析器优先：官方通道必然抛 VIP，返回的却应是解析器直链")
        XCTAssertTrue(stream.url.contains("https://example.invalid/audio/"), "实际 URL：\(stream.url)")
    }

    // MARK: 11. 解析器声明的音质能力（qualities）：analyze → meta → 落盘 meta.json → 读回

    /// 脚本 `registerBuiltinParser({ qualities: [...] })` 声明的档位要一路保留到已安装的解析器：
    /// `prelude_parser.js` → `decodeMeta` → `BuiltinParserStore`（meta.json）→ `loadParser`。
    /// 这是「无损档是否显示」将来由解析器声明驱动的数据前提。
    func testParserDeclaredQualitiesSurviveInstallRoundTrip() async throws {
        let parserID = "test-qualities-\(UUID().uuidString.prefix(8))"
        let expected: Set<String> = ["auto", "saver", "standard", "high", "lossless"]
        let preview = try await BuiltinParserRuntime.shared.analyze(
            scriptText: Self.fixtureParserScript(id: parserID),
            fileName: "qualities_fixture.js"
        )
        XCTAssertEqual(preview.meta.qualities, expected, "analyze 阶段应读到脚本声明的档位")
        XCTAssertTrue(QualityPolicy.parserDeclaresLossless(preview.meta.qualities))

        let installed = try await BuiltinParserRuntime.shared.install(preview: preview)
        addTeardownBlock { _ = try? await BuiltinParserRuntime.shared.uninstall(parserID: parserID) }

        // `install()` 内部会用 `BuiltinParserStore.installedParsers()` 重扫磁盘，
        // 因此 `installed.meta` 就是「写盘后从 meta.json 读回」的结果，声明不应丢失
        XCTAssertEqual(installed.meta.qualities, expected, "写入 meta.json 再读回后 qualities 不应丢失")
        let reloaded = await BuiltinParserRuntime.shared.parser(withID: parserID)
        XCTAssertEqual(reloaded?.meta.qualities, expected)
        XCTAssertTrue(QualityPolicy.parserDeclaresLossless(reloaded?.meta.qualities ?? []))
    }

    // MARK: fixtures

    /// 离线解析器 fixture：不做网络请求，返回固定 URL；用 pref 计数验证缓存是否命中
    ///
    /// - Parameters:
    ///   - hosts: 目标 host（默认喜马拉雅，走 host 匹配路径）
    ///   - sourceIDs: 目标 sourceID（默认 fixture 自身派生值，走 sourceID 兜底路径）
    static func fixtureParserScript(
        id: String,
        hosts: [String] = ["ximalaya.com", "xmcdn.com"],
        sourceIDs: [String]? = nil
    ) -> String {
        let resolvedSourceIDs = sourceIDs ?? ["\(id)_source"]
        let jsArray = { (items: [String]) in "[" + items.map { "'\($0)'" }.joined(separator: ", ") + "]" }
        return """
        registerBuiltinParser({
          id: '\(id)',
          name: '离线测试解析器',
          version: '0.0.1',
          author: 'tests',
          description: '仅用于单元测试，不做任何网络请求',
          targets: { hosts: \(jsArray(hosts)), sourceIDs: \(jsArray(resolvedSourceIDs)) },
          capabilities: { playback: true, download: true, needsCookie: false },
          qualities: ['auto', 'saver', 'standard', 'high', 'lossless'],
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
              url: 'https://example.invalid/audio/' + request.trackId + '?n=' + count + '&q=' + request.quality,
              headers: { 'User-Agent': 'fixture' },
              kind: 'onDemand',
              isPaid: true,
              expiresAt: Math.floor(Date.now() / 1000) + 600
            };
          }
        });
        """
    }

    // MARK: 12. A-2：试听短流不滞留正缓存（首次试听抛错后自动作废缓存，下次重跑脚本）

    func testA2TrialStreamDoesNotStayCached() async throws {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let sourceID = "tmp_trial_evict_\(suffix)"
        let fixtureHost = "trial-evict-\(suffix).example"

        let sourceScript = """
        registerSource({
          id: '\(sourceID)',
          name: '试听作废测试源',
          url: 'https://\(fixtureHost)/',
          audio: function (url) {
            throw new Error('这一集需要喜马拉雅会员或购买后才能收听：请在书源管理中登录已开通会员或已购该专辑的账号');
          }
        });
        """
        let sourcePreview = try await PluginRuntime.shared.prepareImportPreview(from: Data(sourceScript.utf8))
        let sourceMetas = try await PluginRuntime.shared.installPackage(sourcePreview)
        let installedSourceID = try XCTUnwrap(sourceMetas.first?.id)
        let sourcePackageID = sourcePreview.packageID
        addTeardownBlock {
            await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: installedSourceID, packageID: sourcePackageID)
        }
        await PluginRuntime.shared.reloadInstalledPackages()

        let parserID = "test-trial-evict-\(suffix)"
        let parserScript = """
        registerBuiltinParser({
          id: '\(parserID)',
          name: '试听缓存作废测试解析器',
          version: '0.0.1',
          author: 'tests',
          description: '第 1 次返回试听，第 2 次返回完整流',
          targets: { hosts: ['\(fixtureHost)'], sourceIDs: ['\(installedSourceID)'] },
          capabilities: { playback: true, download: true, needsCookie: false },
          qualities: ['auto', 'saver', 'standard', 'high', 'lossless'],
          config: [],
          resolveAudio: function (request) {
            var count = parseInt(this.host.getPref('counter', '0'), 10) + 1;
            this.host.setPref('counter', String(count));
            return {
              url: 'https://example.invalid/audio/' + request.trackId + '?attempt=' + count,
              headers: { 'User-Agent': 'fixture' },
              kind: 'onDemand',
              isPaid: true,
              isTrial: count === 1,
              durationSec: count === 1 ? 30 : 600,
              expiresAt: Math.floor(Date.now() / 1000) + 600
            };
          }
        });
        """
        let parserPreview = try await BuiltinParserRuntime.shared.analyze(
            scriptText: parserScript,
            fileName: "trial_evict_fixture.js"
        )
        let installedParser = try await BuiltinParserRuntime.shared.install(preview: parserPreview)
        addTeardownBlock { _ = try? await BuiltinParserRuntime.shared.uninstall(parserID: installedParser.id) }

        CookieSync.setVerifiedLogin(sourceID: installedSourceID, nickname: "tester")
        defer { CookieSync.setVerifiedLogin(sourceID: installedSourceID, nickname: nil) }

        // 第 1 次：解析器返回 isTrial=true → 必须作废缓存并抛带 trial_only: 前缀的 builtinParserFailed
        do {
            _ = try await PluginRuntime.shared.resolvePlayStream(
                sourceID: installedSourceID,
                episodeURL: "xm:888001",
                forDownload: false,
                tier: .high
            )
            XCTFail("第 1 次返回试听流应抛 builtinParserFailed")
        } catch let error as PluginError {
            guard case .builtinParserFailed(_, let reason) = error else {
                return XCTFail("应抛出 builtinParserFailed，实际：\(error)")
            }
            XCTAssertTrue(reason.hasPrefix("trial_only:"), "应保留 trial_only: 前缀，实际：\(reason)")
        }

        // 第 2 次：缓存已作废，必须重新调用脚本并拿到完整流（attempt=2）
        let full = try await PluginRuntime.shared.resolvePlayStream(
            sourceID: installedSourceID,
            episodeURL: "xm:888001",
            forDownload: false,
            tier: .high
        )
        XCTAssertTrue(full.url.contains("attempt=2"), "试听流缓存应已作废并重新解析，实际 URL：\(full.url)")
    }

    // MARK: 13. A-3：describe 保留 BuiltinParserError.rejected 原始错误码并可被 DSStateView 精确匹配

    func testA3ReasonKeepsRawCodeThroughDescribe() {
        let trialDesc = PluginRuntime.describe(BuiltinParserError.rejected("trial_only", "该章节仅提供试听"))
        XCTAssertEqual(trialDesc, "trial_only: 该章节仅提供试听")

        let noCookieEmpty = PluginRuntime.describe(BuiltinParserError.rejected("no_cookie", ""))
        XCTAssertEqual(noCookieEmpty, "no_cookie")

        let overrideTrial = UserFacingError.messageOverride(
            for: PluginError.builtinParserFailed(sourceID: "s1", reason: trialDesc)
        )
        XCTAssertEqual(overrideTrial, "该章节仅提供试听，需要会员或购买")

        let overrideNoCookie = UserFacingError.messageOverride(
            for: PluginError.builtinParserFailed(sourceID: "s1", reason: noCookieEmpty)
        )
        XCTAssertEqual(
            overrideNoCookie,
            "本机账号无权限，且共享的具备权限的 Cookie 不可用；请用会员账号登录或稍后重试"
        )
    }

    // MARK: 14. A-5：JS 错误回传带 c: true 时映射为 Swift CancellationError

    func testA5JSCancelledFlagMapsToCancellationError() async throws {
        let parserID = "test-js-cancel-\(UUID().uuidString.prefix(8))"
        let script = """
        registerBuiltinParser({
          id: '\(parserID)',
          name: '取消标志测试解析器',
          version: '0.0.1',
          author: 'tests',
          description: '抛出带 cancelled: true 的错误',
          targets: { hosts: ['cancel-flag.example'], sourceIDs: ['\(parserID)_src'] },
          capabilities: { playback: true, download: false, needsCookie: false },
          qualities: ['high'],
          config: [],
          resolveAudio: function () {
            var err = new Error('request aborted');
            err.cancelled = true;
            err.reason = 'cancelled';
            throw err;
          }
        });
        """
        let preview = try await BuiltinParserRuntime.shared.analyze(scriptText: script, fileName: "cancel_fixture.js")
        let installed = try await BuiltinParserRuntime.shared.install(preview: preview)
        addTeardownBlock { _ = try? await BuiltinParserRuntime.shared.uninstall(parserID: installed.id) }

        do {
            _ = try await BuiltinParserRuntime.shared.resolve(
                parser: installed,
                sourceID: "\(parserID)_src",
                episodeURL: "xm:777001",
                forDownload: false,
                qualityCode: "high"
            )
            XCTFail("JS 抛出 cancelled=true 错误时应抛 CancellationError")
        } catch is CancellationError {
            // 预期命中 CancellationError（不会写入负缓存）
        } catch {
            XCTFail("应映射为 CancellationError，实际：\(error)")
        }
    }
}
